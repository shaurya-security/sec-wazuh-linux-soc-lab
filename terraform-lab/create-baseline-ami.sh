#!/usr/bin/env bash
set -euo pipefail

# ========================================
# SOC Lab - Linux Endpoint Baseline AMI
# Creates a known-good AMI BEFORE simulation
# ========================================

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# Helper functions
print_header() {
    echo -e "\n${BLUE}${BOLD}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BLUE}${BOLD}  🛡️  SOC LAB - LINUX ENDPOINT BASELINE AMI  🛡️  ${RESET}"
    echo -e "${BLUE}${BOLD}════════════════════════════════════════════════════════════${RESET}\n"
}

print_section() {
    echo -e "\n${MAGENTA}${BOLD}◆◆◆ ${1} ◆◆◆${RESET}\n"
}

print_info() {
    echo -e "${CYAN}${BOLD}➜${RESET} ${1}"
}

print_success() {
    echo -e "${GREEN}${BOLD}✓${RESET} ${1}"
}

print_error() {
    echo -e "${RED}${BOLD}✗${RESET} ${1}"
}

print_warning() {
    echo -e "${YELLOW}${BOLD}⚠${RESET} ${1}"
}

print_step() {
    echo -e "\n${MAGENTA}${BOLD}◆${RESET} ${1}"
}

print_key_value() {
    printf "${YELLOW}  %-14s${RESET} ${BOLD}%s${RESET}\n" "$1:" "$2"
}

print_box() {
    echo -e "${BLUE}${BOLD}┌─────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BLUE}${BOLD}│${RESET} $1"
    echo -e "${BLUE}${BOLD}└─────────────────────────────────────────────────────────┘${RESET}"
}

# Spinner function
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Get instance and region info
INSTANCE_ID="$(terraform output -raw linux_endpoint_instance_id 2>/dev/null || echo "")"
REGION="$(aws configure get region 2>/dev/null || echo "")"

# Clear screen for fancy presentation
clear

# Main header
print_header

# Validation
if [[ -z "$INSTANCE_ID" ]]; then
    echo
    print_error "Could not determine Linux endpoint instance ID."
    echo -e "${RED}${BOLD}  💡${RESET} Make sure Terraform has been applied and output is available."
    exit 1
fi

if [[ -z "$REGION" ]]; then
    echo
    print_error "AWS region is not configured."
    echo -e "${RED}${BOLD}  💡${RESET} Run 'aws configure' to set your region."
    exit 1
fi

# Display instance details
echo
echo -e "${BLUE}${BOLD}┌─────────────────────────────────────────────────────────┐${RESET}"
echo -e "${BLUE}${BOLD}│${RESET} ${WHITE}${BOLD}📋 INSTANCE INFORMATION${RESET}                              ${BLUE}${BOLD}│${RESET}"
echo -e "${BLUE}${BOLD}├─────────────────────────────────────────────────────────┤${RESET}"
print_key_value "Instance" "${GREEN}${INSTANCE_ID}${RESET}"
print_key_value "Region" "${CYAN}${REGION}${RESET}"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
AMI_NAME="soc-lab-linux-endpoint-baseline-${TIMESTAMP}"
print_key_value "AMI Name" "${MAGENTA}${AMI_NAME}${RESET}"
echo -e "${BLUE}${BOLD}└─────────────────────────────────────────────────────────┘${RESET}"

# Create AMI
echo
print_step "Creating known-good baseline AMI..."
echo -e "${DIM}  This may take a few minutes...${RESET}"

# Create AMI with spinner
(
    AMI_ID="$(
        aws ec2 create-image \
            --region "$REGION" \
            --instance-id "$INSTANCE_ID" \
            --name "$AMI_NAME" \
            --description "Known-good Linux SOC lab endpoint baseline before attack simulation" \
            --no-reboot \
            --query 'ImageId' \
            --output text 2>/dev/null
    )"
    echo "$AMI_ID" > /tmp/ami_id.txt
) &

SPINNER_PID=$!
spinner $SPINNER_PID
wait $SPINNER_PID

AMI_ID="$(cat /tmp/ami_id.txt 2>/dev/null || echo "")"
rm -f /tmp/ami_id.txt

if [[ -z "$AMI_ID" ]]; then
    echo
    print_error "Failed to create AMI. Check AWS permissions and instance state."
    exit 1
fi

print_success "AMI created: ${GREEN}${BOLD}${AMI_ID}${RESET}"

# Wait for AMI to become available
echo
print_step "Waiting for AMI to become available..."
echo

