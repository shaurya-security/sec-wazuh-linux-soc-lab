# Wazuh Linux SOC Simulation

A self-contained SOC lab on AWS: a Wazuh manager and a Linux endpoint, provisioned entirely with Terraform, instrumented with custom correlation rules, and exercised end-to-end against a simulated privilege-escalation-to-persistence attack chain — detection, correlation, evidence preservation, and recovery.

This isn't a Wazuh install guide. It's a working example of taking a detection stack from "installed" to "proven": a specific attack chain is simulated, the SIEM is shown detecting and correlating it, and the compromised host is recovered from a known-good image with the decision reasoning documented.

## What this demonstrates

- **Infrastructure as code** — VPC, security groups, IAM (SSM-only access, no SSH keys), and two EC2 instances (manager + endpoint) defined in Terraform, with user-data delivered via S3 and driven by content-hash triggers (`filemd5()` → `user_data_replace_on_change`) so a script edit reliably replaces the instance instead of silently no-op'ing.
- **A real, if simplified, attack chain** — sudo-group escalation → repeated root execution → root crontab persistence — generated on the endpoint and traced through to alerts on the manager.
- **Custom correlation rules**, not just default Wazuh signatures, mapped to MITRE ATT&CK.
- **A documented recovery decision**, not just a cleanup script: why the compromised host was rebuilt rather than cleaned in place, with evidence preserved before any remediation.
- **Honest scope** — what was validated, and what wasn't, written down instead of implied.

## Architecture

```
                          AWS (ap-south-1)
                                │
                    ┌───────────┴───────────┐
                    │          VPC           │
                    │   public subnet only   │
                    └───────────┬───────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        │                       │                        │
 ┌──────▼───────┐      ┌────────▼────────┐      ┌────────▼─────────┐
 │ wazuh-server  │◄─────┤ linux-endpoint  │      │ linux-endpoint-   │
 │ (manager +    │ 1514 │ (Wazuh agent +  │      │ recovery           │
 │  dashboard)   │ 1515 │  auditd + FIM)  │      │ (known-good        │
 │               │      │                 │      │  baseline AMI)     │
 └───────────────┘      └─────────────────┘      └─────────────────────┘
        │                       │
        └────────── AWS SSM (no inbound SSH needed) ──────────┘
```

- **Manager and endpoint** communicate over the private subnet (agent enrollment on 1515, event forwarding on 1514); the dashboard (443) is restricted to the operator's own public IP.
- **Access is via AWS Systems Manager**, not SSH keys — the IAM role attached to both instances only grants `AmazonSSMManagedInstanceCore` plus scoped read access to the user-data bucket.
- **User-data scripts live in S3**, not inline in Terraform, to get around the 16KB EC2 user-data limit and to keep the actual provisioning logic reviewable as plain shell rather than buried in HCL strings.
- **The recovery endpoint** is a separate resource launched from a baseline AMI captured *before* the attack simulation, standing in for "rebuild from known-good state" rather than in-place cleanup.

## Repository layout

```
.
├── terraform-bootstrap/     # One-time setup: S3 bucket for Terraform remote state
├── terraform-lab/           # The actual lab infrastructure
│   ├── main.tf, vpc.tf, iam.tf, compute.tf, s3.tf, data.tf, locals.tf, variables.tf, output.tf
│   ├── create-baseline-ami.sh     # Snapshots the clean endpoint into a known-good AMI
│   ├── .checkov.yaml               # Static-analysis exceptions, with reasons
│   ├── .github/workflows/          # CI: terraform fmt/validate + Checkov on every push/PR
│   └── userdata/
│       ├── common.sh                    # Shared bootstrap: SSM, ssm-user, shell setup
│       ├── wazuh.sh / wazuh.sh.tpl               # Manager install + custom correlation rules
│       ├── linux-endpoint.sh / .sh.tpl           # Agent install, FIM + auditd forwarding
│       ├── simulate_soc_chain.sh                 # Generates the controlled attack chain
│       ├── recovery-assessment.sh                # Case-specific persistence check
│       └── userdata-logs.sh                      # Scans bootstrap logs for real failures
├── evidence/
│   ├── timeline.txt                     # Full incident → recovery timeline
│   ├── wazuh/                           # Raw correlation alerts (JSON)
│   ├── endpoint/                        # Recovery-assessment output, pre- and post-recovery
│   ├── screenshots/                     # Detection/correlation and persistence evidence
│   └── ami_reference.example.txt        # Template for recording the baseline AMI used
├── lessons-learned.txt      # Explicit gaps in this exercise, not silently closed
└── debugging-notes.md       # Working notes: decisions and fixes made while building this
```

