# 📓 Lessons Learned

What building, attacking, recovering and documenting this lab taught me. Gaps are listed as gaps.

**Contents:** [Exercise status](#-exercise-status) · [Gaps in the recovery](#-gaps-in-the-recovery-exercise) · [Detection](#-detection-lessons) · [Engineering](#-engineering-lessons) · [Security](#-security-lessons) · [Evidence quality](#-evidence-quality) · [Open questions](#-open-questions) · [Takeaway](#-key-takeaway)

---

## 📊 Exercise status

| Stage | Status |
|---|:-:|
| Detection | ✅ Completed |
| Correlation | ✅ Completed |
| Persistence validation | ✅ Completed |
| Evidence preservation | ✅ Completed |
| Known-good AMI recovery | ✅ Completed |
| Post-recovery assessment | ✅ Completed |
| Endpoint isolation | ❌ Not completed |
| Compromised host removal | ❌ Not completed |
| Post-recovery Wazuh validation | ❌ Not completed |

The three open items are limitations of this exercise and candidates for a future one.

---

## 🕳️ Gaps in the recovery exercise

### 1. Endpoint isolation

The compromised endpoint was **not isolated** after detection. It stayed reachable during evidence collection and recovery.

> **Lesson:** isolate as part of containment, while keeping what the investigation needs. In AWS this can be as simple as moving the instance to a deny-all Security Group.

### 2. Compromised endpoint lifecycle

The original compromised instance has **not been removed**. Evidence was collected and the replacement was provisioned, but the old instance is still in the environment, in the same Security Group and with the same IAM role as the recovered one.

> **Lesson:** after evidence preservation and recovery validation, stop or terminate the host and record the action.

### 3. Post-recovery telemetry

The recovered endpoint passed the targeted persistence assessment, but **end-to-end Wazuh telemetry was not verified**. A future exercise should confirm:

- agent connectivity
- log ingestion by the manager
- event visibility in the indexer
- detection and correlation firing
- a controlled test alert after recovery

> **Lesson:** a clean host that nobody can see is not a recovered host.

### 4. What did work

A known-good AMI captured *before* the simulation let a replacement be provisioned quickly. Future runs should build containment, host lifecycle and telemetry validation into the procedure.

Suggested wording for reports, so nothing is overclaimed:

> *The replacement endpoint was provisioned from the known-good pre-compromise AMI and passed the targeted persistence assessment. End-to-end post-recovery Wazuh telemetry validation was not performed.*

---

## 🎯 Detection lessons

| Lesson | Detail |
|---|---|
| **Generated is not collected** | An event can exist in the local journal and never reach the manager. Check the endpoint and the manager separately. |
| **Build around what is forwarded** | During diagnosis, stock `2961` and `2833` did not show up as alerts while `5402` did. Rather than chase them, custom rules were built around the events that were reliably forwarded. (`110012` still uses `2833` as its trigger, and the evidence shows it matched.) |
| **Pick the command that matches the rule** | `usermod -aG sudo` does not trigger stock `2961`. `gpasswd -a` does. The crontab rule needs the real `REPLACE (root)` log line. |
| **Timing is part of the rule** | The 5 s gap in the script exists so events land inside the 60 s and 90 s windows. |
| **Your own investigation trips the rules** | Assessment commands run under `sudo` raised `110011`. Expect analyst activity in the alert stream, and filter for it. |
| **Verify the chain, not only the end** | The preserved evidence shows `110011` and `110012` firing but no `110010`. A final alert can hide a silent first step. |

---

## 🛠️ Engineering lessons

| # | Lesson | Why it matters |
|:-:|---|---|
| 1 | **Separate template layer from runtime layer** | `.tpl` files go through `templatefile()` and use `${lowercase}` Terraform variables. Plain `.sh` files are uploaded as-is and may only use real shell variables. Mixing them caused two separate bugs, including an unbound-variable crash under `set -u`. |
| 2 | **Hash-driven rebuilds are a feature and a trap** | `filemd5()` into `user_data` with `user_data_replace_on_change` makes script edits reliably replace instances. It also means a harmless edit to `common.sh` rebuilds the manager and the endpoint. |
| 3 | **Keep the AMI concepts apart** | A generic base image and a configured baseline image were conflated into one variable, which Terraform rejected as a duplicate. They are now `linux_ami_id` and `linux_endpoint_baseline_ami_id`. |
| 4 | **Bound every wait loop** | An unbounded dashboard health poll could become an orphan process. Enrollment also raced the manager install, fixed with a bounded wait on port 1515. |
| 5 | **Match config by structure, not by line** | A plain `grep -c` counted commented-out example blocks in the stock `ossec.conf`, producing a false failure. The current script rewrites the config with regexes and validates it before restart. |
| 6 | **Back up, validate, roll back** | The agent step copies `ossec.conf`, runs `wazuh-agentd -t`, and restores on failure. |
| 7 | **Pin what can drift** | The agent is pinned to an exact version. The manager is pinned only to the `4.14` branch, so a patch mismatch is possible. |
| 8 | **Don't invent steps to look thorough** | No credential rotation was added for an SSM-only setup with no SSH keys. The notes say so instead. |

---

## 🔐 Security lessons

| Lesson | Detail |
|---|---|
| **Rebuild beats clean after root** | Removing the cron entry removes one indicator. It does not prove nothing else changed. The decision matrix in the [debugging notes](debugging-notes.md) puts root compromise at "rebuild". |
| **Verify each remediation** | A successful command is not proof. Check the resulting state, as the post-recovery assessment does. |
| **A targeted assessment is not proof of integrity** | The post-recovery output itself says the clean result "does not constitute proof of full host integrity". |
| **Shared roles widen the blast radius** | All three instances share one IAM role. It includes `ec2:AuthorizeSecurityGroupIngress` and `RevokeSecurityGroupIngress` on `*`, currently unused. Root on the endpoint could reach those credentials. Scope or remove it. |
| **Redundant access paths are attack surface** | SSH (22) is open to the operator IP although access is via SSM and no key pairs exist. |
| **Verify downloads** | Starship is checksum-verified. `bat` is not. |
| **Secrets in user-data are readable** | A registration password would appear in plain text in user-data. It is empty by default, so the risk is dormant. Use Parameter Store if it is ever set. |

---

## 🧾 Evidence quality

Writing the incident report meant cross-checking the notes, timeline, alert exports and screenshots. They did not fully agree.

| Item | Finding |
|---|---|
| **Date** | `timeline.txt` says 2026-09-08. Alert exports and the dashboard show 2026-09-09. The dashboard's time range starts on Sep 8, which may be the source. |
| **Log entries** | The timeline says eight persistence entries. The assessment output and screenshot show two. |
| **Post-recovery time** | The timeline says 13:04:24. The assessment output says 13:09:02. |
| **Which commands ran** | The alerts match steps 2 to 4 of `simulate_soc_chain.sh`, but step 1 was `usermod -aG sudo`, not the script's `gpasswd -a`. |
| **Notes vs code** | The debugging notes describe fixes (e.g. `bat` checksum) that the code does not contain. See the banner in [`debugging-notes.md`](debugging-notes.md). |

> **Lesson:** write the evidence trail from machine output, not memory, and re-read it against the artifacts before publishing.

---

## ❓ Open questions

| Question | Why it matters |
|---|---|
| Why is there no `110010` alert in the evidence? | The first rule in the chain is unproven. |
| Does an AMI cloned from an enrolled agent keep its enrollment identity? | If the recovered endpoint reuses the original agent's key or name, the manager may reject or conflate it. This could explain why telemetry wasn't confirmed. It is untested. |
| How long did detect-to-recover take? | Recovery launch time was not recorded. |
| Should the CI workflow live at the repo root? | It sits under `terraform-lab/.github/`, where GitHub does not read it. See [`architecture.md`](architecture.md). |

---

## 🧭 Key takeaway

Detection engineering does not end at an alert, and recovery does not end at a clean file listing.

```
baseline → attack → detect → correlate → investigate → decide → preserve → rebuild → validate → monitor
```

The steps this lab did not finish (isolate, remove, re-verify telemetry) are the ones that separate "recovered" from "restored and trusted". Writing them down plainly was part of the exercise.

---

📎 Related: [`incident-report.md`](incident-report.md) · [`detection-rules.md`](detection-rules.md) · [`architecture.md`](architecture.md) · [`debugging-notes.md`](debugging-notes.md)
