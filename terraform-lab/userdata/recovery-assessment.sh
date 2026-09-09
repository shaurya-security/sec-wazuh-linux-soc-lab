#!/usr/bin/env bash
#
# recovery-assessment.sh
#
# Case-specific recovery assessment for the SOC correlation-chain lab.
#
# Relevant chain:
#   2961  -> user added to sudo group
#   5402  -> successful sudo -> ROOT
#   5402  -> successful sudo -> ROOT
#   2833  -> root crontab modification
#              |
#              v
#        recurring persistence
#
# This is NOT a general forensic scanner.
# It deliberately checks only artifacts directly relevant to this case.
#
# Run:
#   sudo ./recovery-assessment.sh [TEST_USER]
#

set -uo pipefail

TEST_USER="${1:-ssm-user}"
PERSISTENCE_MARKER="SOC_LAB_PERSISTENCE_TEST"
CRON_PATTERN="$PERSISTENCE_MARKER"
LOG_FILE="/tmp/soc-lab.log"

HOST="$(hostname)"
NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# ------------------------------------------------------------
# Colors
# ------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ------------------------------------------------------------
# Formatting
# ------------------------------------------------------------

line() {
    printf '%*s\n' 72 '' | tr ' ' '='
}

section() {
    echo
    line
    echo -e "${BOLD}${CYAN}[$1]${NC}"
    line
}

command_block() {
    echo
    echo -e "${BOLD}${YELLOW}COMMAND :${NC} $1"
    echo -e "${WHITE}$2${NC}"
}

finding() {
    echo -e "${BOLD}${GREEN}FINDING :${NC} $1"
}

reason() {
    echo -e "${BOLD}${BLUE}REASON  :${NC} $1"
}

next_step() {
    echo -e "${BOLD}${MAGENTA}NEXT    :${NC} $1"
}

status_ok() {
    echo -e "${GREEN}✓ $1${NC}"
}

status_warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

status_error() {
    echo -e "${RED}✗ $1${NC}"
}

status_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

# ------------------------------------------------------------
# State
# ------------------------------------------------------------

ROOT_CRON=""
SUDO_GROUP=""
PERSISTENCE_FOUND=0
PERSISTENCE_EXECUTED=0
SUDO_MEMBERSHIP_FOUND=0

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

echo -e "${BOLD}${CYAN}======================================================================"
echo " Linux Endpoint — Recovery Assessment"
echo "======================================================================"
echo -e "${NC}"
echo -e "${WHITE} Host    :${NC} $HOST"
echo -e "${WHITE} Time    :${NC} $NOW"
echo -e "${WHITE} Case    :${NC} SOC correlation-chain persistence scenario"
echo -e "${WHITE} User    :${NC} $TEST_USER"
echo
echo -e "${BOLD}Scope:${NC}"
echo -e "   • sudo-group modification"
echo -e "   • successful sudo → ROOT activity"
echo -e "   • root crontab persistence"
echo -e "   • persistence execution"
echo -e "   • immediate recovery decision"
echo

# ============================================================
# 01 — PRIVILEGED GROUP STATE
# ============================================================

section "01 — SUDO GROUP STATE"

SUDO_GROUP="$(getent group sudo 2>/dev/null || true)"

command_block \
    "getent group sudo" \
    "${SUDO_GROUP:-<sudo group not present>}"

if [[ "$SUDO_GROUP" == *":${TEST_USER}"* ||
      "$SUDO_GROUP" == *":${TEST_USER},"* ]]; then

    SUDO_MEMBERSHIP_FOUND=1

    echo -e "${GREEN}FINDING : OBSERVED — $TEST_USER is currently a member of sudo.${NC}"
    echo -e "${BLUE}REASON  : This matches the simulated 2961 step and confirms the account currently has sudo-group membership.${NC}"
    echo -e "${MAGENTA}NEXT    : Correlate the membership change with the original alert timeline; do not treat membership alone as proof of compromise.${NC}"

else

    echo -e "${YELLOW}FINDING : NOT PRESENT — $TEST_USER is not currently listed in sudo.${NC}"
    echo -e "${BLUE}REASON  : The simulated privileged-group state is no longer present.${NC}"
    echo -e "${MAGENTA}NEXT    : Continue validating the remaining persistence and recovery state.${NC}"
fi


# ============================================================
# 02 — ROOT CRONTAB
# ============================================================

section "02 — ROOT CRONTAB"

ROOT_CRON="$(sudo crontab -l 2>/dev/null || true)"

command_block \
    "sudo crontab -l" \
    "${ROOT_CRON:-<no root crontab>}"

if grep -Fq "$PERSISTENCE_MARKER" <<< "$ROOT_CRON"; then

    PERSISTENCE_FOUND=1

    echo -e "${RED}FINDING : CONFIRMED — lab persistence remains installed in root's crontab.${NC}"
    echo -e "${BLUE}REASON  : The root crontab contains the exact persistence command created by the simulated 2833 step.${NC}"
    echo -e "${MAGENTA}NEXT    : Preserve the evidence. Do not rely on deleting this entry as proof that the host is trustworthy.${NC}"

