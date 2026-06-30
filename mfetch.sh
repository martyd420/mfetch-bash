#!/usr/bin/env bash
# shellcheck disable=SC2059  # Color variables are constants defined below and
# are intentionally embedded in printf format strings for readability.

set -euo pipefail

# Force the C locale so awk always formats and parses numbers with a decimal
# point, regardless of the user's locale.
export LC_ALL=C

VERSION="1.0.0"

print_usage() {
    cat <<EOF
Usage: mfetch.sh [OPTIONS]

A memory-focused system info tool. Shows RAM and swap usage and, when run
with root privileges, details about the physical memory modules (DIMMs).

Options:
  -p, --processes N  List the top N memory-consuming process groups. Processes
                     are grouped by name (e.g. all "apache2" workers together)
                     and their memory is summed (PSS where available, else RSS)
  --no-color         Disable colored output (the NO_COLOR env var works too)
  -h, --help         Show this help and exit
  -V, --version      Show version and exit
EOF
}

# Colors are enabled only when stdout is a terminal, and can be disabled
# explicitly with the NO_COLOR environment variable (https://no-color.org)
# or the --no-color option.
use_color=0
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    use_color=1
fi

# Number of top process groups to list (0 = section disabled).
top_count=0

# Validates that the given value is a positive integer; exits otherwise.
require_positive_int() {
    local opt="$1"
    local value="$2"
    if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        printf 'ERROR: %s requires a positive integer argument\n\n' "$opt" >&2
        print_usage >&2
        exit 1
    fi
}

while (( $# )); do
    case "$1" in
        -p|--processes)
            require_positive_int "$1" "${2:-}"
            top_count="$2"
            shift
            ;;
        --processes=*)
            require_positive_int "--processes" "${1#*=}"
            top_count="${1#*=}"
            ;;
        --no-color)
            use_color=0
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        -V|--version)
            printf 'mfetch-bash %s\n' "$VERSION"
            exit 0
            ;;
        *)
            printf 'ERROR: Unknown option: %s\n\n' "$1" >&2
            print_usage >&2
            exit 1
            ;;
    esac
    shift
done

if (( use_color )); then
    GREEN='\033[0;32m'
    CYAN='\033[0;36m'
    YELLOW='\033[0;33m'
    MAGENTA='\033[0;35m'
    RED='\033[0;31m'
    BRIGHT_BLACK='\033[0;90m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    GREEN=''
    CYAN=''
    YELLOW=''
    MAGENTA=''
    RED=''
    BRIGHT_BLACK=''
    BOLD=''
    NC=''
fi

# Generic function to extract a value for a given key from a block of text.
# It's designed to be resilient, returning "-" if the key is not found.
get_val_from_block() {
    local block="$1"
    local key="$2"
    local value
    value=$(printf '%s\n' "$block" | sed -n "s/^[[:space:]]*${key}:[[:space:]]*//p" | head -n1)
    if [[ -n "$value" ]]; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "-"
    fi
}

# Checks if a command is available in the system's PATH.
# If not, it prints an error message and exits the script.
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        printf "${RED}ERROR: Command '%s' not found. Please install it.${NC}\n" "$cmd" >&2
        exit 1
    fi
}

# Prints a horizontal bar to visualize usage percentage.
# This function is used for both RAM and Swap usage.
print_bar() {
    local label="$1"
    local current="$2"
    local total="$3"
    local filled_color="$4"
    local empty_color="$5"
    local BAR_WIDTH=40
    local FILLED_CHAR="#"
    local EMPTY_CHAR="-"

    local stats
    if ! stats=$(awk -v current="$current" -v total="$total" -v width="$BAR_WIDTH" 'BEGIN {
            if (total <= 0) {
                exit 1
            }
            perc = (current / total) * 100
            if (perc < 0) {
                perc = 0
            }
            if (perc > 100) {
                perc = 100
            }
            filled = int((perc / 100) * width + 0.5)
            if (filled > width) {
                filled = width
            }
            printf "%.2f %.0f", perc, filled
        }'); then
        return
    fi

    local percentage filled_blocks
    read -r percentage filled_blocks <<< "$stats"
    local empty_blocks=$(( BAR_WIDTH - filled_blocks ))

    local filled_segment empty_segment
    filled_segment=$(printf "%${filled_blocks}s" | tr ' ' "$FILLED_CHAR")
    empty_segment=$(printf "%${empty_blocks}s" | tr ' ' "$EMPTY_CHAR")

    printf "  %s: [${filled_color}%s${empty_color}%s${NC}] %s%%\n" \
        "$label" "$filled_segment" "$empty_segment" "$percentage"
}

