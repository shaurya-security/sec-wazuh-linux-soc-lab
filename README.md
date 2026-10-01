<div align="center">

# 🛡️ Linux Privilege-Abuse Detection & Recovery Lab

**Attack → Detect → Correlate → Preserve → Rebuild, on AWS, built entirely as code.**

![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC?style=flat-square)
![Wazuh](https://img.shields.io/badge/SIEM-Wazuh_4.14-005571?style=flat-square)
![AWS](https://img.shields.io/badge/Cloud-AWS_ap--south--1-FF9900?style=flat-square)
![MITRE](https://img.shields.io/badge/MITRE-T1548.003_·_T1053.003-C0392B?style=flat-square)

</div>

---

## 📌 Summary

A small SOC lab that simulates a sudo-abuse-to-persistence chain on a Linux endpoint, detects and correlates it with custom [Wazuh](https://wazuh.com) rules, then recovers the host by **rebuilding it from a known-good AMI** instead of cleaning it in place.

It goes past "Wazuh is installed" to a documented case: what fired, what was found, why the host was rebuilt, and which steps were *not* finished.

| | |
|---|---|
| **Attack** | `ssm-user` added to sudo → repeated root sudo → root crontab persistence ([T1548.003](https://attack.mitre.org/techniques/T1548/003/), [T1053.003](https://attack.mitre.org/techniques/T1053/003/)) |
| **Detection** | Custom rules `110010` → `110011` → `110012` on top of stock `2961`, `5402`, `2833` |
| **Response** | Evidence first, targeted assessment, rebuild from a pre-attack baseline AMI |
| **Infra** | VPC, 3× EC2, IAM + SSM (no SSH keys), S3-delivered bootstrap scripts. Terraform with remote state |
| **Scope** | Honest: isolation, host removal and post-recovery telemetry validation were **not completed** |

---

## 🔬 Results

Recorded run, 9 Sep 2026 (IST). Full detail in [`docs/incident-report.md`](docs/incident-report.md).

| # | Step | Outcome | Evidence |
|:-:|---|---|:-:|
| 1 | Sudo activity on `linux-endpoint` | `5402`, then **`110011`** (level 12) about 6 s later | [alerts](evidence/wazuh/correlation-alerts.json) |
| 2 | Root crontab replaced | **`110012`** (level **15**), 44 s after the first event | [screenshot](evidence/screenshots/detection-correlation.png) |
| 3 | Endpoint inspected | Cron entry present and had executed | [screenshot](evidence/screenshots/persistence.png) |
| 4 | Recovery decision | **REBUILD** (root-level persistence, host untrusted) | [assessment](evidence/endpoint/recovery-assessment.txt) |
| 5 | Replacement from baseline AMI | No known persistence found | [assessment](evidence/endpoint/post-recovery-assessment.txt) |

> **The question that mattered was not "is the cron entry gone?" It was "can this host still be trusted?"** After root-level persistence, deleting the entry removes one indicator and proves nothing about the rest.

---

## 🗺️ Architecture at a glance

```
 Operator ──SSM──▶ linux-endpoint ──Wazuh agent──▶ wazuh-server
 (runs the chain)   auditd · FIM · journald  1514/1515   manager + indexer + dashboard
                                                          custom rules 110010/11/12

 Baseline AMI (captured before the attack) ──▶ linux-endpoint-recovery
```

Detailed diagrams, network rules and design decisions: **[`docs/architecture.md`](docs/architecture.md)**

---

## 📂 Repository layout

| Path | Contents |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Infrastructure, data flow, security boundaries |
| [`docs/detection-rules.md`](docs/detection-rules.md) | How each rule works and where it falls short |
| [`docs/incident-report.md`](docs/incident-report.md) | Timeline, analysis, recovery and action items |
| [`docs/lessons-learned.md`](docs/lessons-learned.md) | Gaps left open and what the work taught |
| [`docs/debugging-notes.md`](docs/debugging-notes.md) | Working notes: recovery playbook and fixes made along the way |
| [`terraform-bootstrap/`](terraform-bootstrap) | One-time setup: remote state bucket |
| [`terraform-lab/`](terraform-lab) | The lab: VPC, EC2, IAM, scripts in `userdata/`, `create-baseline-ami.sh` |
| [`evidence/`](evidence/README.md) | Alerts, assessments, screenshots, timeline |

Scripts in `terraform-lab/userdata/`:

| Script | Role |
|---|---|
| `common.sh` | Shared bootstrap: SSM, `ssm-user`, shell tooling |
| `wazuh.sh` | Manager install and the custom rules |
| `linux-endpoint.sh` | Agent install, FIM and auditd forwarding |
| `simulate_soc_chain.sh` | Generates the attack chain on the endpoint |
| `recovery-assessment.sh` | Case-specific persistence check |
| `userdata-logs.sh` | Scans bootstrap logs for real failures |

---

## 🚀 Quick start

**Requirements**

- AWS account and credentials, default region `ap-south-1`
- Terraform ≥ 1.10 for the lab (S3 `use_lockfile`)
- An S3 bucket for the bootstrap scripts, **created beforehand** (the repo does not create it)

```bash
# 1 ─ One-time: create the remote state bucket
cd terraform-bootstrap
terraform init && terraform apply

# 2 ─ Deploy the lab (Wazuh installs at first boot; allow 5 to 10 minutes)
cd ../terraform-lab
terraform init && terraform plan && terraform apply

# 3 ─ Find the dashboard
terraform output
#     Admin password: /home/ssm-user/wazuh-passwords.txt on the manager
#     (connect with SSM Session Manager)

# 4 ─ Capture the known-good baseline BEFORE attacking
./create-baseline-ami.sh

# 5 ─ Run the chain on the endpoint (SSM session)
cd /home/ssm-user && ./simulate_soc_chain.sh
#     then on the manager:
#     sudo grep -E '"id":"(110010|110011|110012|5402)"' /var/ossec/logs/alerts/alerts.json | tail

# 6 ─ Assess the endpoint
sudo ./recovery-assessment.sh
```

<details>
<summary><b>Forking this repo?</b></summary>

<br>

S3 bucket names are global, so they must be unique.

1. Change `aws_account_id_or_suffix` in `terraform-bootstrap/variables.tf`
2. Update the state bucket name in `terraform-lab/backend.tf`
3. Create your own userdata bucket and set `userdata_bucket` in `terraform-lab/variables.tf`
4. Override `linux_endpoint_baseline_ami_id`. The default is an AMI from the recorded run and will not exist in your account.

</details>

<details>
<summary><b>First deploy: the baseline AMI chicken-and-egg</b></summary>

<br>

`linux_endpoint_recovery` is created in the same apply as everything else, but its AMI only exists after you capture one from a running endpoint. On a fresh account, point `linux_endpoint_baseline_ami_id` at any valid AMI for the first apply, run `create-baseline-ami.sh`, then set the variable to the new ID. This workaround is not tested here.

</details>

---

## 🧯 What wasn't completed

Documented in [`docs/lessons-learned.md`](docs/lessons-learned.md), not glossed over:

- The compromised endpoint was **not network-isolated** on detection.
- The compromised endpoint was **not removed** after evidence preservation.
- End-to-end Wazuh telemetry on the **recovered** endpoint was **not re-verified**.
- No `110010` alert appears in the preserved evidence.

---

## ⚠️ Safety notes

- **Lab only.** The persistence payload only appends a marker to `/tmp/soc-lab.log`. Do not point a script like this at systems you don't own.
- **IP allow-listing.** The dashboard and SSH accept traffic only from the public IP that ran `terraform apply`. If it changes, re-apply.
- **Cost.** Three instances bill while running. Destroy the lab when finished.
- **Shared IAM role.** It carries unused, broad Security Group permissions. Scope or remove them before reuse.

---

## 📝 Notes on scope

A personal lab to practice detection engineering and incident-response workflow end to end, not a hardened reference architecture. Deliberate simplifications (single public subnet, no flow logs, single AZ) are listed in [`terraform-lab/.checkov.yaml`](terraform-lab/.checkov.yaml) and [`docs/architecture.md`](docs/architecture.md).
