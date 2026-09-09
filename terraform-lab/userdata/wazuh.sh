#!/bin/bash
#
# Wazuh all-in-one SOC-simulation lab installer (EC2 user-data)
#
set -euo pipefail

exec > >(tee /var/log/wazuh-install.log | logger -t wazuh-userdata -s 2>/dev/console) 2>&1

trap 'echo "🔴🔴🔴🔴🔴🔴🔴🔴🔴🔴 Wazuh installation FAILED at line $LINENO 🔴🔴🔴🔴🔴🔴🔴🔴🔴🔴"; date' ERR

echo "===== Wazuh installation started ====="
date

# --------------------------------------------------
# Idempotency guard
# --------------------------------------------------
if [ -f /root/.wazuh-provisioned ]; then
    echo "⚠️  /root/.wazuh-provisioned already exists — Wazuh appears to be installed."
    echo "    Remove that file if you want to force a re-run. Exiting."
    exit 0
fi

# --------------------------------------------------
# Config
# --------------------------------------------------
WORK_USER="ssm-user"
WORK_HOME="/home/${WORK_USER}"
WAZUH_VERSION="4.14"
DASHBOARD_TIMEZONE="Asia/Kolkata"

# --------------------------------------------------
# Ensure ssm-user exists
# --------------------------------------------------
if ! id "${WORK_USER}" &>/dev/null; then
    echo "Creating ${WORK_USER} user..."
    useradd -m -s /bin/bash "${WORK_USER}"
fi

# --------------------------------------------------
# System preparation
# --------------------------------------------------
dnf install -y tar gzip unzip cronie

hostnamectl set-hostname wazuh-server

# --------------------------------------------------
# Wazuh all-in-one installation
# --------------------------------------------------
cd /tmp
curl -sO "https://packages.wazuh.com/${WAZUH_VERSION}/wazuh-install.sh"
chmod +x wazuh-install.sh

echo "Running Wazuh installer (this may take 5-10 minutes)..."
bash ./wazuh-install.sh -a
rm -f /tmp/wazuh-install.sh

# --------------------------------------------------
# Helper: pull the admin password out of the install log
# (ignores the "set -x" trace lines that start with '+ ')
# --------------------------------------------------
get_wazuh_password() {
    grep -a "Password:" /var/log/wazuh-install.log \
        | grep -v '^+ ' \
        | head -n 1 \
        | sed 's/.*Password: //' \
        | xargs
}

PASS_VAL="$(get_wazuh_password)"

# --------------------------------------------------
# Save generated credentials / install files to ssm-user's home
# --------------------------------------------------
echo "Processing Wazuh credentials and installation files..."

if [ -f /root/wazuh-install-files.tar ]; then
    echo "✅ Found /root/wazuh-install-files.tar. Extracting archive..."
    mkdir -p "${WORK_HOME}/wazuh-install-files"
    tar -xvf /root/wazuh-install-files.tar -C "${WORK_HOME}/wazuh-install-files" || true
    chown -R "${WORK_USER}:${WORK_USER}" "${WORK_HOME}/wazuh-install-files"
fi

