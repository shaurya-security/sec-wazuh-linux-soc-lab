# 🧰 SOC Lab: Debugging & Recovery Notes

> **Point-in-time working notes.** Written while building the lab, kept as a record of how decisions were made. Where they differ from the current code or preserved evidence, the code and evidence win. Known differences:
>
> | These notes say | Code / evidence show |
> |---|---|
> | Final working chain was `110010 → 5402 → 5402 → 110012` | Preserved alerts show `5402 → 110011 → 110011 → 110012`. No `110010` alert is preserved. See [`detection-rules.md`](detection-rules.md). |
> | `bat` tarball is verified with `sha256sum -c` (item 5) | `common.sh` verifies the Starship tarball only. `bat` is installed without a checksum check. |
> | FIM/auditd step uses an `awk` comment-aware counter | `linux-endpoint.sh` now rewrites `ossec.conf` with Python regexes and strips existing `syscheck` and audit `localfile` blocks first. |
> | `output_time_ist` was reworked to stop plan noise | `output.tf` still uses `timestamp()`, so it changes on every plan. |
> | A custom auditd-stop rule (T1562.001, placeholder `80730`) was pinned | `wazuh.sh` deploys only `110010`, `110011` and `110012`. |
>
> Related: [`architecture.md`](architecture.md) · [`incident-report.md`](incident-report.md) · [`lessons-learned.md`](lessons-learned.md)

---

*Personal notes. Compiled from working sessions on the Wazuh SOC lab (Terraform / AWS / Wazuh). Covers two threads: the incident recovery playbook (decisions) and the infra/detection debugging (executions).*

---

## 1. Recovery playbook — the decision framework

Core principle: after a root-level compromise, the question isn't *"did I remove the malicious cron job?"* — it's *"what evidence do I have that there isn't another persistence mechanism I haven't found?"*

**Playbook sequence:**

```
INCIDENT CONFIRMED → CONTAINMENT → SCOPE CONFIRMED? → ERADICATION
                                                          ↓
CLOSE ← MONITOR ← RECOVER (rebuild/restore/validate) ←──┘
```

Anti-pattern to avoid: `delete cron → kill process → reboot → declare recovered`. That proves nothing after a root-level compromise.

### First decision: is the host still trustworthy?

- **Can you prove the attacker only changed known things?** → targeted eradication may be acceptable.
- **Can't prove it?** → treat the host as compromised: isolate → preserve evidence → rebuild from known-good state.
- For a host where the attacker reached root, **rebuild is the cleaner recovery boundary**.

### Decision matrix (clean vs. rebuild)

| Condition | Recovery decision |
|---|---|
| Low-privilege compromise, tightly scoped | Targeted cleanup may be acceptable |
| Persistence found but no root | Cleanup + validation |
| Root compromise | **Rebuild (strong preference)** |
| Unknown persistence | **Rebuild** |
| System binaries modified | **Rebuild** |
| Credentials potentially stolen | Rebuild + credential rotation |
| Multiple hosts affected | Broader containment/recovery |
| Critical production system | Follow org recovery/BCP procedure |

### The 8 decision gates

1. **Evidence preserved?** No → stop recovery, don't destroy what you're documenting.
2. **Scope understood?** No → keep investigating (accounts, hosts, persistence, timeline).
3. **Root compromise?** Yes → strongly consider rebuild (the major branch point).
4. **Credentials exposed?** Yes → revoke/rotate.
5. **Persistence eliminated?** Check cron, systemd, SSH, users, sudo, startup mechanisms, scheduled tasks.
6. **Host integrity verified?** If trust can't be established → rebuild.
7. **Detection pipeline verified?** Confirm `endpoint → collector → SIEM → rule → alert` with a controlled test.
8. **Monitoring period clean?** Don't declare victory immediately — watch for repeated sudo activity, new persistence, anomalous auth, unexpected outbound connections.

---

## 2. Containment

**Network**
- Isolate the affected endpoint; block unnecessary outbound traffic.
- Preserve connectivity to logging/forensics infra if required.
- Block known-bad IPs/domains; check whether other hosts contacted the compromised endpoint.

