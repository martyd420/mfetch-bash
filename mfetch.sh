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

ram_type="-"
ram_speed="-"

declare -a module_blocks

if [[ "$EUID" -ne 0 ]]; then
  printf "${RED}This script requires root privileges.${NC}\n" >&2
  exit 1
fi


print_bar() {
    local label="$1"
    local current="$2"
    local total="$3"
    local filled_color="$4"
    local empty_color="$5"
    local BAR_WIDTH=40

    local FILLED_CHAR="#"
    local EMPTY_CHAR="-"

    if (( $(echo "$total <= 0" | bc -l) )); then return; fi

    local percentage;
    percentage=$(printf "%.2f" "$(echo "scale=4; ($current / $total) * 100" | bc -l)")

    local filled_blocks;
    filled_blocks=$(printf "%.0f" "$(echo "scale=4; ($percentage / 100) * $BAR_WIDTH" | bc -l)")

    local empty_blocks;
    empty_blocks=$(( BAR_WIDTH - filled_blocks ))

    local filled_segment;
    filled_segment=$(printf '%*s' "$filled_blocks" | tr ' ' "$FILLED_CHAR")

    local empty_segment;
    empty_segment=$(printf '%*s' "$empty_blocks" | tr ' ' "$EMPTY_CHAR")

    printf "  ${label}: [${filled_color}%s${empty_color}%s${NC}] ${percentage}%%\n" "$filled_segment" "$empty_segment"
}


get_mem_info() {
    if [[ ! -r "/proc/meminfo" ]]; then
        printf "${RED}ERROR: Cant read /proc/meminfo.${NC}\n\n" >&2; return 1;
    fi


    local mem_data; mem_data=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} /^SwapTotal:/ {st=$2} /^SwapFree:/ {sf=$2} END {printf "%.2f %.2f %.2f %.2f", t/1024/1024, a/1024/1024, st/1024/1024, sf/1024/1024}' /proc/meminfo)
    read -r total_gb avail_gb swap_total_gb swap_free_gb <<< "$mem_data"
    local used_gb; used_gb=$(echo "$total_gb - $avail_gb" | bc -l)

    printf "  ${YELLOW}Total RAM${NC}: ${total_gb} GB\t${YELLOW}Used${NC}: ${used_gb} GB\t${YELLOW}Available${NC}: ${avail_gb} GB\n"
    print_bar "Usage" "$used_gb" "$total_gb" "$MAGENTA" "$BRIGHT_BLACK"

    if (( $(echo "$swap_total_gb > 0" | bc -l) )); then
      printf "\n"
      local swap_used_gb; swap_used_gb=$(echo "$swap_total_gb - $swap_free_gb" | bc -l)
      if (( $(echo "$swap_used_gb > 0" | bc -l) )); then
        printf "  ${YELLOW}Total swap${NC}: ${swap_total_gb} GB\t${YELLOW}Used${NC}: ${swap_used_gb} GB\t${YELLOW}Available${NC}: ${swap_free_gb} GB\n"
        print_bar "Usage" "$swap_used_gb" "$swap_total_gb" "$CYAN" "$BRIGHT_BLACK"
        printf "\n"
      fi
    fi
}


get_array_info() {
    printf "${CYAN}${BOLD}📖 Memory info${NC}\n"

    local array_info;
    if ! array_info=$(dmidecode -t 16 2>/dev/null); then
        printf "  ${YELLOW}The physical memory information is not available.${NC}\n\n"; return;
    fi

    get_val() { grep -oP "^\s*${1}:\s*\K.*" <<< "$array_info" || echo "-"; }

    local max_capacity; max_capacity=$(get_val "Maximum Capacity")
    local num_devices; num_devices=$(get_val "Number Of Devices")

    printf "  ${YELLOW}Max. RAM size${NC}: %s (%s slots)\n" "$max_capacity" "$num_devices"
    printf "  ${YELLOW}Memory type${NC}: %s\n" "$ram_type"
    printf "  ${YELLOW}Speed${NC}: %s\n" "$ram_speed"
    printf "  ${YELLOW}Error correction (ECC)${NC}: $(get_val "Error Correction Type")\n"
    printf "\n"
}


collect_dmi_data() {
    if ! command -v dmidecode &> /dev/null; then
        return 1
    fi

    local dmi_output;
    if ! dmi_output=$(dmidecode --type 17 2>/dev/null); then
        return 1
    fi

    while IFS= read -r -d '' block; do
        if [[ "$block" == *"Size: No Module Installed"* ]]; then continue; fi
        if [[ "$block" == *"Size:"* ]]; then
            module_blocks+=("$block")
            if [[ "$ram_type" == "-" ]]; then
               ram_type=$(grep -oP '^\s*Type:\s*\K.*' <<< "$block" || echo "N/A")
               ram_speed=$(grep -oP '^\s*Speed:\s*\K.*' <<< "$block" || echo "N/A")
            fi
        fi
    done < <(printf '%s\0' "$dmi_output" | awk -v RS='\n\n' -v ORS='\0' '{print $0}')
    return 0
}


parse_dmi_block() {
    local block="$1"

    get_val() {
        local key="$1"
        grep -oP "^\s*${key}:\s*\K.*" <<< "$block" || echo "-"
    }

    local size; size=$(get_val "Size")

    printf "  ${MAGENTA}🧠 Slot${NC}: %-20s ${MAGENTA}📍 Bank${NC}: %s\n" "$(get_val "Locator")" "$(get_val "Bank Locator")"
    printf "  ${MAGENTA}📦 Size${NC}: %s\n" "$size"
    printf "  ${MAGENTA}🏭 Manufacturer${NC}: %s\n" "$(get_val "Manufacturer")"
    printf "  ${MAGENTA}🏷️ Part Number${NC}: %s\n" "$(get_val "Part Number")"
    printf "  ${MAGENTA}✅ ECC${NC}: $(get_val "Error Correction Type")\n"
    printf "  ${MAGENTA}🔌 Voltage${NC}: $(get_val "Configured Voltage")\n"
    printf "\n"
}


print_dmi_details() {
    printf "${CYAN}${BOLD}📗 Memory modules (DIMM)${NC}\n"

    if ! command -v dmidecode &> /dev/null; then
        printf "  ${YELLOW}The command 'dmidecode' is not available. Skipping module details.${NC}\n\n"
        return
    fi

    if (( ${#module_blocks[@]} == 0 )); then
        printf "  ${YELLOW}No memory modules were identified.${NC}\n\n"
        return
    fi

    for block in "${module_blocks[@]}"; do
        parse_dmi_block "$block"
    done
}


main() {
    printf "${GREEN}${BOLD}📦 mfetch-bash${NC} "
    printf "${BRIGHT_BLACK}[memory-focused system info tool]\n\n${NC}"


    collect_dmi_data
    get_array_info
    get_mem_info
    print_dmi_details
}


main