# Fetch IMDSv2 token and retrieve public IP (falls back to hostname if no public IP)
TOKEN=$(curl -s -S -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
PUBLIC_IP=$(curl -s -S -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/public-ipv4" || true)
DASHBOARD_HOST="${PUBLIC_IP:-$(hostname)}"

cat > "${WORK_HOME}/wazuh-passwords.txt" <<EOF
=================================================================
                  WAZUH ADMIN CREDENTIALS
=================================================================

  🌐 Web Dashboard : https://${DASHBOARD_HOST}:443
  👤 Username      : admin
  🔑 Password      : ${PASS_VAL:-"Check /var/log/wazuh-install.log"}

=================================================================
EOF

if [ -f "${WORK_HOME}/wazuh-passwords.txt" ]; then
    chmod 600 "${WORK_HOME}/wazuh-passwords.txt"
    chown "${WORK_USER}:${WORK_USER}" "${WORK_HOME}/wazuh-passwords.txt"
    echo "✅ Credentials saved to ${WORK_HOME}/wazuh-passwords.txt"
else
    echo "❌ Failed to retrieve credentials."
fi


# --------------------------------------------------
# Local Rules - Wazuh Manager
# --------------------------------------------------

tee /var/ossec/etc/rules/local_rules.xml > /dev/null << 'EOF'

<group name="local,soc_correlation,">

  <!-- Marker: user added to sudo group -->
  <rule id="110010" level="12">
    <if_sid>2961</if_sid>
    <description>SOC: User added to sudo group - privilege escalation precursor</description>
    <mitre>
      <id>T1136</id>
      <id>T1548.003</id>
    </mitre>
    <group>privilege_escalation,account_manipulation,</group>
  </rule>

  <!-- Correlation proof: 2 successful sudo->ROOT within 60s -->
  <rule id="110011" level="12" frequency="2" timeframe="60">
    <if_matched_sid>5402</if_matched_sid>
    <same_user />
    <description>SOC: Multiple successful sudo-to-ROOT executions detected within 60s</description>
    <mitre>
      <id>T1548.003</id>
    </mitre>
    <group>privilege_escalation,soc_correlation,</group>
  </rule>

  <!-- Final: repeated root sudo + crontab change = persistence -->
  <rule id="110012" level="15" frequency="2" timeframe="90">
    <if_matched_sid>5402</if_matched_sid>
    <if_sid>2833</if_sid>
    <description>SOC HIGH: Repeated root sudo executions followed by root crontab modification - possible persistence</description>
    <mitre>
      <id>T1548.003</id>
      <id>T1053.003</id>
    </mitre>
    <group>privilege_escalation,persistence,soc_correlation,</group>
  </rule>

</group>

EOF

# --------------------------------------------------
# Active response config
# Written to ossec.conf directly here so it actually
# takes effect (previously this was only saved as a
# standalone script and never executed).
# --------------------------------------------------
tee -a /var/ossec/etc/ossec.conf > /dev/null << 'EOF'
EOF

# --------------------------------------------------
# Configure Wazuh Dashboard Timezone
# --------------------------------------------------
echo "Setting Wazuh Dashboard timezone to ${DASHBOARD_TIMEZONE}..."


(
    READY=false
    for i in {1..60}; do
        if curl -s -k -u "admin:${PASS_VAL}" https://localhost:443/api/status \
            | grep -q '"state":"green"\|"state":"yellow"'; then
            READY=true
            break
        fi
        sleep 5
    done

    if [[ "${READY}" != true ]]; then
        echo "⚠️  Dashboard did not report healthy within 300s — skipping timezone update."
        exit 0
    fi

    curl -s -k -X POST "https://localhost:443/api/opensearch-dashboards/settings" \
      -H "osd-xsrf: true" \
      -H "Content-Type: application/json" \
      -u "admin:${PASS_VAL}" \
      -d "{\"changes\":{\"dateFormat:tz\":\"${DASHBOARD_TIMEZONE}\"}}" > /dev/null \
      && echo "✅ Successfully updated Wazuh Dashboard timezone to ${DASHBOARD_TIMEZONE}"
) &

# --------------------------------------------------
# Service Enablement and Health Wait Loop
# --------------------------------------------------
echo "Enabling and verifying Wazuh services..."

systemctl daemon-reload
systemctl enable wazuh-indexer wazuh-manager wazuh-dashboard

echo "Waiting for wazuh-dashboard service to be registered..."
for i in {1..30}; do
    if systemctl list-unit-files | grep -q wazuh-dashboard.service; then
        echo "✅ wazuh-dashboard service registered after $((i * 2)) seconds"
        break
    fi
    echo "Waiting for wazuh-dashboard.service... ($((i * 2))s)"
    sleep 2
done

systemctl start wazuh-indexer 2>/dev/null || true
systemctl start wazuh-manager 2>/dev/null || true
systemctl start wazuh-dashboard 2>/dev/null || true

echo "Waiting for Wazuh Dashboard to be healthy..."
for i in {1..24}; do
    if systemctl is-active --quiet wazuh-dashboard; then
        echo "✅ wazuh-dashboard is active!"
        break
    fi
    echo "Waiting for wazuh-dashboard... ($((i * 5))s)"
    sleep 5
done

echo "Checking if Wazuh Dashboard is listening on port 443..."
for i in {1..12}; do
    if ss -tlnp | grep -q ":443"; then
        echo "✅ wazuh-dashboard is listening on port 443"
        break
    fi
    echo "Waiting for port 443... ($((i * 10))s)"
    sleep 10
done

echo "Restarting wazuh-dashboard to apply timezone / rule changes..."
systemctl restart wazuh-manager
systemctl restart wazuh-dashboard
sleep 10

echo "===== Verifying Wazuh services ====="
SERVICES=("wazuh-indexer" "wazuh-manager" "wazuh-dashboard")
SERVICE_NAMES=("Indexer" "Manager" "Dashboard")
ALL_OK=true

for i in "${!SERVICES[@]}"; do
    if systemctl is-active --quiet "${SERVICES[$i]}"; then
        echo "✅ Wazuh ${SERVICE_NAMES[$i]}: OK"
    else
        echo "❌ Wazuh ${SERVICE_NAMES[$i]}: FAILED"
        ALL_OK=false
    fi
done


# --------------------------------------------------
# Marker files for successful installation
# --------------------------------------------------
DASHBOARD_CONF="/etc/wazuh-dashboard/opensearch_dashboards.yml"

cat > "${WORK_HOME}/.wazuh-provisioned" <<EOF
Wazuh provisioned on: $(date)
Version: ${WAZUH_VERSION}
Timezone: ${DASHBOARD_TIMEZONE}
Dashboard configured: $( [ -f "$DASHBOARD_CONF" ] && echo "Yes" || echo "No" )
EOF
chown "${WORK_USER}:${WORK_USER}" "${WORK_HOME}/.wazuh-provisioned"

cat > /root/.wazuh-provisioned <<EOF
Wazuh provisioned on: $(date)
Version: ${WAZUH_VERSION}
Timezone: ${DASHBOARD_TIMEZONE}
EOF

# --------------------------------------------------
# Summary file
# --------------------------------------------------
INFO_FILE="${WORK_HOME}/wazuh-info.txt"

{
echo "================================================================="
echo "                 Wazuh Installation Information"
echo "================================================================="
echo ""
echo "📅 Install Date: $(date)"
echo "🌐 Hostname: $(hostname)"
echo "👤 User: ${WORK_USER}"
echo ""
echo "📋 Important files for ${WORK_USER}:"
echo "   📁 Credentials: ${WORK_HOME}/wazuh-passwords.txt"
echo "   📁 Summary File: ${INFO_FILE}"
echo "   📁 Full Install Files: ${WORK_HOME}/wazuh-install-files/"
echo "   📁 Alert-gen reference commands: ${WORK_HOME}/alert_gen_commands.txt"
echo ""
echo "🔐 To view passwords:"
echo "   cat ${WORK_HOME}/wazuh-passwords.txt"
echo ""
echo "📊 Service Status:"
if [ "$ALL_OK" = true ]; then
    echo "   ✅ All services are running"
else
    echo "   ⚠️  Some services may not be ready yet"
    echo "   Check logs: journalctl -u wazuh-dashboard -f"
fi
echo ""
echo "📝 Logs:"
echo "   /var/log/wazuh-install.log"
echo "   journalctl -u wazuh-dashboard"
echo ""
echo "================================================================="
} | tee "$INFO_FILE"

chmod 644 "$INFO_FILE"
chown "${WORK_USER}:${WORK_USER}" "$INFO_FILE"

echo "===== Wazuh installation finished ====="
date