# Gathers and displays information about RAM usage from /proc/meminfo.
get_ram_info() {
    local meminfo="$1"

    # Extract memory values and convert from KB to GB. Kernels older than
    # 3.14 lack MemAvailable; approximate it with MemFree+Buffers+Cached.
    local mem_data
    mem_data=$(printf '%s\n' "$meminfo" | awk '
        /^MemTotal:/ {t=$2}
        /^MemAvailable:/ {a=$2; have_avail=1}
        /^MemFree:/ {f=$2}
        /^Buffers:/ {b=$2}
        /^Cached:/ {c=$2}
        END {
            if (!have_avail) a = f + b + c
            used = t - a
            printf "%.2f %.2f %.2f", t/1024/1024, used/1024/1024, a/1024/1024
        }
    ')
    local total_gb used_gb avail_gb
    read -r total_gb used_gb avail_gb <<< "$mem_data"

    printf "  ${YELLOW}%s${NC}: %-12s${YELLOW}%s${NC}: %-12s${YELLOW}%s${NC}: %s\n" \
        "Total RAM" "${total_gb} GB" "Used" "${used_gb} GB" "Available" "${avail_gb} GB"
    print_bar "Usage" "$used_gb" "$total_gb" "$MAGENTA" "$BRIGHT_BLACK"
}

# Gathers and displays information about Swap usage from /proc/meminfo.
get_swap_info() {
    local meminfo="$1"

    local swap_data
    swap_data=$(printf '%s\n' "$meminfo" | awk '
        /^SwapTotal:/ {st=$2}
        /^SwapFree:/ {sf=$2}
        END {
            used = st - sf
            printf "%.2f %.2f %.2f", st/1024/1024, used/1024/1024, sf/1024/1024
        }
    ')
    local total_gb used_gb free_gb
    read -r total_gb used_gb free_gb <<< "$swap_data"

    if awk -v total="$total_gb" 'BEGIN {exit !(total > 0)}'; then
        if awk -v used="$used_gb" 'BEGIN {exit !(used > 0.01)}'; then
            printf "\n"
            printf "  ${YELLOW}%s${NC}: %-12s${YELLOW}%s${NC}: %-12s${YELLOW}%s${NC}: %s\n" \
                "Total Swap" "${total_gb} GB" "Used" "${used_gb} GB" "Available" "${free_gb} GB"
            print_bar "Usage" "$used_gb" "$total_gb" "$CYAN" "$BRIGHT_BLACK"
        fi
    fi
}

# Emits the dmidecode blocks of installed memory modules, NUL-separated.
# Blocks are sets of lines separated by blank lines; slots without a module
# are skipped.
installed_module_blocks() {
    local dmi_output="$1"
    local block
    while IFS= read -r -d '' block; do
        if [[ "$block" == *"Size: No Module Installed"* ]]; then continue; fi
        if [[ "$block" == *"Size:"* ]]; then
            printf '%s\0' "$block"
        fi
    done < <(printf '%s\0' "$dmi_output" | awk -v RS= -v ORS='\0' '{print $0}')
}

# Determines the supported memory type by checking all installed memory modules.
# If all modules are of the same type, that type is returned.
# If types are mixed, it returns "Mixed". If no modules are found, it returns "-".
get_supported_mem_type() {
    local dmi_output="$1"
    if [[ -z "$dmi_output" ]]; then
        echo "-"
        return
    fi

    local types=()
    local block type
    while IFS= read -r -d '' block; do
        type=$(get_val_from_block "$block" "Type")
        if [[ "$type" != "-" ]]; then
            types+=("$type")
        fi
    done < <(installed_module_blocks "$dmi_output")

    if (( ${#types[@]} == 0 )); then
        echo "-"
        return
    fi

    local unique_types
    unique_types=$(printf "%s\n" "${types[@]}" | sort -u)

    if [[ $(wc -l <<< "$unique_types") -gt 1 ]]; then
        echo "Mixed"
        return
    fi

    echo "$unique_types"
}

# Displays general information about the physical memory array.
get_array_info() {
    printf "${CYAN}${BOLD}📖 Memory Array Info${NC}\n"

    local array_info="$1"
    local module_info="$2"
    local has_root="$3"

    if [[ -z "$array_info" ]]; then
        if (( has_root )); then
            printf "  ${YELLOW}Physical memory array information is not available.${NC}\n\n"
        else
            printf "  ${YELLOW}Requires root privileges. Run with sudo to see this section.${NC}\n\n"
        fi
        return
    fi

    local max_capacity; max_capacity=$(get_val_from_block "$array_info" "Maximum Capacity")
    local num_devices; num_devices=$(get_val_from_block "$array_info" "Number Of Devices")
    local ecc_type; ecc_type=$(get_val_from_block "$array_info" "Error Correction Type")
    local mem_type; mem_type=$(get_supported_mem_type "$module_info")


    printf "  ${YELLOW}Max. Capacity${NC}: %s (%s slots)\n" "$max_capacity" "$num_devices"
    printf "  ${YELLOW}Supported type${NC}: %s\n" "$mem_type"
    printf "  ${YELLOW}Error Correction (ECC)${NC}: %s\n" "$ecc_type"
    printf "\n"
}

# Parses a block of dmidecode output for a single memory module and prints its details.
parse_dmi_block() {
    local block="$1"

    printf "  ${MAGENTA}🧠 Slot${NC}: %-20s ${MAGENTA}📍 Bank${NC}: %s\n" \
        "$(get_val_from_block "$block" "Locator")" \
        "$(get_val_from_block "$block" "Bank Locator")"

    printf "  ${MAGENTA}📦 Size${NC}: %s\n" "$(get_val_from_block "$block" "Size")"
    printf "  ${MAGENTA}🏭 Manufacturer${NC}: %s\n" "$(get_val_from_block "$block" "Manufacturer")"
    printf "  ${MAGENTA}🏷️ Part Number${NC}: %s\n" "$(get_val_from_block "$block" "Part Number")"
    printf "  ${MAGENTA}🆔 Serial Number${NC}: %s\n" "$(get_val_from_block "$block" "Serial Number")"
    printf "  ${MAGENTA}📝 Form Factor${NC}: %s\n" "$(get_val_from_block "$block" "Form Factor")"
    printf "  ${MAGENTA}⚡ Type${NC}: %s\n" "$(get_val_from_block "$block" "Type")"
    # The actual running speed can differ from the rated one (XMP profiles,
    # downclocking with all slots populated). dmidecode older than 3.0 calls
    # the field "Configured Clock Speed" instead of "Configured Memory Speed".
    local configured_speed
    configured_speed=$(get_val_from_block "$block" "Configured Memory Speed")
    if [[ "$configured_speed" == "-" ]]; then
        configured_speed=$(get_val_from_block "$block" "Configured Clock Speed")
    fi

    printf "  ${MAGENTA}💨 Speed${NC}: %s\n" "$(get_val_from_block "$block" "Speed")"
    printf "  ${MAGENTA}🚀 Configured Speed${NC}: %s\n" "$configured_speed"
    printf "  ${MAGENTA}↔️ Data Width${NC}: %s\n" "$(get_val_from_block "$block" "Data Width")"
    printf "  ${MAGENTA}↕️ Total Width${NC}: %s\n" "$(get_val_from_block "$block" "Total Width")"
    printf "  ${MAGENTA}🔌 Voltage${NC}: %s\n" "$(get_val_from_block "$block" "Configured Voltage")"
    printf "\n"
}

# Collects and displays detailed information for each installed memory module.
print_dmi_details() {
    printf "${CYAN}${BOLD}📗 Memory Modules (DIMMs)${NC}\n"

    local dmi_output="$1"
    local has_root="$2"
    if [[ -z "$dmi_output" ]]; then
        if (( has_root )); then
            printf "  ${YELLOW}Could not retrieve DMI data. Skipping module details.${NC}\n\n"
        else
            printf "  ${YELLOW}Requires root privileges. Run with sudo to see this section.${NC}\n\n"
        fi
        return
    fi

    local blocks_found=0
    local block
    while IFS= read -r -d '' block; do
        parse_dmi_block "$block"
        blocks_found=1
    done < <(installed_module_blocks "$dmi_output")

    if (( blocks_found == 0 )); then
        printf "  ${YELLOW}No memory modules were identified.${NC}\n\n"
    fi
}

# Emits "<kb>\t<comm>" for every running process, where <kb> is the process's
# memory footprint. PSS (proportional set size, from smaps_rollup) is preferred
# because it counts shared pages only once, which matters when summing many
# workers that share libraries; it falls back to RSS (from statm) when
# smaps_rollup is missing (older kernels) or unreadable (other users' processes
# without root).
emit_process_mem() {
    local page_kb=$(( $(getconf PAGE_SIZE) / 1024 ))
    local d comm kb key val pages

    for d in /proc/[0-9]*; do
        [[ -d "$d" ]] || continue
        read -r comm < "$d/comm" 2>/dev/null || continue
        [[ -n "$comm" ]] || continue

        kb=""
        if [[ -r "$d/smaps_rollup" ]]; then
            while read -r key val _; do
                if [[ "$key" == "Pss:" ]]; then
                    kb="$val"
                    break
                fi
            done < "$d/smaps_rollup" 2>/dev/null || true
        fi

        # Fall back to RSS: field 2 of statm is the resident set in pages.
        if [[ -z "$kb" && -r "$d/statm" ]]; then
            if read -r _ pages _ < "$d/statm" 2>/dev/null; then
                kb=$(( pages * page_kb ))
            fi
        fi

        [[ -n "$kb" ]] || continue
        printf '%s\t%s\n' "$kb" "$comm"
    done
}

# Lists the top N process groups by summed memory usage, grouped by name.
get_top_processes() {
    printf "${CYAN}${BOLD}📊 Top Processes by Memory${NC}\n"

    local count="$1"
    local has_root="$2"

    local rows
    # head closing the pipe early makes upstream exit with SIGPIPE under
    # 'pipefail'; the captured output is still complete, so ignore that status.
    rows=$(emit_process_mem | awk -F'\t' '
        { sum[$2] += $1; cnt[$2]++ }
        END { for (k in sum) printf "%d\t%d\t%s\n", sum[k], cnt[k], k }
    ' | sort -rn -k1,1 | head -n "$count") || true

    if [[ -z "$rows" ]]; then
        printf "  ${YELLOW}No process information available.${NC}\n\n"
        return
    fi

    printf "  ${BRIGHT_BLACK}(grouped by name; PSS where available, otherwise RSS)${NC}\n"
    if (( ! has_root )); then
        printf "  ${BRIGHT_BLACK}Run with sudo for accurate accounting of other users' processes.${NC}\n"
    fi

    local kb cnt name human
    while IFS=$'\t' read -r kb cnt name; do
        human=$(awk -v kb="$kb" 'BEGIN {
            mb = kb / 1024
            if (mb >= 1024) {
                printf "%.2f GB", mb / 1024
            } else {
                printf "%.1f MB", mb
            }
        }')
        printf "  ${MAGENTA}%-18s${NC} %12s  ${BRIGHT_BLACK}(%s proc)${NC}\n" \
            "$name" "$human" "$cnt"
    done <<< "$rows"
    printf "\n"
}

# Main function to orchestrate the script's execution.
main() {
    local has_root=1
    if [[ "$EUID" -ne 0 ]]; then
      has_root=0
      printf "${YELLOW}Some information requires root privileges. Run with sudo for full output.${NC}\n\n" >&2
    fi

    printf "${GREEN}${BOLD}📦 mfetch-bash${NC} "
    printf "${BRIGHT_BLACK}[memory-focused system info tool]\n\n${NC}"

    # Read /proc/meminfo once; both the RAM and Swap sections parse it.
    local meminfo=""
    if [[ -r "/proc/meminfo" ]]; then
        meminfo=$(</proc/meminfo)
    else
        printf "${RED}ERROR: Cannot read /proc/meminfo.${NC}\n\n" >&2
    fi

    local dmi_array_output=""
    local dmi_module_output=""

    if (( has_root )); then
        # Ensure required commands are available before proceeding.
        check_command "dmidecode"

        if ! dmi_array_output=$(dmidecode -t 16 2>/dev/null); then
            dmi_array_output=""
        fi
        if ! dmi_module_output=$(dmidecode --type 17 2>/dev/null); then
            dmi_module_output=""
        fi
    fi

    # The order of execution for information gathering and display.
    get_array_info "$dmi_array_output" "$dmi_module_output" "$has_root"
    if [[ -n "$meminfo" ]]; then
        get_ram_info "$meminfo"
        get_swap_info "$meminfo"
    fi
    printf "\n"
    print_dmi_details "$dmi_module_output" "$has_root"

    if (( top_count > 0 )); then
        printf "\n"
        get_top_processes "$top_count" "$has_root"
    fi
}

# Entry point of the script.
main "$@"
