#!/usr/bin/env bash

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
MAGENTA='\033[0;35m'
RED='\033[0;31m'
BRIGHT_BLACK='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m' # No Color (reset)

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (e.g. with sudo)" >&2
  exit 1
fi

get_mem_info() {
    if [[ ! -r "/proc/meminfo" ]]; then
        echo -e "${RED}could not retrieve memory info\n${NC}"
        return 1
    fi

    echo -e "${CYAN}${BOLD}💾 memory${NC}"

    local total_kb=$(grep 'MemTotal:' /proc/meminfo | awk '{print $2}')
    local avail_kb=$(grep 'MemAvailable:' /proc/meminfo | awk '{print $2}')

    local total_gb=$(echo "$total_kb" | awk '{printf "%.2f", $1/1024/1024}')
    local avail_gb=$(echo "$avail_kb" | awk '{printf "%.2f", $1/1024/1024}')

    echo -e "  ${YELLOW}total${NC}: ${total_gb} gb"
    echo -e "  ${YELLOW}available${NC}: ${avail_gb} gb\n"
}


parse_dmi_block() {
    local block="$1"
    
    if [[ ! "$block" == *"Size:"* || "$block" == *"Size: No Module Installed"* ]]; then
        return
    fi
    
    get_val() {
        local key="$1"
        local value=$(echo -e "$block" | sed -n "s/^[[:space:]]*${key}:[[:space:]]*//p")
        echo "${value:--}"
    }
    
    echo -e "  ${MAGENTA}🧠 slot${NC}: $(get_val "Locator")"
    echo -e "  ${MAGENTA}📦 size${NC}: $(get_val "Size")"
    echo -e "  ${MAGENTA}⚡ speed${NC}: $(get_val "Speed")"
    echo -e "  ${MAGENTA}🔠 type${NC}: $(get_val "Type")"
    echo -e "  ${MAGENTA}📍 bank${NC}: $(get_val "Bank Locator")"
    echo -e "  ${MAGENTA}✅ ecc${NC}: $(get_val "Error Correction Type")"
    echo -e "  ${MAGENTA}🔌 voltage${NC}: $(get_val "Configured Voltage")"
    echo
}


get_dmi_info() {
    if ! command -v dmidecode &> /dev/null; then
        echo -e "${RED}command 'dmidecode' not found. Please install it.${NC}"
        return 1
    fi
    
    echo -e "${CYAN}${BOLD}📗 modules${NC}"
    
    local dmi_output
    dmi_output=$(sudo dmidecode --type 17 2>/dev/null)
    local status=$?

    if [[ $status -ne 0 ]]; then
        echo -e "${RED}could not retrieve dmi memory module info (need sudo?)\n${NC}"
        return 1
    fi

    local current_block=""
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            if [[ -n "$current_block" ]]; then
                parse_dmi_block "$current_block"
                current_block=""
            fi
        else
            current_block+="$line\n"
        fi
    done <<< "$dmi_output"
    
    if [[ -n "$current_block" ]]; then
        parse_dmi_block "$current_block"
    fi
}


main() {
    echo -e "${GREEN}${BOLD}📦 mfetch${NC}"
    echo -e "${BRIGHT_BLACK}A Bash version of a memory-focused system info tool originally written in Rust by d3v.\n${NC}"

    get_mem_info
    get_dmi_info
}


main
