#!/bin/bash
#
# Wazuh Linux endpoint provisioning (EC2 user-data)
#
# Installs Wazuh Agent, enrolls it with the Wazuh manager,
# and enables real-time File Integrity Monitoring (FIM) plus
# auditd log forwarding (for auditd-tampering / account-manipulation
# detection rules on the manager side).
#
# This script is fully parameterized via environment variables so it can
# be invoked identically by Terraform user-data or run manually:
#
#   WAZUH_MANAGER="10.0.1.10" \
#   WAZUH_REGISTRATION_PASSWORD="..." \
#   WAZUH_AGENT_VERSION="4.14.7-1" \
#   sudo ./linux-endpoint.sh
#

set -euo pipefail

exec > >(tee /var/log/wazuh-install.log | logger -t wazuh-userdata -s 2>/dev/console) 2>&1

trap 'echo "🔴🔴🔴🔴🔴🔴🔴🔴🔴🔴 Wazuh installation FAILED at line $LINENO 🔴🔴🔴🔴🔴🔴🔴🔴🔴🔴"; date' ERR


########################################
# Configuration (supplied by environment)
########################################

WORK_USER="ssm-user"
WORK_HOME="/home/${WORK_USER}"

# Full package version string, e.g. "4.14.7-1"
WAZUH_AGENT_VERSION="${WAZUH_AGENT_VERSION:-4.14.7-1}"
WAZUH_PACKAGE_VERSION="${WAZUH_AGENT_VERSION}"
# Human-readable version (strips the "-<release>" suffix) for logging.
WAZUH_VERSION="${WAZUH_AGENT_VERSION%-*}"

# Wazuh manager address (no default — must be supplied).
WAZUH_MANAGER="${WAZUH_MANAGER:-}"
WAZUH_REGISTRATION_SERVER="${WAZUH_MANAGER}"

# Enrollment password (OPTIONAL). The lab's Wazuh manager (wazuh.sh) runs
# `wazuh-install.sh -a` with no authd password enforcement configured, so
# agents enroll unauthenticated by default. Leave this unset unless/until
# authd is explicitly configured with a password on the manager side.
WAZUH_REGISTRATION_PASSWORD="${WAZUH_REGISTRATION_PASSWORD:-}"

# Agent name defaults to the EC2 hostname if not explicitly supplied.
WAZUH_AGENT_NAME="${WAZUH_AGENT_NAME:-$(hostname -s)}"

# Optional Wazuh agent group.
WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP:-}"

# Set the OS hostname to match the Wazuh agent name, so the instance's
# own hostname and its Wazuh enrollment identity always agree.
hostnamectl set-hostname "${WAZUH_AGENT_NAME}"


########################################
# [1/10] Basic validation
########################################

if [[ -z "${WAZUH_MANAGER}" ]]; then
    echo "ERROR: WAZUH_MANAGER has not been configured (empty)."
    exit 1
fi

if [[ -z "${WAZUH_REGISTRATION_PASSWORD}" ]]; then
    echo "NOTE: WAZUH_REGISTRATION_PASSWORD is empty — enrolling without a password"
    echo "      (this matches the manager's current unauthenticated authd config)."
fi

echo "========================================"
echo "Wazuh Linux Endpoint Provisioning"
echo "========================================"
echo "Agent version : ${WAZUH_VERSION}"
echo "Manager       : ${WAZUH_MANAGER}"
echo "Agent name    : ${WAZUH_AGENT_NAME}"
echo "Started       : $(date)"
echo



########################################
# [2/10] Add Wazuh repository
########################################

echo "[2/10] Configuring Wazuh repository..."

rpm --import https://packages.wazuh.com/key/GPG-KEY-WAZUH

cat > /etc/yum.repos.d/wazuh.repo <<'EOF'
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
EOF

dnf clean all


########################################
# [3/10] Wait for manager to accept enrollment
########################################

echo "[3/10] Waiting for Wazuh manager enrollment port to be reachable..."