**Identity**
- Determine if credentials were exposed. Candidates to rotate: user password, SSH keys, sudo-capable credentials, service credentials, API tokens, cloud credentials, deployment credentials.
- Don't blindly rotate everything before collecting evidence if credential usage is itself part of the investigation.

## 3. Evidence preservation

Draw a clean line between **what happened** and **what you changed afterward**. Capture:

- Host state: hostname, users, groups, sudo config, running processes, listening sockets, network connections, systemd services, cron/at jobs, SSH config, authorized_keys, recently modified files.
- Security evidence: auth logs, sudo logs, audit logs, endpoint telemetry, SIEM alerts, correlation-rule output.

This is also where evidence screenshots come from.

## 4. Eradication

Malicious cron is an **IOC, not the whole compromise**. Investigate:

```
Persistence surfaces          Other checks
─────────────────────         ─────────────────
/etc/crontab                  new users
/etc/cron.*                   new sudoers entries
/var/spool/cron/              modified sudo config
systemd services/timers       SUID/SGID binaries
~/.config/systemd/            unexpected executables
/etc/rc.local                 /tmp, /var/tmp, /dev/shm
SSH authorized_keys
shell startup files
```

Build a timeline of modified files.

## 5. Recovery build sequence (if rebuilding)

```
1. Preserve evidence          7. Rotate affected credentials
2. Isolate original host      8. Reinstall required software
3. Provision clean OS/image   9. Reconnect logging
4. Patch it                  10. Reconnect endpoint monitoring
5. Apply known-good config   11. Validate security controls
6. Restore only trusted data 12. Return to network
```

Do **not** blindly restore `/etc`, `/usr/local`, `/home`, cron, systemd, SSH config, scripts, or binaries from the untrusted host.

## 6. Recovery validation gate

Before declaring recovery successful:

- **Host integrity:** no malicious cron, no unexpected systemd persistence, no unauthorized users/SSH keys/sudoers rules, no suspicious processes or listening ports.
- **Identity:** required credentials rotated, unauthorized ones revoked, SSH/sudo access verified.
- **Detection:** generate a controlled test event and confirm it flows `sudo → root → SIEM ingestion → correlation rule → SOC alert → MITRE mapping → analyst visibility`.

This last point is the payoff of having already built the logs + correlation + detection pipeline: it proves the recovered host is clean *and* that monitoring still works.

## 7. The five questions the write-up must answer

1. What was compromised?
2. How did the attacker maintain access? *(cron-based persistence, in this case)*
3. How was the compromise removed? *(targeted eradication vs. rebuild, with justification)*
4. How was recovery proven? *(host validation + credential validation + detection pipeline test)*
5. What prevents recurrence? *(hardening + monitoring + correlation rules + response procedure)*

The one section not to gloss over: **"Why did we trust this host enough to clean it instead of rebuilding it?"**

Suggested repo layout for the write-up: `incident/`, `detection/`, `containment/`, `eradication/`, `recovery/`, `evidence/` (6–8 strong screenshots, not 30 mediocre ones), `lessons-learned/`.

---

## 8. Execution log — what actually happened in this lab

### 8.1 Baseline (Golden) AMI

- Decision: build a clean AL2023 instance, install only what the architecture needs, validate `wazuh-agent` / `amazon-ssm-agent` status, listening sockets, enabled units, and crontab — this becomes the definition of "what a healthy endpoint looks like."
- Captured via `aws ec2 create-image --instance-id <id> --name soc-lab-al2023-golden-v1 --no-reboot`, **before** running the attack simulation.
- Follow-up decision: promote this into a **Launch Template** so recovery becomes *launch from template → attach IAM role → SSM online → validate*, instead of manually rebuilding each time.
- Security note surfaced during this: SSM already provides admin access without inbound SSH, so port 22 should eventually be dropped from the security group — no credential rotation is needed for this lab either, since there are no persistent SSH keys, only IAM/SSM. Documented explicitly rather than inventing a rotation step to make the report look more "realistic."

### 8.2 Terraform bug: duplicate `linux_ami_id`

