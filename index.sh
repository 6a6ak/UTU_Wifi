#!/usr/bin/env bash

as_root() {
    if (( EUID == 0 )); then "$@"; else sudo -- "$@"; fi
}

check_dependencies() {
    local tool missing=0
    for tool in iw iwlist ip lspci rfkill modprobe modinfo; do
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
modprobe kmod
modinfo kmod
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
    else
        echo 'No wireless interface exists. PCI detection does not mean the Wi-Fi driver initialized.' >&2
    fi
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
    if command -v modinfo >/dev/null 2>&1 && [[ ${pci,,} == *14e4:4331* ]]; then
        modinfo b43 2>&1 | head -n 12
        modprobe --showconfig 2>/dev/null | grep -E '^(blacklist|install)[[:space:]]+(b43|bcma|wl)([[:space:]]|$)' || true
        echo 'Interactive repair: bash index.sh --repair'
    fi
    echo 'Check firmware errors, driver probe failures, module blacklists and rfkill blocks. No reload, unblock, restart or reboot was attempted.'
    [[ -n $interfaces ]]
}

# Mutating operations are opt-in and never unload a module or restart a manager.
confirm_action() {
    local answer
    read -r -p "$1 Type YES to continue: " answer || return 1
    [[ $answer == YES ]]
}

install_packages() {
    as_root env NEEDRESTART_MODE=l apt-get update &&
        as_root env NEEDRESTART_MODE=l apt-get install -y --no-install-recommends "$@"
}