# Progress bar
PROGRESS=0
while [[ $PROGRESS -le 100 ]]; do
    # Check if AMI is available
    AMI_STATE="$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI_ID" --query 'Images[0].State' --output text 2>/dev/null || echo 'pending')"
    
    if [[ "$AMI_STATE" == "available" ]]; then
        PROGRESS=100
    elif [[ "$AMI_STATE" == "failed" ]]; then
        echo -e "\n${RED}${BOLD}✗ AMI creation failed!${RESET}"
        exit 1
    fi
    
    # Draw progress bar
    BAR_LENGTH=40
    FILLED=$((PROGRESS * BAR_LENGTH / 100))
    EMPTY=$((BAR_LENGTH - FILLED))
    
    echo -ne "\r  ${BLUE}${BOLD}[${RESET}"
    for ((i=0; i<FILLED; i++)); do echo -ne "${GREEN}${BOLD}█${RESET}"; done
    for ((i=0; i<EMPTY; i++)); do echo -ne "${DIM}░${RESET}"; done
    echo -ne "${BLUE}${BOLD}]${RESET} ${WHITE}${BOLD}${PROGRESS}%${RESET} "
    
    if [[ "$AMI_STATE" == "available" ]]; then
        echo -ne "${GREEN}✓${RESET}\n"
        break
    fi
    
    # Wait and increment
    sleep 3
    if [[ $PROGRESS -lt 90 ]]; then
        PROGRESS=$((PROGRESS + 3))
    elif [[ $PROGRESS -lt 95 ]]; then
        PROGRESS=$((PROGRESS + 1))
    fi
done

# Success summary
echo
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  ✨  BASELINE AMI SUCCESSFULLY CREATED  ✨${RESET}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${RESET}"

echo
print_key_value "AMI ID" "${GREEN}${BOLD}${AMI_ID}${RESET}"
print_key_value "AMI Name" "${CYAN}${AMI_NAME}${RESET}"
print_key_value "Region" "${YELLOW}${REGION}${RESET}"
print_key_value "Source" "${MAGENTA}${INSTANCE_ID}${RESET}"
print_key_value "Created" "${WHITE}$(date '+%Y-%m-%d %H:%M:%S %z')${RESET}"

# Save reference file
REFERENCE_FILE="ami_reference_${TIMESTAMP}.txt"

cat > "$REFERENCE_FILE" <<EOF
SOC Lab - Linux Endpoint Baseline AMI
=====================================

AMI ID:     ${AMI_ID}
AMI Name:   ${AMI_NAME}
Region:     ${REGION}
Created:    $(date '+%Y-%m-%d %H:%M:%S %z')
Source:     Instance ${INSTANCE_ID}

Purpose:
Known-good endpoint image captured immediately before
the controlled SOC attack simulation.

Recovery:
Provision a replacement Linux endpoint from this AMI.
EOF

print_success "Reference saved to: ${YELLOW}${REFERENCE_FILE}${RESET}"

# Next steps
echo
echo -e "${BLUE}${BOLD}┌─────────────────────────────────────────────────────────┐${RESET}"
echo -e "${BLUE}${BOLD}│${RESET} ${WHITE}${BOLD}📝  NEXT STEPS${RESET}                                      ${BLUE}${BOLD}│${RESET}"
echo -e "${BLUE}${BOLD}├─────────────────────────────────────────────────────────┤${RESET}"

STEPS=(
    "Pin this AMI ID in Terraform"
    "Verify the endpoint is clean"
    "Run simulate_soc_chain.sh"
    "Preserve incident evidence"
    "Rebuild from this AMI"
)

for i in "${!STEPS[@]}"; do
    NUM=$((i+1))
    echo -e "${BLUE}${BOLD}│${RESET}  ${CYAN}${NUM}.${RESET} ${STEPS[$i]}"
    if [[ $i -lt $((${#STEPS[@]} - 1)) ]]; then
        echo -e "${BLUE}${BOLD}│${RESET}"
    fi
done
echo -e "${BLUE}${BOLD}└─────────────────────────────────────────────────────────┘${RESET}"

echo
echo -e "${GREEN}${BOLD}🎯 Ready for the next phase!${RESET}"
echo -e "${DIM}  Remember: A good baseline is the foundation of great forensics.${RESET}\n"

# Colorful goodbye
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║${RESET}  ${WHITE}Keep this AMI safe - it's your "undo button" for the lab!${RESET}  ${CYAN}${BOLD}║${RESET}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}\n"
