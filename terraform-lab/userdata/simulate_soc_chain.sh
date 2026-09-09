#!/usr/bin/env bash
#
# simulate_soc_chain.sh
# Run this ON THE ENDPOINT (not the Wazuh manager).
#
# Generates the observed event chain:
#   110010 -> 5402 -> 5402 -> 110012
#
# with a 5s gap between events so the Wazuh correlation rules
# 110011 / 110012 have a chance to fire on the manager.
#
# Requires:
#   - TEST_USER already exists
#   - TEST_USER has passwordless sudo
#     (for example, TEST_USER ALL=(ALL) NOPASSWD:ALL in /etc/sudoers.d/)
#
# Note:
#   110010 and 110012 are custom SOC lab rules.
#   5402 is the Wazuh sudo-success rule.
#

set -euo pipefail

TEST_USER="${1:-ssm-user}"
GAP=5

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

# Validate test user exists.
if ! id "${TEST_USER}" >/dev/null 2>&1; then
    log "ERROR: User '${TEST_USER}' does not exist."
    exit 1
fi

# Ensure the sudo group exists.
if ! getent group sudo >/dev/null; then
    log "[0/4] Sudo group not found. Creating sudo group..."
    sudo groupadd sudo
fi

log "=== SOC correlation chain simulation for user: ${TEST_USER} ==="

# --- Step 1: custom rule 110010 ---------------------------------------
log "Step 1/4: adding ${TEST_USER} to sudo group (-> rule 110010)"
sudo gpasswd -a "${TEST_USER}" sudo
sleep "${GAP}"

# --- Step 2: rule 5402 - successful sudo -> ROOT ----------------------
log "Step 2/4: first successful sudo->ROOT (-> rule 5402, occurrence 1)"
sudo -u "${TEST_USER}" sudo -n whoami
sleep "${GAP}"

# --- Step 3: rule 5402 - successful sudo -> ROOT ----------------------
# Repeated successful sudo activity contributes to rule 110011.
log "Step 3/4: second successful sudo->ROOT (-> rule 5402, occurrence 2)"
sudo -u "${TEST_USER}" sudo -n whoami
sleep "${GAP}"

# --- Step 4: custom rule 110012 - root crontab modification ----------
log "Step 4/4: modifying root's crontab (-> rule 110012)"

(
    sudo crontab -l 2>/dev/null
    echo '*/5 * * * * /bin/echo SOC_LAB_PERSISTENCE_TEST >> /tmp/soc-lab.log'
) | sudo crontab -

sleep "${GAP}"

log "=== Simulation complete. Check the Wazuh manager: ==="
log "sudo tail -n 50 /var/ossec/logs/alerts/alerts.json | grep -E '\"id\":\"(110010|110011|110012|5402)\"'"
