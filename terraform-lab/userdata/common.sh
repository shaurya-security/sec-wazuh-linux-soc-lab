#!/bin/bash
set -euxo pipefail

# --------------------------------------------------------------------
# Enable Amazon SSM Agent
# --------------------------------------------------------------------
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# --------------------------------------------------------------------
# Wait until outbound Internet is available
# --------------------------------------------------------------------
echo "Waiting for Internet connectivity..."

until curl -fsSL https://github.com >/dev/null 2>&1; do
    sleep 5
done

echo "Internet is available."

# --------------------------------------------------------------------
# Set working user and home directory
# --------------------------------------------------------------------
WORK_USER="ssm-user"
WORK_HOME="/home/${WORK_USER}"

# Ensure ssm-user exists
if ! id "${WORK_USER}" &>/dev/null; then
    echo "Creating ${WORK_USER} user..."
    useradd -m -s /bin/bash "${WORK_USER}"

    echo "ssm-user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ssm-agent-users
    chmod 0440 /etc/sudoers.d/ssm-agent-users
fi

# Create necessary directories
mkdir -p "${WORK_HOME}/.local/bin"
mkdir -p "${WORK_HOME}/.config"
mkdir -p "${WORK_HOME}/.cache/starship"


# Set timezone
timedatectl set-timezone "${timezone:-Asia/Kolkata}"


# --------------------------------------------------------------------
# Install common packages
# --------------------------------------------------------------------
dnf install -y \
    git \
    nano \
    jq \
    tree \
    tmux \
    wget

# --------------------------------------------------------------------
# Install Starship (verified, pinned version)
# --------------------------------------------------------------------
echo "Installing Starship prompt..."

STARSHIP_VERSION="1.21.1"   # pin explicitly; bump deliberately
STARSHIP_TARBALL="starship-x86_64-unknown-linux-musl.tar.gz"
STARSHIP_BASE_URL="https://github.com/starship/starship/releases/download/v${STARSHIP_VERSION}"

cd /tmp
curl -LO "${STARSHIP_BASE_URL}/${STARSHIP_TARBALL}"
curl -LO "${STARSHIP_BASE_URL}/${STARSHIP_TARBALL}.sha256"

EXPECTED_HASH="$(tr -d '[:space:]' < "${STARSHIP_TARBALL}.sha256")"
ACTUAL_HASH="$(sha256sum "${STARSHIP_TARBALL}" | awk '{print $1}')"

if [[ "${EXPECTED_HASH}" != "${ACTUAL_HASH}" ]]; then
    echo "ERROR: Starship checksum mismatch."
    echo "Expected: ${EXPECTED_HASH}"
    echo "Actual  : ${ACTUAL_HASH}"
    exit 1
fi

echo "✅ Starship checksum verified."

tar -xzf "${STARSHIP_TARBALL}"
install -m 0755 starship "${WORK_HOME}/.local/bin/"
rm -f "${STARSHIP_TARBALL}" "${STARSHIP_TARBALL}.sha256" starship

# Add to PATH in .bashrc
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "${WORK_HOME}/.bashrc" \
    || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${WORK_HOME}/.bashrc"

# Add Starship init to .bashrc
grep -qxF 'eval "$(starship init bash)"' "${WORK_HOME}/.bashrc" \
    || echo 'eval "$(starship init bash)"' >> "${WORK_HOME}/.bashrc"

# --------------------------------------------------------------------
# Compact Starship Configuration
# --------------------------------------------------------------------
cat > "${WORK_HOME}/.config/starship.toml" <<'STARSHIP'
# ============================================
# ✨ Starship Prompt Configuration
# ============================================

add_newline = false
scan_timeout = 30

# -------- Main Format --------
format = """
$hostname\
$directory\
$git_branch\
$git_status\
$time\
$character\
"""

# -------- Username (Disabled) --------
[username]
disabled = true

# -------- Hostname --------
[hostname]
ssh_only = false
disabled = false
format = "🛰️ [@$hostname](bold green) "

# -------- Directory --------
[directory]
truncation_length = 3
truncation_symbol = "…/"
format = "[$path](bold cyan) "
style = "bold"

# -------- Git Branch --------
[git_branch]
format = "🌿 [$branch](bold yellow) "
symbol = ""
style = "bold"

