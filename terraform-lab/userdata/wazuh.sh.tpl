#!/bin/bash
# Script Hash: ${script_hash}
# Common Hash: ${common_hash}
set -euxo pipefail
exec > >(tee /var/log/wazuh_bootstrap.log | logger -t wazuh_bootstrap -s 2>/dev/console) 2>&1

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


# --------------------------------------------------
# Step 4: Download and run wazuh.sh from S3
# --------------------------------------------------
echo "🔐 Running Wazuh installation..."
s3_download "wazuh.sh" "/tmp/wazuh.sh"
chmod +x /tmp/wazuh.sh
/tmp/wazuh.sh

# --------------------------------------------------
# Step 5: Cleanup
# --------------------------------------------------
rm -f /tmp/common.sh /tmp/wazuh.sh

echo "===== Bootstrap Complete ====="
date
