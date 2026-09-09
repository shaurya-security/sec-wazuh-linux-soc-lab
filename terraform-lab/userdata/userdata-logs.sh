#!/usr/bin/env bash
#
# search_wazuh_errors.sh
#
# Scans Wazuh installation log files for 🔴 error markers, ignoring the
# lines that merely *define* the trap which prints those markers, and
# prints surrounding context for every genuine error occurrence found.
#
# Exit codes:
#   0  -> no errors found in any log file
#   1  -> at least one error found
#   (individual missing files are reported but do not affect the exit code)

set -uo pipefail

# ----------------------------------------------------------------------------
# Colors (disabled automatically when stdout isn't a terminal)
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

readonly ERROR_MARKER='🔴🔴🔴🔴🔴🔴🔴🔴🔴🔴'
readonly DEFAULT_CONTEXT_LINES=10
readonly RULE_WIDTH=72
readonly NAME_COL_WIDTH=24   # width reserved for the log-file name column in the summary

# ----------------------------------------------------------------------------
# Small output helpers — these replace hand-drawn box art, which goes ragged
# whenever a line's emoji count changes its printed width. A plain full-width
# rule always lines up, on every terminal.
# ----------------------------------------------------------------------------
print_rule() {
    # Built by repeating the (possibly multi-byte) character via printf's
    # arg-recycling, not `tr`, since `tr` mangles multi-byte UTF-8 glyphs.
    local char="${1:-─}"
    local i line=""
    for (( i = 0; i < RULE_WIDTH; i++ )); do
        line+="$char"
    done
    printf '%s\n' "$line"
}

print_banner() {
    local title="$1"
    print_rule "═"
    printf '  %s\n' "$title"
    print_rule "═"
}