- **Symptom:** `variables.tf` declared `linux_ami_id` twice — once for the generic AL2023 base image, once (mislabeled) for the known-good SOC-baseline image. Terraform rejects duplicate variable declarations.
- **Root cause:** two separate AMI concepts (generic base vs. configured baseline) were conflated into one variable name.
- **Fix:** split into two variables — `linux_ami_id` (generic AL2023, used by Wazuh manager and the normal endpoint) and `linux_endpoint_baseline_ami_id` (known-good baseline, used only by the recovery endpoint). Also fixed a tag bug where `AMI_ID = "var.linux_ami_id"` was a literal string instead of an interpolated reference — changed to `AMI_ID = var.linux_endpoint_baseline_ami_id`.
- **Verification:**
  ```bash
  grep -n 'variable ".*ami' variables.tf
  grep -n 'ami.*=' compute.tf
  terraform fmt
  terraform validate
  ```

### 8.3 Correlation-rule debugging: `simulate_soc_chain.sh`

Goal: script the event chain `sudo-to-sudo-group → sudo→root ×2 → root crontab edit` on the endpoint so the correlation rules fire on the manager.

**Round 1 — wrong commands for the target rules:**
- `usermod -aG sudo` does **not** trigger Wazuh rule `2961` — that rule is a child of `2960` and expects a `gpasswd`-decoded event containing "added by". Fix: use `sudo gpasswd -a "$TEST_USER" sudo` instead.
- Root crontab rule `2833` (chain `2830 → 2832 REPLACE → 2833 REPLACE (root)`) needs the actual `crontab[...]: (root) REPLACE (root)` syslog/journal line — modifying the crontab file alone doesn't guarantee that event exists or is forwarded.

**Round 2 — events exist locally but alerts don't fire:**
- Verified directly on the endpoint that both target events *were* being generated:
  - `gpasswd[...]: user ssm-user added by root to group sudo`
  - `crontab[...]: (root) REPLACE (root)` and `crond[...]: RELOAD (/var/spool/cron/root)`
- But `2961` and `2833` never appeared in `alerts.json`, while the sudo-based rule `5402` and the custom correlation rules `110011`/`110012` fired fine.
- Diagnosis path used:
  ```bash
  # on the endpoint — is the agent connected?
  sudo systemctl status wazuh-agent --no-pager
  sudo grep -E 'Connected to|Unable to connect|Lost connection' /var/ossec/logs/ossec.log | tail -20

  # on the manager — is the raw event arriving at all?
  sudo grep -R -F 'user ssm-user added by root to group sudo' /var/ossec/logs/ 2>/dev/null | tail -20
  sudo grep -R -F '(root) REPLACE (root)' /var/ossec/logs/ 2>/dev/null | tail -20

  # on the endpoint — is journald actually being collected?
  sudo grep -n -A5 -B2 '<localfile>' /var/ossec/etc/ossec.conf
  ```
- Conclusion: generating an event locally is not the same as Wazuh *collecting* it — the gap was in log collection/forwarding for those specific sources, not in the correlation logic itself.
- Working decision: rather than chase the exact stock rule IDs (`2961`/`2833`) through the collection gap, the lab moved to **custom rules `110010`/`110012`** built directly around the events the endpoint reliably forwards (sudo group change + root crontab modification), keeping `5402` (sudo success) and `110011` (repeated sudo→root) as the reliable middle of the chain.
- Final observed, working chain: `110010 → 5402 → 5402 → 110012`, run with a 5-second gap between steps so the correlation window has time to evaluate.

### 8.4 Simulated incident timeline (evidence artifact)

Produced as the actual timeline document for the write-up:

```
PRE-INCIDENT   Baseline AMI captured (soc-lab-linux-endpoint-baseline-...)
ATTACK         5402 (sudo success) → 110011 (repeated sudo→root) ×several
               → 110012 (high-severity: repeated root sudo + crontab mod)
INVESTIGATION  ssm-user in sudo group; root crontab holds persistence entry;
               /tmp/soc-lab.log shows repeated executions under the cron job
DECISION       REBUILD — root-level persistence confirmed, host treated as untrusted
RECOVERY       Replacement endpoint launched from the pre-incident baseline AMI
```

### 8.5 `.gitignore` for the Terraform repo

Decision: block anything that could leak local state, secrets, or lab-generated noise before publishing to GitHub. Categories covered:
- Terraform core: local provider cache, local state files (since S3/DynamoDB backend is used instead), plan/crash logs, local var files with secrets.
- Local environment noise: Python runtime artifacts in the incidents directory, OS/editor indexing files.
- Security safeguards: any identity/key file accidentally dropped into the repo.

