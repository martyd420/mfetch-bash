#!/usr/bin/env bash

set -euo pipefail

LC_NUMERIC="C"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
MAGENTA='\033[0;35m'
RED='\033[0;31m'
BRIGHT_BLACK='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

declare -A BANK_OCCURRENCES=()

# Normalizes the "Bank Locator" value into a more descriptive label.
# Many vendors report values such as "P0 CHANNEL A" where the "P" prefix
# references the physical CPU socket.  Converting them to a readable form
# makes it obvious which channel the DIMM belongs to.
format_bank_locator() {
    local raw="$1"
    if [[ -z "$raw" || "$raw" == "-" ]]; then
        printf '-\n'
        return
    fi

    local trimmed
    trimmed=$(printf '%s\n' "$raw" | awk '{$1=$1; print}')

    if [[ "$trimmed" =~ ^P([0-9]+)[[:space:]]+CHANNEL[[:space:]]+(.+)$ ]]; then
        local cpu="${BASH_REMATCH[1]}"
        local channel="${BASH_REMATCH[2]}"
        printf 'CPU %s / Channel %s\n' "$cpu" "$channel"
        return
    fi

    if [[ "$trimmed" =~ ^P([0-9]+)[[:space:]]+BANK[[:space:]]+([0-9]+)$ ]]; then
        local cpu="${BASH_REMATCH[1]}"
        local bank="${BASH_REMATCH[2]}"
        printf 'CPU %s / Bank %s\n' "$cpu" "$bank"
        return
    fi

    printf '%s\n' "$trimmed"
}

# Adds a stable suffix when multiple DIMMs report the same bank label so the
# output stays unique even on platforms that duplicate the vendor string.
decorate_bank_label() {
    local label="$1"

    if [[ -z "$label" || "$label" == "-" ]]; then
        printf '-\n'
        return
    fi

    local count=1
    if [[ -v BANK_OCCURRENCES[$label] ]]; then
        count=$(( BANK_OCCURRENCES[$label] + 1 ))
    fi
    BANK_OCCURRENCES[$label]=$count

    if (( count > 1 )); then
        printf '%s (module #%d)\n' "$label" "$count"
    else
        printf '%s\n' "$label"
    fi
}

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
        printf '-\n'
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

    printf "  ${label}: [${filled_color}%s${empty_color}%s${NC}] ${percentage}%%\n" "$filled_segment" "$empty_segment"
}

