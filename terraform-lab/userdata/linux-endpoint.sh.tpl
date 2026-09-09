#!/bin/bash
# Common Hash: ${common_hash}
# Linux Endpoint Script Hash: ${linux_endpoint_hash}
set -euxo pipefail
exec > >(tee /var/log/linux_bootstrap.log | logger -t linux_bootstrap -s 2>/dev/console) 2>&1

BUCKET="${s3_bucket}"

# --------------------------------------------------
# Helper: download a file from S3 with retries
# --------------------------------------------------
s3_download() {
    local key="$1"
    local dest="$2"
    for i in {1..5}; do
        aws s3 cp "s3://$BUCKET/$key" "$dest" && return 0
        echo "S3 copy failed for $key, retrying in 5 seconds... ($i/5)"
        sleep 5
    done
    echo "❌ Failed to download $key after 5 attempts."
    return 1
}

# --------------------------------------------------
# Helper: fetch a helper script into ssm-user's home dir
# --------------------------------------------------
install_ssm_user_script() {
    local key="$1"
    local dest="/home/ssm-user/$key"
    s3_download "$key" "$dest"
    if [ -f "$dest" ]; then
        chmod 700 "$dest"
        chown "ssm-user:ssm-user" "$dest"
        echo "✅ Script saved to $dest"
    else
        echo "❌ Failed to save $key."
    fi
}

# --------------------------------------------------
# Step 1: Ensure AWS CLI Installation
# --------------------------------------------------
if ! command -v aws &> /dev/null; then
    echo "📦 Installing AWS CLI..."
    dnf install -y awscli2 || dnf install -y aws-cli
fi

# --------------------------------------------------
# Step 2: Download and run common.sh from S3
# --------------------------------------------------
echo "📦 Running common bootstrap..."
s3_download "common.sh" "/tmp/common.sh"
chmod +x /tmp/common.sh
/tmp/common.sh

# --------------------------------------------------
# Step 3: Install ssm-user helper scripts
# --------------------------------------------------
echo "📦 Setting Up Userdata Error Finder..."
install_ssm_user_script "userdata-logs.sh"

echo "📦 Setting Up Recovery Assessment..."
install_ssm_user_script "recovery-assessment.sh"

echo "📦 Setting Up Simulating soc chain"
install_ssm_user_script "simulate_soc_chain.sh"

# --------------------------------------------------
# Step 4: Download and run linux-endpoint.sh
# --------------------------------------------------
echo "📦 Provisioning Wazuh Linux endpoint..."
s3_download "linux-endpoint.sh" "/tmp/linux-endpoint.sh"
chmod +x /tmp/linux-endpoint.sh

# Configuration is passed in explicitly from Terraform, exactly the same
# pattern used by the Windows script's [string]$WazuhManagerIP parameter.
# This keeps linux-endpoint.sh independently reusable outside Terraform too.
#
# WAZUH_REGISTRATION_PASSWORD is OPTIONAL — the manager (wazuh.sh) currently
# runs authd without password enforcement, so this may be an empty string.
# It's wired through now so enabling a real authd password later only
# requires setting var.wazuh_registration_password, no script changes.
WAZUH_MANAGER="${wazuh_manager_ip}" \
WAZUH_REGISTRATION_PASSWORD="${wazuh_registration_password}" \
WAZUH_AGENT_VERSION="${wazuh_agent_version}" \
WAZUH_AGENT_NAME="${wazuh_agent_name}" \
/tmp/linux-endpoint.sh

# --------------------------------------------------
# Step 5: Cleanup
# --------------------------------------------------
rm -f /tmp/common.sh
rm -f /tmp/linux-endpoint.sh

echo "===== Bootstrap Complete ====="
date