# -------- Git Status --------
[git_status]
format = "([$all_status$ahead_behind](yellow)) "
staged = "✨"
modified = "📝"
untracked = "❓"
deleted = "🗑️"
renamed = "🔄"
conflicted = "⚡"
ahead = "↑"
behind = "↓"

# -------- Time --------
[time]
disabled = false
format = "⏱️ [$time](dimmed white) "
time_format = "%H:%M:%S"
style = "dimmed white"

# -------- Character --------
[character]
success_symbol = "[❯](bold green) "
error_symbol = "[✗](bold red) "
vicmd_symbol = "[❮](bold yellow) "

# -------- Battery --------
[battery]
full_symbol = "🔋"
charging_symbol = "⚡"
discharging_symbol = "🔋"
unknown_symbol = "🔋"
empty_symbol = "🪫"
format = "[$symbol$percentage]($style) "
display = [
    { threshold = 20, style = "red bold" },
    { threshold = 50, style = "yellow bold" },
]

# -------- Command Duration --------
[cmd_duration]
format = "⏳ [$duration]($style) "
style = "yellow"
min_time = 2000

# -------- Line Break --------
[line_break]
disabled = false

# -------- Fill --------
[fill]
symbol = " "
style = "bold"

STARSHIP

# --------------------------------------------------------------------
# Install bat (with proper variable substitution)
# --------------------------------------------------------------------
echo "Installing bat..."
VERSION="0.25.0"

curl -LO "https://github.com/sharkdp/bat/releases/download/v${VERSION}/bat-v${VERSION}-x86_64-unknown-linux-musl.tar.gz"

tar -xzf "bat-v${VERSION}-x86_64-unknown-linux-musl.tar.gz"

install \
    "bat-v${VERSION}-x86_64-unknown-linux-musl/bat" \
    /usr/local/bin/

rm -rf "bat-v${VERSION}-x86_64-unknown-linux-musl"*

# --------------------------------------------------------------------
# Add aliases and customizations to .bashrc
# --------------------------------------------------------------------
cat >> "${WORK_HOME}/.bashrc" <<'BASHRC'

# ============================================
# Custom Aliases
# ============================================
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias l='ls -l --color=auto'
alias cls='clear'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'
alias df='df -h'
alias du='du -h'
alias free='free -h'
alias psg='ps aux | grep -v grep | grep -i'
alias mkdir='mkdir -pv'
alias ping='ping -c 4'
alias ip='ip -c'
alias tree='tree -C'

# Use bat if available
if command -v bat &>/dev/null; then
    alias less='bat --paging=always'
    cat() {
        if [[ "$*" == /var/log/* ]] || [[ "$*" == *.log ]]; then
            command cat "$@"
        else
            bat --style=header --paging=never "$@"
        fi
    }
fi

# ============================================
# Welcome Message
# ============================================
echo
echo "🛰️  Connected to $(hostname) | User: $(whoami)"
echo "📅 $(date '+%Y-%m-%d %H:%M:%S')"
echo "💡 Type 'starship --help' for prompt customization"
echo

BASHRC

# --------------------------------------------------------------------
# Set proper ownership
# --------------------------------------------------------------------
chown -R "${WORK_USER}:${WORK_USER}" "${WORK_HOME}"

# --------------------------------------------------------------------
# Marker file
# --------------------------------------------------------------------
tee /root/provisioned.txt <<EOF > /dev/null
Provisioned successfully on $(date)

/var/log/wazuh-install.log
EOF

echo "Provisioned for ${WORK_USER} on $(date)" > "${WORK_HOME}/provisioned.txt"
chown "${WORK_USER}:${WORK_USER}" "${WORK_HOME}/provisioned.txt"

# --------------------------------------------------------------------
# Final message
# --------------------------------------------------------------------
echo "=========================================="
echo "✅ Bootstrap completed successfully!"
echo "=========================================="
echo "User: ${WORK_USER}"
echo "Home: ${WORK_HOME}"
echo "Starship: $(su - ${WORK_USER} -c 'starship --version' 2>/dev/null || echo 'installed')"
echo "Bat: $(bat --version 2>/dev/null || echo 'installed')"
echo "/var/log/wazuh-install.log"
echo "=========================================="