## The attack chain

Everything is driven by four Wazuh events, correlated into two custom rules:

```
Event                                    Wazuh rule   Custom correlation
──────────────────────────────────────   ──────────   ──────────────────
User added to sudo group                 2961    ──▶  110010 (T1136, T1548.003)
Successful sudo → root (1st occurrence)  5402    ─┐
Successful sudo → root (2nd occurrence)  5402    ─┤─▶ 110011: ≥2 sudo→root in 60s (T1548.003)
Root crontab modified ("REPLACE (root)") 2833    ─┘
                                                       110012: repeated sudo→root
                                                       + crontab change in 90s
                                                       → possible persistence
                                                       (T1548.003, T1053.003)
```

`simulate_soc_chain.sh` reproduces this on the endpoint on demand — useful both for generating the original evidence and for re-validating detection after any change to the pipeline (see [Recovery](#recovery--decision-process) below).

## Recovery & decision process

The core question after the simulated compromise wasn't *"is the malicious cron entry gone?"* — it was *"can this host still be trusted?"* Because the chain includes root-level execution, the lab treats that as a **rebuild** case rather than in-place cleanup:

1. **Evidence first** — Wazuh alerts, endpoint state, and a full timeline (`evidence/timeline.txt`) were captured before any remediation.
2. **Assessment, not assumption** — `recovery-assessment.sh` checks the specific persistence chain (sudo group membership, root crontab contents, cron spool, execution artifacts) rather than assuming the known IOC is the whole compromise.
3. **Rebuild from known-good** — the baseline AMI, snapshotted *before* the simulation via `create-baseline-ami.sh`, is used to launch `linux_endpoint_recovery` as a separate Terraform resource, standing in for a genuine known-good rebuild rather than a repaired instance.
4. **Validate, don't assume** — the same `recovery-assessment.sh` is re-run against the recovered endpoint to confirm no persistence artifacts survived.

Full reasoning — the decision gates, the clean-vs-rebuild matrix, and why credential rotation was deliberately *not* invented for an SSM-only architecture — is in [`debugging-notes.md`](./debugging-notes.md).

### What wasn't completed

This is a lab exercise, and the gaps are documented rather than glossed over, in [`lessons-learned.txt`](./lessons-learned.txt):

- The compromised endpoint was not network-isolated immediately on detection.
- The compromised endpoint was not terminated after evidence preservation.
- End-to-end Wazuh telemetry (agent connectivity, log ingestion, live alerting) on the *recovered* endpoint was not independently re-verified.

## Deploying it yourself

```bash
# 1. One-time: create the remote state bucket
cd terraform-bootstrap
terraform init
terraform apply

# 2. Deploy the lab
cd ../terraform-lab
terraform init
terraform plan
terraform apply
```

Requirements: an AWS account/credentials with permission to create VPC, EC2, IAM, and S3 resources, and Terraform ≥ 1.5. The Wazuh dashboard, manager private IP, and generated credentials are surfaced as Terraform outputs after apply; the manager's admin password is also written to `/home/ssm-user/wazuh-passwords.txt` on the instance itself, retrievable via SSM (no SSH access is configured or required).

To re-run the attack simulation against a fresh deployment:

```bash
# on the endpoint, via SSM Session Manager
sudo ./simulate_soc_chain.sh
# then check /var/ossec/logs/alerts/alerts.json on the manager for rules
# 110010 / 110011 / 110012
```

CI (`.github/workflows/terraform.yml`) runs `terraform fmt -check`, `terraform validate`, and Checkov on every push and pull request; intentional Checkov exceptions (public IPs on the lab subnet, unrestricted egress, etc.) are documented with reasons in `.checkov.yaml`.

## Notes on scope

This is a personal lab built to exercise detection engineering and incident-response workflow end-to-end, not a hardened reference architecture. Deliberate simplifications — a single public subnet, no VPC Flow Logs, no multi-AZ — are called out in `.checkov.yaml` and `lessons-learned.txt` rather than left unexplained.