MANAGER_READY=false
for i in {1..30}; do
    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/${WAZUH_MANAGER}/1515" 2>/dev/null; then
        echo "✅ Manager ${WAZUH_MANAGER}:1515 is reachable after $((i * 10))s"
        MANAGER_READY=true
        break
    fi
    echo "Waiting for ${WAZUH_MANAGER}:1515... ($((i * 10))s)"
    sleep 10
done

if [[ "${MANAGER_READY}" != true ]]; then
    echo "ERROR: Wazuh manager ${WAZUH_MANAGER}:1515 not reachable after 300s."
    exit 1
fi


########################################
# [4/10] Install exact Wazuh version (idempotent)
########################################

echo "[4/10] Installing Wazuh Agent ${WAZUH_VERSION}..."

if rpm -q wazuh-agent >/dev/null 2>&1; then
    echo "Existing Wazuh agent detected."

    CURRENT_VERSION="$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' wazuh-agent)"
    echo "Current version: ${CURRENT_VERSION}"

    if [[ "${CURRENT_VERSION}" != "${WAZUH_PACKAGE_VERSION}" ]]; then
        echo "Removing existing Wazuh agent..."
        systemctl stop wazuh-agent 2>/dev/null || true
        dnf remove -y wazuh-agent
    else
        echo "Correct Wazuh version already installed."
    fi
fi

if ! rpm -q wazuh-agent >/dev/null 2>&1; then

    if [[ -n "${WAZUH_AGENT_GROUP}" ]]; then

        WAZUH_MANAGER="${WAZUH_MANAGER}" \
        WAZUH_REGISTRATION_SERVER="${WAZUH_REGISTRATION_SERVER}" \
        WAZUH_REGISTRATION_PASSWORD="${WAZUH_REGISTRATION_PASSWORD}" \
        WAZUH_AGENT_NAME="${WAZUH_AGENT_NAME}" \
        WAZUH_AGENT_GROUP="${WAZUH_AGENT_GROUP}" \
        dnf install -y "wazuh-agent-${WAZUH_PACKAGE_VERSION}"

    else

        WAZUH_MANAGER="${WAZUH_MANAGER}" \
        WAZUH_REGISTRATION_SERVER="${WAZUH_REGISTRATION_SERVER}" \
        WAZUH_REGISTRATION_PASSWORD="${WAZUH_REGISTRATION_PASSWORD}" \
        WAZUH_AGENT_NAME="${WAZUH_AGENT_NAME}" \
        dnf install -y "wazuh-agent-${WAZUH_PACKAGE_VERSION}"

    fi

fi


########################################
# [5/10] Verify auditd is installed and running
#
# Required for the manager-side auditd-tampering / account-manipulation
# detection rules to have anything to match against. Checked before the
# FIM/localfile config step below so we never wire up a <localfile> that
# tails a log auditd isn't writing.
########################################

echo "[5/10] Verifying auditd..."

# NOTE: on AL2023 the package is named "audit" (the daemon/service is
# "auditd") — `rpm -q auditd` will incorrectly report "not installed".
if ! rpm -q audit >/dev/null 2>&1; then
    echo "auditd package not found — installing..."
    dnf install -y audit
fi

systemctl enable auditd

if ! systemctl is-active --quiet auditd; then
    echo "auditd not running — starting..."
    systemctl start auditd
fi

if ! systemctl is-active --quiet auditd; then
    echo "ERROR: auditd failed to start."
    systemctl status auditd --no-pager || true
    exit 1
fi

echo "auditd is active: $(rpm -q audit)"


########################################
# [5.5/10] Ensuring Crontab is installed and running
########################################

if ! rpm -q cronie >/dev/null 2>&1; then
    echo "cronie package not found — installing..."
    dnf install -y cronie
fi

systemctl enable crond

if ! systemctl is-active --quiet crond; then
    echo "crond not running — starting..."
    systemctl start crond