### 8.6 Lessons-learned (documented gaps, not silently skipped)

Rather than artificially extending the exercise to close every gap, the following were written up explicitly as known limitations:

1. **Endpoint isolation** — the compromised endpoint was not isolated from the network immediately after detection; it stayed reachable during evidence collection.
2. **Compromised host lifecycle** — the original compromised instance was not terminated after the recovery endpoint was validated; it was kept around for evidence but its removal was never executed or logged.
3. **Post-recovery telemetry validation** — Wazuh agent connectivity, log ingestion, and detection functionality on the *new* recovered endpoint were never independently re-verified end-to-end.

Recommended wording for the report (avoids overclaiming): *"The replacement endpoint was successfully provisioned from the known-good pre-compromise AMI and passed the targeted persistence assessment. End-to-end post-recovery Wazuh telemetry validation was not performed."*

---

## 9. Infra/provisioning code review — bugs found and fixed

Separate thread: a full code review of the Terraform + shell provisioning stack, working through severity tiers.

### Security

| # | Issue | Resolution |
|---|---|---|
| 1 | `wazuh_security_group` IAM policy allowed `ec2:AuthorizeSecurityGroupIngress`/`RevokeSecurityGroupIngress` on `Resource = "*"` — any SG in the account | Deferred: scope to the specific SG ARN once active-response is actually wired up (see #2). Currently unused, so dead but should be tightened before use. |
| 2 | Active-response block in `wazuh.sh` writes an **empty heredoc** to `ossec.conf` — the comment claims it takes effect, but nothing is appended | Left intentionally empty for now — plan is to verify alerting works correctly first, then decide per-scenario which gets active response vs. manual remediation. |
| 3 | `wazuh_registration_password` marked `sensitive = true` in Terraform but shipped as plaintext in EC2 user-data (readable via `DescribeInstanceAttribute` or from inside the instance) | Acceptable for now — default is `""`, code was pre-written for future use. Revisit via SSM Parameter Store (SecureString) if a real password is ever set. |
| 4 | Unescaped secret interpolated directly into a shell script (`linux-endpoint.sh.tpl`) — breaks or shell-injects if the password ever contains `"`, `` ` ``, `$`, `\` | Same as #3 — dormant risk, deferred until a real password is used (base64 encode/decode would be the fix). |
| 5 | Unverified downloads in `common.sh`: Starship installed via `curl \| sh` with no signature check; `bat` tarball pulled from GitHub releases with no checksum | **Fixed.** Pinned Starship to a specific verified version; added `sha256sum -c` verification for the `bat` tarball, computed once against a manually-verified copy and hardcoded. |

### Bugs

| # | Issue | Resolution |
|---|---|---|
| 6 | `alias history='history -i'` in `common.sh` — `-i` is not a valid `history` flag; every `history` call for `ssm-user` errors out | **Fixed** — alias removed. |
| 7 | Placeholder rule ID (`80730`) left un-replaced in a custom Wazuh rule for detecting auditd stop (T1562.001); comment says to replace it but never was | Investigated: rule ID depends on how the agent collects and forwards logs, and which ruleset version is installed — confirmed against the live ruleset (`/var/ossec/ruleset/rules/*audit*`) and pinned. |
| 8 | Enrollment race condition — `linux_endpoint` only depends on `wazuh` at the *resource* level, not on the manager's user-data finishing (which the manager script itself notes can take 5–10 min); agent enrollment silently fails if the manager isn't listening on 1515 yet | **Fixed** — added a bounded wait-for-port loop against `$WAZUH_MANAGER:1515` before the `dnf install` step, consistent with existing retry loops elsewhere in the script. |
| 9 | Unbounded background loop in `wazuh.sh` polling the dashboard health API — every other wait-loop in the script is bounded, this one isn't; can become an orphaned process if the API never reports healthy | **Fixed** — added a retry cap. |
| 10 | `output_time_ist` Terraform output uses `timestamp()`, which changes on every run — shows as "changed" on every `plan`/`apply` even with no real diff | **Fixed** — reworked into a cleaner IST-formatted output that doesn't create constant plan noise. |

### Minor / style (deferred, tracked)

- Hardcoded bucket name repeated across `s3.tf`, `compute.tf` (×2), `iam.tf`, both `.sh.tpl` files — should become a `local`/`variable`. *(Deferred.)*
- Output names with trailing dashes (`wazuh_private_ip----`) — intentional, for CLI alignment.
- Manager pinned loosely (`WAZUH_VERSION="4.14"`, floats to latest patch) vs. agent pinned exactly (`4.14.7-1`) — possible future patch-version mismatch, noted.
- `linux_endpoint_sg` still allows SSH from the operator's IP despite SSM management — redundant attack surface; candidate for removal once the lab's brute-force testing notes (`t.txt`) are no longer needed.
- No `aws_eip` — public IPs shift on stop/start and can silently break SG rules computed from a point-in-time IP lookup.

### Follow-on debugging sessions

- **`history` alias, FIM/auditd forwarder, checksum block, wait-for-port loop, bounded health loop, IST timestamp fix** — all delivered as concrete patch blocks and applied.
- **Marker file change** — provisioning completion marker at `/root/provisioned.txt` changed from a plain `echo` to a `tee` heredoc, with richer content; final log message updated to match.
- **Starship install failure** — pinned-checksum install script debugged and corrected.
- **`bat`/`cat` false positive** — a detection rule was flagging legitimate `bat` usage as suspicious; fixed by adjusting the rule logic rather than the install.
- **Wazuh rule install failure (`rule` vs `group`)** — install failed because the custom rules file was being registered under the wrong config key; corrected to use the right directive.
- **Unbound variable crash: `wazuh_agent_name`** — `linux-endpoint.sh` referenced `${wazuh_agent_name}` (Terraform-style, lowercase) but that file is a *raw* script uploaded to S3, not run through `templatefile()`. Bash saw it as an unset variable and `set -u` killed the script.
  - **Fix 1** (`linux-endpoint.sh`): read as a real bash env var with a runtime fallback — `WAZUH_AGENT_NAME="${WAZUH_AGENT_NAME:-$(hostname -s)}"`.
  - **Fix 2** (`linux-endpoint.sh.tpl`, which *does* go through `templatefile()`): export `WAZUH_AGENT_NAME="${wazuh_agent_name}"` alongside the existing env vars before invoking the script.
  - **Fix 3**: confirmed `compute.tf` already passed `wazuh_agent_name = var.wazuh_agent_name` into the `templatefile()` call — no change needed there.
  - **Rule of thumb going forward:** `.tpl` files are Terraform template sources → `${lowercase}` Terraform vars are correct there. Plain `.sh` files are literal, already-substituted scripts → they must only reference real bash env vars (`${UPPERCASE}`), never Terraform syntax.
- **FIM/auditd config step false failure** — the provisioning script's safety check counted `<syscheck>`/`<localfile>` blocks with a plain `grep -c`, which matched **commented-out example blocks** shipped in the stock `ossec.conf` (inside `<!-- -->`), triggering a false "duplicate block" error and a safe rollback.
  - **Fix:** replaced the counting logic with a comment-aware `awk` state machine (`count_outside_comments()`) that tracks whether it's inside a `<!-- -->` block line-by-line, so genuinely separate comment blocks don't get over-matched. Backup/restore-on-failure behavior and the delete-then-insert `sed` logic were left unchanged.

---

## 10. Recurring workflow pattern

Across both threads, the same discipline shows up repeatedly:

1. **Reproduce and verify locally** before trusting a fix (`wazuh-analysisd -t` before restarting the manager; manual `gpasswd`/`crontab` tests before touching the simulation script).
2. **Separate the templated layer from the runtime layer** — Terraform `.tpl` interpolation vs. real bash env vars was the root cause of two separate bugs.
3. **Don't assume "event generated" means "event collected."** Local journald activity and manager-side ingestion are two different failure domains — check both independently.
4. **When a stock detection rule doesn't reliably fire through the pipeline, build a custom rule around what the environment actually forwards**, rather than chasing an upstream rule ID indefinitely.
5. **Document gaps instead of quietly closing them out of scope** — isolation, host teardown, and post-recovery telemetry validation were explicitly left as "not completed" rather than glossed over.
