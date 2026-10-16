#!/usr/bin/env bash

as_root() {
    if (( EUID == 0 )); then "$@"; else sudo -- "$@"; fi
}

check_dependencies() {
    local tool missing=0
    for tool in iw iwlist ip lspci rfkill; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Missing tool: $tool" >&2
            missing=1
        fi
    done
    return "$missing"
}

install_dependencies() {
    local tool package
    local -a packages=()
    while read -r tool package; do
        command -v "$tool" >/dev/null 2>&1 || packages+=("$package")
    done <<'PACKAGES'
iw iw
iwlist wireless-tools
ip iproute2
lspci pciutils
rfkill rfkill
PACKAGES
    ((${#packages[@]})) || return 0
    command -v apt-get >/dev/null 2>&1 || {
        echo 'Automatic installation requires Ubuntu/Debian apt-get.' >&2
        return 1
    }
    echo "Installing missing packages: ${packages[*]}"
    # Prevent needrestart from restarting services during tool installation.
    as_root env NEEDRESTART_MODE=l apt-get update || {
        echo 'Package index update failed. Check connectivity and repositories.' >&2
        return 1
    }
    as_root env NEEDRESTART_MODE=l apt-get install -y --no-install-recommends "${packages[@]}" || {
        echo 'Installation failed; inspect apt errors above.' >&2
        return 1
    }
    check_dependencies
}

find_interfaces() {
    local path
    for path in /sys/class/net/*; do
        [[ -d "$path/wireless" || -e "$path/phy80211" ]] && basename "$path"
    done
    return 0
}

find_interface() {
    local item
    local -a interfaces=()
    mapfile -t interfaces < <(find_interfaces)
    if [[ -n ${WIFI_INTERFACE:-} ]]; then
        for item in "${interfaces[@]}"; do
            if [[ $item == "$WIFI_INTERFACE" ]]; then echo "$item"; return 0; fi
        done
        echo "Requested wireless interface does not exist: $WIFI_INTERFACE" >&2
        return 1
    fi
    ((${#interfaces[@]})) || return 1
    if ((${#interfaces[@]} > 1)); then
        echo "Multiple wireless interfaces: ${interfaces[*]}. Select with WIFI_INTERFACE." >&2
        return 1
    fi
    echo "${interfaces[0]}"
}

diagnose() {
    local service pci='' logs interfaces
    echo 'Network service status (read-only):'
    for service in NetworkManager systemd-networkd; do
        printf '%s: ' "$service"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl is-active "$service" 2>/dev/null || true
        else echo 'unavailable'; fi
    done
    check_dependencies || true
    if command -v lspci >/dev/null 2>&1; then
        pci=$(lspci -nnk)
        printf '%s\n' "$pci" | grep -A3 -Ei 'network controller|wireless' || true
    fi
    command -v ip >/dev/null 2>&1 && ip -brief link
    command -v rfkill >/dev/null 2>&1 && rfkill list
    interfaces=$(find_interfaces)
    if [[ -n $interfaces ]]; then
        printf 'Wireless interfaces:\n%s\n' "$interfaces"
        return 0
    fi
    echo 'No wireless interface exists. PCI detection does not mean the Wi-Fi driver initialized.' >&2
    if [[ ${pci,,} == *14e4:4331* ]]; then
        echo 'BCM4331 supports b43. bcma-pci-bridge is the bus bridge, not evidence that b43 and firmware initialized.'
        echo 'If kernel logs report missing b43 firmware, Ubuntu provides firmware-b43-installer (multiverse).'
        echo 'Manual repair after reviewing logs: sudo apt-get install firmware-b43-installer'
        echo 'Firmware installation requires downloads. No driver, firmware or module changes are made automatically.'
    fi
    if logs=$(dmesg 2>/dev/null); then
        echo 'Relevant kernel messages:'
        printf '%s\n' "$logs" | grep -Ei 'b43|bcma|brcm|firmware|wlan|80211' | tail -n 60
    else
        echo 'Kernel log access denied. Run: sudo journalctl -k -b --no-pager'
    fi
    echo 'Check firmware errors, driver probe failures, module blacklists and rfkill blocks. No reload, unblock, restart or reboot was attempted.'
    return 1
}

scan_wifi() {
    local interface output
    interface=$(find_interface) || { diagnose; return 1; }
    command -v iw >/dev/null 2>&1 || {
        echo 'Missing iw. Run: bash index.sh --install' >&2
        return 1
    }
    echo "Scanning on $interface..."
    if output=$(as_root iw dev "$interface" scan 2>&1); then
        printf '%s\n' "$output" | grep -E 'BSS |SSID:|freq:|signal:'
    else
        printf '%s\n' "$output" >&2
        echo 'Scan failed. Check --diagnose for rfkill and link state. An administrator must explicitly bring up a down interface.' >&2
        return 1
    fi
}

show_passwords() {
    local directory=/etc/NetworkManager/system-connections profile
    if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-active --quiet NetworkManager; then
        echo 'Saved-password viewing requires active NetworkManager; the current manager will not be changed.'
        return 1
    fi
    if [[ ! -r $directory || ! -x $directory ]]; then
        echo 'Cannot read saved profiles. Run with appropriate permissions to view saved secrets.' >&2
        return 1
    fi
    local -a profiles=()
    while IFS= read -r -d '' profile; do profiles+=("$profile"); done < <(find "$directory" -maxdepth 1 -type f -print0)
    if ((${#profiles[@]} == 0)); then echo 'No saved profiles found.'; return 0; fi
    for profile in "${profiles[@]}"; do
        printf 'Network: %s\n' "$(basename "$profile")"
        if [[ -r $profile ]]; then sed -n 's/^psk=/Password: /p' "$profile"
        else echo 'Profile is not readable.'; fi
    done
}

main() {
    case "${1:-}" in
        --install) install_dependencies && diagnose; return $? ;;
        --diagnose) diagnose; return $? ;;
        --help) echo 'Usage: bash index.sh [--install|--diagnose|--help]'; return 0 ;;
        '') ;;
        *) echo "Unknown option: $1" >&2; return 2 ;;
    esac
    check_dependencies || { install_dependencies || return 1; }
    local choice
    while true; do
        printf '\n1) List Wi-Fi networks\n2) Show saved Wi-Fi passwords\n3) Show frequencies and signals\n4) Diagnose Wi-Fi\n0) Exit\n'
        read -r -p 'Choice: ' choice || break
        case "$choice" in
            1|3) scan_wifi ;;
            2) show_passwords ;;
            4) diagnose ;;
            0) break ;;
            *) echo 'Invalid choice.' ;;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