fi

if ! systemctl is-active --quiet crond; then
    echo "ERROR: crond failed to start."
    systemctl status crond --no-pager || true
    exit 1
fi

echo "crond is active: $(rpm -q cronie)"

########################################
# [6/10] Configure FIM + auditd forwarding (idempotent, with backup)
#
# NOTE: this step used to be a pure sed script. That approach was fragile
# for two reasons that showed up in practice:
#
#   1. The <syscheck> removal only matched if the opening tag was the
#      *exact* string "<syscheck>" alone on its line and the closing tag
#      was *exactly* "</syscheck>" alone on its line. Any attribute,
#      trailing comment, or formatting difference in the shipped
#      ossec.conf caused the old block to survive, so after inserting a
#      new one the count came out as 2.
#   2. The script never removed *pre-existing* audit-format <localfile>
#      blocks. Wazuh's stock RPM ossec.conf for RHEL/AL2023-family agents
#      already ships with one or more audit localfile stanzas built in,
#      so appending another one produced duplicates (e.g. 3 total).
#
# The fix below matches blocks by content (start tag + matching end tag,
# tolerant of attributes/whitespace) via Python instead of line-anchored
# sed, and explicitly strips any existing audit-format <localfile> block
# before inserting the canonical one. This makes the step idempotent
# regardless of what the shipped default ossec.conf looks like.
########################################

echo "[6/10] Configuring File Integrity Monitoring and auditd forwarding..."

OSSEC_CONF="/var/ossec/etc/ossec.conf"

if [[ ! -f "${OSSEC_CONF}" ]]; then
    echo "ERROR: ${OSSEC_CONF} does not exist."
    exit 1
fi

# Back up the config before modifying it.
BACKUP_CONF="${OSSEC_CONF}.bak.$(date +%Y%m%d%H%M%S)"
cp -p "${OSSEC_CONF}" "${BACKUP_CONF}"
echo "Backed up ossec.conf to ${BACKUP_CONF}"

python3 - "${OSSEC_CONF}" <<'PYEOF'
import re
import sys

path = sys.argv[1]

with open(path, "r") as f:
    content = f.read()

# Remove any existing <syscheck ...>...</syscheck> block(s), tolerant of
# attributes on the opening tag and of leading whitespace/trailing newline.
content = re.sub(
    r'[ \t]*<syscheck\b[^>]*>.*?</syscheck>[ \t]*\n?',
    '',
    content,
    flags=re.DOTALL,
)

# Remove any existing <localfile>...</localfile> block(s) whose log_format
# is "audit" (these ship by default in some Wazuh RPM configs).
def strip_if_audit(match):
    block = match.group(0)
    if re.search(r'<log_format>\s*audit\s*</log_format>', block):
        return ''
    return block

content = re.sub(
    r'[ \t]*<localfile>.*?</localfile>[ \t]*\n?',
    strip_if_audit,
    content,
    flags=re.DOTALL,
)

new_blocks = (
    '  <syscheck>\n'
    '    <disabled>no</disabled>\n'
    '    <scan_on_start>yes</scan_on_start>\n'
    '    <frequency>43200</frequency>\n'
    '    <directories realtime="yes">/etc</directories>\n'
    '  </syscheck>\n'
    '  <localfile>\n'
    '    <log_format>audit</log_format>\n'
    '    <location>/var/log/audit/audit.log</location>\n'
    '  </localfile>\n'
)

if '</ossec_config>' not in content:
    print("ERROR: </ossec_config> closing tag not found.", file=sys.stderr)
    sys.exit(1)

content = content.replace('</ossec_config>', new_blocks + '</ossec_config>', 1)

syscheck_count = len(re.findall(r'<syscheck\b', content))
audit_localfile_count = len(re.findall(r'<log_format>\s*audit\s*</log_format>', content))