repair_wifi() {
    install_dependencies || return 1
    local pci logs interface module_config
    pci=$(lspci -nnk) || return 1
    # Obtain privileged logs only inside the explicitly selected repair workflow.
    logs=$(as_root journalctl -k -b --no-pager 2>&1) || true
    printf '%s\n' "$logs" | grep -Ei 'b43|bcma|brcm|firmware|80211|verification|key was rejected' | tail -n 80
    echo 'Radio state:'
    rfkill list
    echo 'Repair never removes drivers, edits blacklists, restarts managers or reboots.'
    if [[ -n $(find_interfaces) ]]; then
        interface=$(find_interface) || return 1
        if rfkill list wifi | grep -q 'Hard blocked: yes'; then
            echo 'Hardware radio block: enable the physical switch/BIOS radio first.'
            return 1
        fi
        if rfkill list wifi | grep -q 'Soft blocked: yes'; then
            confirm_action 'Unblock Wi-Fi radios?' || return 1
            as_root rfkill unblock wifi || return 1
        fi
        confirm_action "Bring wireless interface $interface up (no disconnect requested)?" || return 1
        as_root ip link set dev "$interface" up || return 1
        scan_wifi
        return $?
    fi
    if [[ ${pci,,} != *14e4:4331* ]]; then
        echo 'No supported automatic driver repair for this PCI ID. Inspect the kernel errors above.'
        echo 'For USB adapters also inspect lsusb. Missing hardware, unsupported kernels and hardware failures require device-specific repair.'
        return 1
    fi
    if module_loaded wl; then
        echo 'Conflicting wl module is loaded. Automatic driver replacement is refused to protect existing links.'
        return 1
    fi
    module_config=$(modprobe --showconfig) || return 1
    if printf '%s\n' "$module_config" | grep -Eq '^(blacklist[[:space:]]+(b43|bcma)([[:space:]]|$)|install[[:space:]]+(b43|bcma)[[:space:]])'; then
        echo 'b43/bcma is disabled or overridden in modprobe configuration:'
        printf '%s\n' "$module_config" | grep -E '^(blacklist|install)[[:space:]]+(b43|bcma)([[:space:]]|$)'
        echo 'Review /etc/modprobe.d and /lib/modprobe.d. No blacklist was edited.'
        return 1
    fi
    if grep -Eq '(modprobe.blacklist|module_blacklist)=[^ ]*(b43|bcma)' /proc/cmdline; then
        echo 'Kernel command line blocks b43/bcma. Review boot configuration from a recovery console.'
        return 1
    fi
    if ! modinfo b43 >/dev/null 2>&1; then
        echo "b43 is absent for kernel $(uname -r). Checking the matching Ubuntu extra-modules package."
        confirm_action "Install linux-modules-extra-$(uname -r)?" || return 1
        install_packages "linux-modules-extra-$(uname -r)" || return 1
        modinfo b43 >/dev/null 2>&1 || { echo 'This kernel still has no b43 module; use a supported Ubuntu kernel.'; return 1; }
    fi
    echo 'BCM4331 repair: install/reconfigure b43 firmware, then load b43 without unloading any driver.'
    confirm_action 'Install firmware-b43-installer and load b43?' || return 1
    if ! apt-cache show firmware-b43-installer >/dev/null 2>&1; then
        echo 'firmware-b43-installer is not in the local apt index. Refresh it first.'
        as_root env NEEDRESTART_MODE=l apt-get update || return 1
        if ! apt-cache show firmware-b43-installer >/dev/null 2>&1; then
            confirm_action 'Enable Ubuntu multiverse to obtain b43 firmware?' || return 1
            if ! grep -q '^ID=ubuntu$' /etc/os-release; then
                echo 'Automatic multiverse enablement is supported only on Ubuntu.'; return 1
            fi
            install_packages software-properties-common || return 1
            as_root add-apt-repository -y multiverse || return 1
        fi
    fi
    install_packages firmware-b43-installer || {
        echo 'Firmware installation failed. Check apt/download errors and whether multiverse is enabled in your Ubuntu sources.'
        return 1
    }
    # Re-run the downloader even when dpkg considers the installer already installed.
    as_root env NEEDRESTART_MODE=l dpkg-reconfigure -f noninteractive firmware-b43-installer || return 1
    as_root modprobe b43 || {
        echo 'Loading b43 failed. Check module availability, signature/Secure Boot errors and kernel logs.'
        return 1
    }
    command -v udevadm >/dev/null 2>&1 && as_root udevadm settle --timeout=10
    if [[ -z $(find_interfaces) ]]; then
        echo 'No interface appeared. A previously failed probe may need a controlled reboot or driver reload; neither is automatic.'
        as_root journalctl -k -b --no-pager | grep -Ei 'b43|bcma|firmware|verification' | tail -n 60
        return 1
    fi
    echo 'Wireless interface created. Select repair again to enable/scan it, then connect.'
    diagnose
}

module_loaded() { [[ -d /sys/module/$1 ]]; }