else

    echo -e "${GREEN}FINDING : CLEAN — known lab persistence entry is absent from root's crontab.${NC}"
    echo -e "${BLUE}REASON  : The specific persistence mechanism created by the simulation is not currently installed.${NC}"
    echo -e "${MAGENTA}NEXT    : Validate the persistence output and continue recovery assessment.${NC}"
fi


# ============================================================
# 03 — CRON SPOOL CORROBORATION
# ============================================================

section "03 — ROOT CRON SPOOL CORROBORATION"

ROOT_SPOOL="$(sudo find /var/spool/cron /var/spool/cron/crontabs \
    -maxdepth 1 \
    -type f \
    -user root \
    -printf '%p owner=%u mode=%m modified=%TY-%Tm-%Td %TH:%TM:%TS\n' \
    2>/dev/null || true)"

command_block \
    "find root cron spool files" \
    "${ROOT_SPOOL:-<no root-owned cron spool file found>}"

if [[ -n "$ROOT_SPOOL" ]]; then
    echo -e "${GREEN}FINDING : EXPECTED — root cron spool exists.${NC}"
    echo -e "${BLUE}REASON  : The spool file is the backing storage for the root crontab and corroborates that root cron configuration exists.${NC}"
    echo -e "${MAGENTA}NEXT    : Use the crontab contents, rather than spool-file existence, as the persistence determination.${NC}"
else
    echo -e "${YELLOW}FINDING : CLEAN — no root-owned cron spool file found.${NC}"
    echo -e "${BLUE}REASON  : No root cron spool artifact was returned by this check.${NC}"
    echo -e "${MAGENTA}NEXT    : Continue to execution validation.${NC}"
fi


# ============================================================
# 04 — PERSISTENCE EXECUTION
# ============================================================

section "04 — PERSISTENCE EXECUTION"

if [[ -f "$LOG_FILE" ]]; then

    LINE_COUNT="$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)"
    MARKER_COUNT="$(grep -Fc "$PERSISTENCE_MARKER" "$LOG_FILE" 2>/dev/null || echo 0)"
    LAST_LINE="$(tail -n 1 "$LOG_FILE" 2>/dev/null || true)"

    RESULT="lines=$LINE_COUNT
marker_matches=$MARKER_COUNT
last_line=$LAST_LINE"

    command_block \
        "wc -l /tmp/soc-lab.log; grep -Fc '$PERSISTENCE_MARKER' /tmp/soc-lab.log; tail -n 1 /tmp/soc-lab.log" \
        "$RESULT"

    if (( MARKER_COUNT > 0 )); then

        PERSISTENCE_EXECUTED=1

        echo -e "${RED}FINDING : CONFIRMED — persistence has executed successfully.${NC}"
        echo -e "${BLUE}REASON  : The expected marker is present in /tmp/soc-lab.log, demonstrating execution of the scheduled persistence command.${NC}"
        echo -e "${MAGENTA}NEXT    : Treat the endpoint as compromised until recovery is completed.${NC}"

    else

        echo -e "${GREEN}FINDING : CLEAN — persistence marker not observed in the output file.${NC}"
        echo -e "${BLUE}REASON  : The known lab persistence command has not produced the expected marker.${NC}"
        echo -e "${MAGENTA}NEXT    : Continue with the recovery decision.${NC}"
    fi

else

    command_block \
        "test -f /tmp/soc-lab.log" \
        "<file does not exist>"

    echo -e "${GREEN}FINDING : CLEAN — persistence output file is absent.${NC}"
    echo -e "${BLUE}REASON  : The known persistence output artifact is not present.${NC}"
    echo -e "${MAGENTA}NEXT    : Continue with recovery assessment.${NC}"
fi


# ============================================================
# 05 — PERSISTENCE FILE METADATA
# ============================================================

section "05 — PERSISTENCE ARTIFACT METADATA"

if [[ -e "$LOG_FILE" ]]; then

    META="$(stat -c 'path=%n
owner=%U:%G
mode=%a
size=%s
modified=%y' "$LOG_FILE" 2>/dev/null || true)"

    command_block \
        "stat /tmp/soc-lab.log" \
        "$META"

    echo -e "${YELLOW}FINDING : OBSERVED — persistence output artifact exists.${NC}"
    echo -e "${BLUE}REASON  : The file is the expected output target of the root cron command.${NC}"
    echo -e "${MAGENTA}NEXT    : Preserve it as incident evidence; do not use the file alone to determine host integrity.${NC}"

else

    echo -e "${GREEN}FINDING : CLEAN — persistence output artifact does not exist.${NC}"
    echo -e "${BLUE}REASON  : No metadata is available because the expected output file is absent.${NC}"
    echo -e "${MAGENTA}NEXT    : Continue to final decision.${NC}"
fi


# ============================================================
# 06 — TARGETED PERSISTENCE SEARCH
# ============================================================

section "06 — TARGETED PERSISTENCE SEARCH"