print_section() {
    local title="$1"
    local fill_len=$(( RULE_WIDTH - ${#title} - 4 ))
    (( fill_len < 0 )) && fill_len=0
    local i fill=""
    for (( i = 0; i < fill_len; i++ )); do
        fill+="─"
    done
    echo ""
    printf -- '── %s %s\n' "$title" "$fill"
}

# Log files to check, in the order they should be processed.
readonly LOG_NAMES=("linux_bootstrap.log" "wazuh_bootstrap.log" "wazuh-install.log")
declare -A LOG_PATHS=(
    ["linux_bootstrap.log"]="/var/log/linux_bootstrap.log"
    ["wazuh_bootstrap.log"]="/var/log/wazuh_bootstrap.log"
    ["wazuh-install.log"]="/var/log/wazuh-install.log"
)

# ----------------------------------------------------------------------------
# Return, via stdout, the line numbers in $1 that contain a genuine error
# marker (i.e. not part of a `trap ... echo ...` definition).
# ----------------------------------------------------------------------------
get_error_lines() {
    local log_file="$1"
    grep -n -- "$ERROR_MARKER" "$log_file" 2>/dev/null \
        | grep -v -e "trap.*echo.*${ERROR_MARKER}" -e "trap 'echo" \
        | cut -d: -f1
}

# ----------------------------------------------------------------------------
# Print a header/metadata block, then context around every real error found
# in a single log file. Returns 1 if errors were found, 0 otherwise, 2 if
# the file doesn't exist.
# ----------------------------------------------------------------------------
search_log_for_errors() {
    local log_file="$1"
    local log_name="$2"
    local context_lines="${3:-$DEFAULT_CONTEXT_LINES}"

    print_section "Analyzing ${log_name}"

    if [ ! -f "$log_file" ]; then
        echo -e "  ${YELLOW}⚠️  Not found:${NC} $log_file"
        return 2
    fi

    printf '  %-14s %s\n' "Path:" "$log_file"
    printf '  %-14s %s\n' "Size:" "$(du -h "$log_file" 2>/dev/null | cut -f1)"
    printf '  %-14s %s\n' "Modified:" "$(stat -c %y "$log_file" 2>/dev/null | cut -d. -f1)"
    echo ""

    local error_lines
    error_lines="$(get_error_lines "$log_file")"

    if [ -z "$error_lines" ]; then
        echo -e "  ${GREEN}✅ No error markers found${NC} (trap definitions ignored)"
        return 0
    fi

    local error_count
    error_count="$(wc -l <<< "$error_lines")"
    echo -e "  ${RED}🔴 ${error_count} error occurrence(s) found${NC}"

    local counter=1
    local line_num start_line end_line current_line content
    while IFS= read -r line_num; do
        echo ""
        echo -e "  ${YELLOW}▸ Error #${counter} — line ${line_num}${NC}"
        print_rule "·"

        start_line=$(( line_num - context_lines / 2 ))
        (( start_line < 1 )) && start_line=1
        end_line=$(( line_num + context_lines / 2 ))

        for (( current_line = start_line; current_line <= end_line; current_line++ )); do
            content="$(sed -n "${current_line}p" "$log_file" 2>/dev/null)"
            if [ "$current_line" -eq "$line_num" ]; then
                echo -e "  ${RED}▶ ${current_line}│${NC} ${content}"
            else
                printf '    %s│ %s\n' "$current_line" "$content"
            fi
        done
        print_rule "·"
        (( counter++ ))
    done <<< "$error_lines"

    return 1
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    print_banner "🛡  WAZUH INSTALLATION LOG SEARCH UTILITY"
    echo "  Searching for 🔴 error markers (trap definitions excluded)"
    echo -e "  ${BLUE}Started:${NC} $(date '+%Y-%m-%d %H:%M:%S')"

    declare -A results
    declare -A error_counts
    local total_error_occurrences=0
    local files_with_errors=0
    local errors_in_files=()

    local log_name log_file error_count

    for log_name in "${LOG_NAMES[@]}"; do
        log_file="${LOG_PATHS[$log_name]}"

        search_log_for_errors "$log_file" "$log_name" "$DEFAULT_CONTEXT_LINES"

        if [ -f "$log_file" ]; then
            error_count="$(get_error_lines "$log_file" | grep -c '' || true)"
            error_counts["$log_name"]=$error_count

            if [ "$error_count" -gt 0 ]; then
                results["$log_name"]="ERRORS FOUND"
                errors_in_files+=("$log_name")
                (( files_with_errors++ ))
                (( total_error_occurrences += error_count ))
            else
                results["$log_name"]="NO ERRORS"
            fi
        else
            results["$log_name"]="FILE NOT FOUND"
            error_counts["$log_name"]=0
        fi
    done

    # ---- Summary ----
    print_banner "📋 SEARCH SUMMARY"

    for log_name in "${LOG_NAMES[@]}"; do
        local status="${results[$log_name]}"
        error_count="${error_counts[$log_name]}"

        case "$status" in
            *"ERRORS FOUND"*)
                printf "  ${RED}🔴 %-${NAME_COL_WIDTH}s %s (%s)${NC}\n" \
                    "$log_name" "$status" "${error_count} error(s)"
                ;;
            *"NO ERRORS"*)
                printf "  ${GREEN}✅ %-${NAME_COL_WIDTH}s %s${NC}\n" "$log_name" "$status"
                ;;
            *)
                printf "  ${YELLOW}⚠️  %-${NAME_COL_WIDTH}s %s${NC}\n" "$log_name" "$status"
                ;;
        esac
    done

    print_rule "─"

    if [ "$files_with_errors" -gt 0 ]; then
        echo -e "  ${RED}❌ INSTALLATION ERRORS DETECTED${NC}"
        printf '  %-24s %s\n' "Files with errors:" "${errors_in_files[*]}"
        printf '  %-24s %s\n' "Total occurrences:" "$total_error_occurrences"
        echo "  ☝  Review the error context above for details"
    else
        echo -e "  ${GREEN}✅ NO ERRORS DETECTED IN ANY LOG FILE${NC}"
        echo "  🎉 Installation appears to have completed successfully"
    fi

    echo -e "  ${BLUE}Completed:${NC} $(date '+%Y-%m-%d %H:%M:%S')"
    print_rule "═"

    [ "$files_with_errors" -gt 0 ] && return 1 || return 0
}

main
exit $?