# Gathers and displays information about RAM usage from /proc/meminfo.
get_ram_info() {
    if [[ ! -r "/proc/meminfo" ]]; then
        printf "${RED}ERROR: Cannot read /proc/meminfo.${NC}\n\n" >&2
        return 1
    fi

    # Extract memory values and convert from KB to GB.
    local mem_data
    mem_data=$(awk '
        /^MemTotal:/ {t=$2}
        /^MemAvailable:/ {a=$2}
        END {
            used = t - a
            printf "%.2f %.2f %.2f", t/1024/1024, used/1024/1024, a/1024/1024
        }
    ' /proc/meminfo)
    read -r total_gb used_gb avail_gb <<< "$mem_data"

    printf "  ${YELLOW}Total RAM${NC}: ${total_gb} GB\t${YELLOW}Used${NC}: ${used_gb} GB\t${YELLOW}Available${NC}: ${avail_gb} GB\n"
    print_bar "Usage" "$used_gb" "$total_gb" "$MAGENTA" "$BRIGHT_BLACK"
}

# Gathers and displays information about Swap usage from /proc/meminfo.
get_swap_info() {
    if [[ ! -r "/proc/meminfo" ]]; then return 1; fi

    local swap_data
    swap_data=$(awk '
        /^SwapTotal:/ {st=$2}
        /^SwapFree:/ {sf=$2}
        END {
            used = st - sf
            printf "%.2f %.2f %.2f", st/1024/1024, used/1024/1024, sf/1024/1024
        }
    ' /proc/meminfo)
    read -r total_gb used_gb free_gb <<< "$swap_data"

    if awk -v total="$total_gb" 'BEGIN {exit !(total > 0)}'; then
        if awk -v used="$used_gb" 'BEGIN {exit !(used > 0.01)}'; then
            printf "\n"
            printf "  ${YELLOW}Total Swap${NC}: ${total_gb} GB\t${YELLOW}Used${NC}: ${used_gb} GB\t${YELLOW}Available${NC}: ${free_gb} GB\n"
            print_bar "Usage" "$used_gb" "$total_gb" "$CYAN" "$BRIGHT_BLACK"
        fi
    fi
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
    while IFS= read -r -d '' block; do
        if [[ "$block" == *"Size: No Module Installed"* ]]; then continue; fi
        if [[ "$block" == *"Size:"* ]]; then
            local type
            type=$(get_val_from_block "$block" "Type")
            if [[ "$type" != "-" ]]; then
                types+=("$type")
            fi
        fi
    done < <(printf '%s\0' "$dmi_output" | awk -v RS='\n\n' -v ORS='\0' '{print $0}')

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

    if [[ -z "$array_info" ]]; then
        printf "  ${YELLOW}Physical memory array information is not available.${NC}\n\n"
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

    local slot locator
    slot=$(get_val_from_block "$block" "Locator")
    locator=$(get_val_from_block "$block" "Bank Locator")
    locator=$(format_bank_locator "$locator")
    locator=$(decorate_bank_label "$locator")

    printf "  ${MAGENTA}🧠 Slot${NC}: %-20s ${MAGENTA}📍 Bank${NC}: %s\n" \
        "$slot" \
        "$locator"

    printf "  ${MAGENTA}📦 Size${NC}: %s\n" "$(get_val_from_block "$block" "Size")"
    printf "  ${MAGENTA}🏭 Manufacturer${NC}: %s\n" "$(get_val_from_block "$block" "Manufacturer")"
    printf "  ${MAGENTA}🏷️ Part Number${NC}: %s\n" "$(get_val_from_block "$block" "Part Number")"
    printf "  ${MAGENTA}🆔 Serial Number${NC}: %s\n" "$(get_val_from_block "$block" "Serial Number")"
    printf "  ${MAGENTA}📝 Form Factor${NC}: %s\n" "$(get_val_from_block "$block" "Form Factor")"
    printf "  ${MAGENTA}⚡ Type${NC}: %s\n" "$(get_val_from_block "$block" "Type")"
    printf "  ${MAGENTA}💨 Speed${NC}: %s\n" "$(get_val_from_block "$block" "Speed")"
    printf "  ${MAGENTA}↔️ Data Width${NC}: %s\n" "$(get_val_from_block "$block" "Data Width")"
    printf "  ${MAGENTA}↕️ Total Width${NC}: %s\n" "$(get_val_from_block "$block" "Total Width")"
    printf "  ${MAGENTA}🔌 Voltage${NC}: %s\n" "$(get_val_from_block "$block" "Configured Voltage")"
    printf "\n"
}

# Collects and displays detailed information for each installed memory module.
print_dmi_details() {
    printf "${CYAN}${BOLD}📗 Memory Modules (DIMMs)${NC}\n"

    local dmi_output="$1"
    if [[ -z "$dmi_output" ]]; then
        printf "  ${YELLOW}Could not retrieve DMI data. Skipping module details.${NC}\n\n"
        return
    fi

    # Process each memory module block from dmidecode output.
    # A block is defined as a set of lines separated by double newlines.
    local blocks_found=0
    while IFS= read -r -d '' block; do
        if [[ "$block" == *"Size: No Module Installed"* ]]; then continue; fi
        if [[ "$block" == *"Size:"* ]]; then
            parse_dmi_block "$block"
            blocks_found=1
        fi
    done < <(printf '%s\0' "$dmi_output" | awk -v RS='\n\n' -v ORS='\0' '{print $0}')

    if (( blocks_found == 0 )); then
        printf "  ${YELLOW}No memory modules were identified.${NC}\n\n"
    fi
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
    get_array_info "$dmi_array_output" "$dmi_module_output"
    get_ram_info
    get_swap_info
    printf "\n"
    print_dmi_details "$dmi_module_output"
}

# Entry point of the script.
main "$@"