connect_wifi() (
    local interface ssid config existing profile security
    install_dependencies || return 1
    interface=$(find_interface) || { echo 'Repair the missing/ambiguous wireless interface first.'; return 1; }
    if systemctl is-active --quiet NetworkManager && systemctl is-active --quiet systemd-networkd; then
        echo 'Both managers are active. Refusing to guess which owns this interface.'
        return 1
    fi
    if systemctl is-active --quiet NetworkManager; then
        command -v nmcli >/dev/null 2>&1 || { echo 'Active NetworkManager has no nmcli; repair its package installation.'; return 1; }
        if iw dev "$interface" link | grep -q '^Connected to'; then
            echo 'This wireless interface is already connected. Refusing to replace an existing connection.'
            return 1
        fi
        read -r -p 'Wi-Fi SSID: ' ssid || return 1
        [[ -n $ssid ]] || return 1
        read -r -p 'Security (wpa/open): ' security || return 1
        [[ $security == wpa || $security == open ]] || { echo 'Only open/WPA personal networks are supported by this wizard.'; return 1; }
        confirm_action "Connect $interface using active NetworkManager?" || return 1
        profile="utu-wifi-$(cat /proc/sys/kernel/random/uuid)"
        local -a properties=()
        [[ $security == wpa ]] && properties+=(wifi-sec.key-mgmt wpa-psk)
        as_root nmcli connection add type wifi ifname "$interface" con-name "$profile" ssid "$ssid" \
            connection.autoconnect no ipv4.method auto ipv4.never-default yes \
            ipv4.ignore-auto-dns yes ipv6.method disabled "${properties[@]}" || return 1
        if ! as_root nmcli --ask connection up id "$profile"; then
            echo "Connection failed. Inactive profile retained for review: $profile"
            return 1
        fi
        as_root nmcli connection modify id "$profile" connection.autoconnect yes
        return $?
    fi
    if ! systemctl is-active --quiet systemd-networkd; then
        echo 'No supported active manager. No manager will be enabled automatically.'
        return 1
    fi
    echo 'networkd connection uses a new Netplan Wi-Fi profile and netplan try.'
    echo 'Netplan try can reconfigure other links. Use a local/out-of-band console; rollback is not guaranteed.'
    if [[ -n ${SSH_CONNECTION:-}${SSH_CLIENT:-} ]]; then
        echo 'Refusing global Netplan changes from an SSH session. Run this step from the server console.'
        return 1
    fi
    echo 'The Wi-Fi profile does not accept DHCP routes or DNS, preserving the current default path.'
    confirm_action 'Install Netplan/WPA tools and prepare an interactive connection?' || return 1
    install_packages netplan.io wpasupplicant python3 python3-yaml || return 1
    # Refuse merges into pre-existing Wi-Fi definitions (including match-based IDs).
    existing=$(as_root netplan get network.wifis) || return 1
    if [[ $existing != null && $existing != '{}' && -n $existing ]]; then
        echo 'Existing Netplan Wi-Fi definitions found. Refusing to merge/overwrite credentials. Review with sudo netplan get network.wifis (contains secrets).'
        return 1
    fi
    config=$(mktemp /tmp/utu-wifi-XXXXXXXX.yaml) || return 1
    trap 'rm -f -- "$config"' EXIT
    chmod 600 "$config"
    if ! python3 "$(dirname -- "${BASH_SOURCE[0]}")/wifi_profile.py" "$interface" "$config"; then
        rm -f -- "$config"; return 1
    fi
    echo 'A new Wi-Fi-only profile is ready. Existing configuration files will be backed up by Netplan.'
    if ! confirm_action 'Try this configuration for 120 seconds? Confirm inside Netplan only after checking connectivity.'; then
        rm -f -- "$config"; return 1
    fi
    as_root netplan try --config-file "$config" --timeout 120
    local result=$?
    rm -f -- "$config"
    echo 'Check the Netplan accept/revert message and actual connectivity; exit status alone does not establish success.'
    echo 'On timeout/cancellation verify both runtime state and /etc/netplan before rebooting.'
    ip -brief address show dev "$interface"
    return "$result"
)

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
        --repair) repair_wifi; return $? ;;
        --connect) connect_wifi; return $? ;;
        --help) echo 'Usage: bash index.sh [--install|--diagnose|--repair|--connect|--help]'; return 0 ;;
        '') ;;
        *) echo "Unknown option: $1" >&2; return 2 ;;
    esac
    check_dependencies || { install_dependencies || return 1; }
    local choice
    while true; do
        printf '\n1) List Wi-Fi networks\n2) Show saved Wi-Fi passwords\n3) Show frequencies and signals\n4) Diagnose Wi-Fi\n5) Repair Wi-Fi (interactive)\n6) Connect to Wi-Fi (interactive)\n0) Exit\n'
        read -r -p 'Choice: ' choice || break
        case "$choice" in
            1|3) scan_wifi ;;
            2) show_passwords ;;
            4) diagnose ;;
            5) repair_wifi ;;
            6) connect_wifi ;;
            0) break ;;
            *) echo 'Invalid choice.' ;;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