if syscheck_count != 1 or audit_localfile_count != 1:
    print(
        f"ERROR: Expected exactly one <syscheck> block and one audit "
        f"<localfile> block; found syscheck={syscheck_count}, "
        f"audit localfile={audit_localfile_count}.",
        file=sys.stderr,
    )
    sys.exit(1)

with open(path, "w") as f:
    f.write(content)
PYEOF

PY_STATUS=$?

if [[ "${PY_STATUS}" -ne 0 ]]; then
    echo "Restoring backup from ${BACKUP_CONF}..."
    cp -p "${BACKUP_CONF}" "${OSSEC_CONF}"
    exit 1
fi

echo "FIM and auditd forwarding configured successfully."


########################################
# [7/10] Validate Wazuh configuration before restart
########################################

echo "[7/10] Validating Wazuh configuration..."

if ! /var/ossec/bin/wazuh-agentd -t; then
    echo "ERROR: Wazuh configuration validation failed."
    echo "Restoring backup from ${BACKUP_CONF}..."
    cp -p "${BACKUP_CONF}" "${OSSEC_CONF}"
    exit 1
fi

echo "Wazuh configuration is valid."


########################################
# [8/10] Enable and start Wazuh agent
########################################

echo "[8/10] Enabling Wazuh agent..."

systemctl daemon-reload
systemctl enable wazuh-agent
systemctl restart wazuh-agent


########################################
# [9/10] Verify installation
########################################

echo "[9/10] Verifying Wazuh agent..."

sleep 5

if ! systemctl is-active --quiet wazuh-agent; then
    echo "ERROR: wazuh-agent is not running."
    systemctl status wazuh-agent --no-pager || true
    exit 1
fi

INSTALLED_VERSION="$(rpm -q --qf '%{VERSION}-%{RELEASE}' wazuh-agent)"

echo
echo "Wazuh agent status:"
systemctl --no-pager --full status wazuh-agent

echo
echo "Installed version: ${INSTALLED_VERSION}"
echo "Expected version : ${WAZUH_PACKAGE_VERSION}"

if [[ "${INSTALLED_VERSION}" != "${WAZUH_PACKAGE_VERSION}" ]]; then
    echo "ERROR: Installed Wazuh version does not match expected version."
    exit 1
fi


########################################
# [10/10] Disable Wazuh repository
########################################

echo "[10/10] Disabling Wazuh repository..."

sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/wazuh.repo


########################################
# Provisioning success marker
########################################

SUCCESS_FILE="${WORK_HOME}/wazuh-provisioned.txt"

cat > "${SUCCESS_FILE}" <<EOF
Wazuh Endpoint Provisioning: SUCCESS

Hostname: ${WAZUH_AGENT_NAME}
Wazuh Agent Version: ${INSTALLED_VERSION}
Wazuh Manager: ${WAZUH_MANAGER}

FIM: ENABLED
FIM Path: /etc
FIM Mode: realtime

Auditd Forwarding: ENABLED
Auditd Log: /var/log/audit/audit.log

Provisioned: $(date)

Wazuh Agent Service:
$(systemctl is-active wazuh-agent)

This file confirms that the EC2 user-data provisioning
script completed successfully.
EOF

chown "${WORK_USER}:${WORK_USER}" "${SUCCESS_FILE}"
chmod 0644 "${SUCCESS_FILE}"


########################################
# Final output
########################################

echo
echo "========================================"
echo "🟢🟢🟢🟢🟢 WAZUH PROVISIONING SUCCESS 🟢🟢🟢🟢🟢"
echo "========================================"
echo
echo "Agent name    : ${WAZUH_AGENT_NAME}"
echo "Agent version : ${INSTALLED_VERSION}"
echo "Manager       : ${WAZUH_MANAGER}"
echo "FIM           : ENABLED"
echo "FIM path      : /etc"
echo "Auditd fwd    : ENABLED"
echo
echo "Success marker:"
echo "${SUCCESS_FILE}"
echo
echo "Completed: $(date)"
echo ""