TARGETED_MATCHES="$(sudo grep -RFl \
    "$PERSISTENCE_MARKER" \
    /etc/cron.d \
    /etc/cron.daily \
    /etc/cron.hourly \
    /etc/cron.weekly \
    /etc/cron.monthly \
    /var/spool/cron \
    /var/spool/cron/crontabs \
    2>/dev/null || true)"

command_block \
    "grep -RFl '$PERSISTENCE_MARKER' targeted cron locations" \
    "${TARGETED_MATCHES:-<no additional matching persistence locations>}"

MATCH_COUNT="$(printf '%s\n' "$TARGETED_MATCHES" | sed '/^$/d' | wc -l)"

if (( MATCH_COUNT > 1 )); then

    echo -e "${YELLOW}FINDING : REVIEW — persistence marker appears in multiple cron locations.${NC}"
    echo -e "${BLUE}REASON  : More than one cron location references the same lab persistence marker.${NC}"
    echo -e "${MAGENTA}NEXT    : Inspect each matching file before recovery.${NC}"

else

    echo -e "${GREEN}FINDING : CLEAN — no additional cron location contains the known persistence marker.${NC}"
    echo -e "${BLUE}REASON  : Only the known root-cron mechanism was identified by this targeted search.${NC}"
    echo -e "${MAGENTA}NEXT    : Proceed to final recovery decision.${NC}"
fi


# ============================================================
# FINAL DECISION
# ============================================================

section "FINAL RECOVERY DECISION"

if (( PERSISTENCE_FOUND == 1 || PERSISTENCE_EXECUTED == 1 )); then

    echo -e "${BOLD}${RED}DECISION       : REBUILD${NC}"
    echo -e "${BOLD}${YELLOW}RECOVERY STATE : PRE-RECOVERY${NC}"
    echo

    echo -e "${BOLD}WHAT WAS FOUND${NC}"
    echo -e "  ${RED}• Root-level persistence is confirmed.${NC}"
    echo -e "  ${RED}• The persistence command has executed successfully.${NC}"
    echo -e "  ${YELLOW}• The persistence mechanism is directly tied to the simulated${NC}"
    echo -e "    ${YELLOW}2833 root-crontab modification.${NC}"
    echo -e "  ${RED}• The endpoint therefore cannot be considered trustworthy${NC}"
    echo -e "    ${RED}based on targeted cleanup alone.${NC}"
    echo

    echo -e "${BOLD}REASONING${NC}"
    echo -e "  The assessment confirms the attack chain reached a privileged"
    echo -e "  persistence stage. Removing the known cron entry would remove"
    echo -e "  the observed IOC, but would not establish that no additional"
    echo -e "  modification or persistence exists."
    echo

    echo -e "${BOLD}${GREEN}RECOVERY ACTION${NC}"
    echo -e "  ${WHITE}1.${NC} Preserve the current endpoint and evidence."
    echo -e "  ${WHITE}2.${NC} Isolate the endpoint."
    echo -e "  ${WHITE}3.${NC} Rebuild from a known-good image."
    echo -e "  ${WHITE}4.${NC} Rotate potentially exposed credentials."
    echo -e "  ${WHITE}5.${NC} Restore required configuration from trusted sources."
    echo -e "  ${WHITE}6.${NC} Reinstall/validate Wazuh telemetry."
    echo -e "  ${WHITE}7.${NC} Validate log ingestion and correlation rules."
    echo -e "  ${WHITE}8.${NC} Perform a controlled detection test."
    echo -e "  ${WHITE}9.${NC} Return the endpoint to service only after validation."

elif (( SUDO_MEMBERSHIP_FOUND == 1 )); then

    echo -e "${BOLD}${YELLOW}DECISION       : FURTHER VALIDATION REQUIRED${NC}"
    echo -e "${BOLD}${YELLOW}RECOVERY STATE : ASSESSMENT${NC}"
    echo
    echo -e "${BOLD}WHAT WAS FOUND${NC}"
    echo -e "  ${YELLOW}• The test account currently has sudo-group membership.${NC}"
    echo -e "  ${GREEN}• The known persistence artifact was not detected.${NC}"
    echo
    echo -e "${BOLD}REASONING${NC}"
    echo -e "  Privileged access remains present, but this assessment did not"
    echo -e "  find the known persistence mechanism. That is insufficient to"
    echo -e "  declare the endpoint clean."
    echo
    echo -e "${BOLD}${MAGENTA}NEXT STEP${NC}"
    echo -e "  Compare the current host against a known-good baseline before"
    echo -e "  choosing targeted remediation or rebuild."

else

    echo -e "${BOLD}${GREEN}DECISION       : NO KNOWN PERSISTENCE FOUND${NC}"
    echo -e "${BOLD}${YELLOW}RECOVERY STATE : ASSESSMENT${NC}"
    echo
    echo -e "${BOLD}REASONING${NC}"
    echo -e "  The artifacts associated with this specific lab chain were not"
    echo -e "  observed. This does not constitute proof of full host integrity."
    echo
    echo -e "${BOLD}${MAGENTA}NEXT STEP${NC}"
    echo -e "  Validate against a known-good baseline before returning the host"
    echo -e "  to service."
fi

echo
line
echo -e "${BOLD}${GREEN}Assessment complete.${NC}"
