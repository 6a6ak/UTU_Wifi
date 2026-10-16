#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./index.sh
fail() { echo "FAIL: $*" >&2; exit 1; }

# Mock all privileged operations: these tests never change the host.
(
    command() {
        if [[ $1 == -v ]]; then
            case $2 in iw|iwlist|rfkill) return 1 ;; *) return 0 ;; esac
        fi
        builtin command "$@"
    }
    as_root() { printf '%s\n' "$*"; }
    check_dependencies() { return 0; }
    output=$(install_dependencies)
    [[ $output == *'apt-get install -y --no-install-recommends iw wireless-tools rfkill'* ]] || fail 'package mapping'
    [[ $output != *network-manager* ]] || fail 'unexpected manager installation'
)
(
    command() { return 1; }
    as_root() { fail 'apt invoked despite unavailable apt'; }
    if install_dependencies >/dev/null 2>&1; then fail 'unsupported platform accepted'; fi
)
(
    command() { [[ $2 == apt-get ]]; }
    as_root() { return 1; }
    check_dependencies() { fail 'continued after apt failure'; }
    if install_dependencies >/dev/null 2>&1; then fail 'apt failure ignored'; fi
)
(
    find_interfaces() { printf '%s\n' wlx00112233; }
    [[ $(find_interface) == wlx00112233 ]] || fail 'dynamic interface detection'
    WIFI_INTERFACE=missing
    if find_interface >/dev/null 2>&1; then fail 'invalid override accepted'; fi
)
(
    unset WIFI_INTERFACE
    find_interfaces() { printf '%s\n' wlan0 wlan1; }
    if find_interface >/dev/null 2>&1; then fail 'ambiguous interface accepted'; fi
    WIFI_INTERFACE=wlan1
    [[ $(find_interface) == wlan1 ]] || fail 'explicit selection'
)
(
    find_interfaces() { :; }
    check_dependencies() { return 1; }
    systemctl() { echo inactive; return 3; }
    lspci() { echo 'Network controller: Broadcom BCM4331 [14e4:4331]'; echo 'Kernel driver in use: bcma-pci-bridge'; }
    ip() { echo 'enp2s0f0 lo tailscale0'; }
    rfkill() { :; }
    dmesg() { echo 'b43: firmware file missing'; }
    output=$(diagnose 2>&1) && fail 'missing interface reported success'
    [[ $output == *'bus bridge'* && $output == *'b43: firmware file missing'* ]] || fail 'missing driver evidence'
)
(
    find_interface() { echo wlan0; }
    prepare_wifi() { :; }
    command() { return 0; }
    as_root() { echo 'RF-kill blocked' >&2; return 1; }
    output=$(scan_wifi 2>&1) && fail 'scan failure reported success'
    [[ $output == *'RF-kill blocked'* ]] || fail 'scan error hidden'
)
echo 'All mocked regression checks passed.'

# Repair must not proceed when the user declines, or on unknown hardware.
(
    install_dependencies() { :; }
    lspci() { echo 'Network controller [14e4:4331]'; }
    as_root() { [[ $1 == journalctl ]] || fail "Unexpected privileged operation: $*"; }
    rfkill() { :; }
    find_interfaces() { :; }
    module_loaded() { return 1; }
    modprobe() { [[ $1 == --showconfig ]] || fail 'module loaded after cancellation'; }
    modinfo() { :; }
    grep() { [[ ${*: -1} == /proc/cmdline ]] && return 1; command grep "$@"; }
    confirm_action() { return 1; }
    if repair_wifi >/dev/null 2>&1; then fail 'cancelled repair succeeded'; fi
)
(
    install_dependencies() { :; }
    lspci() { echo 'Network controller [1234:5678]'; }
    as_root() { [[ $1 == journalctl ]] || fail 'mutated unsupported hardware'; }
    rfkill() { :; }
    find_interfaces() { :; }
    if repair_wifi >/dev/null 2>&1; then fail 'unknown hardware accepted'; fi
)
(
    install_dependencies() { :; }
    lspci() { echo 'Network controller [14e4:4331]'; }
    as_root() { [[ $1 == journalctl ]] || fail 'mutated blacklisted hardware'; }
    rfkill() { :; }
    find_interfaces() { :; }
    module_loaded() { return 1; }
    modprobe() { echo 'blacklist b43'; }
    if repair_wifi >/dev/null 2>&1; then fail 'blacklist ignored'; fi
)
(
    install_dependencies() { :; }
    lspci() { echo 'Network controller [14e4:4331]'; }
    as_root() { [[ $1 == journalctl ]] || fail 'mutated conflicting hardware'; }
    rfkill() { :; }
    find_interfaces() { :; }
    module_loaded() { return 0; }
    if repair_wifi >/dev/null 2>&1; then fail 'loaded wl ignored'; fi
)
(
    install_dependencies() { :; }
    find_interface() { echo wlan0; }
    systemctl() { [[ ${*: -1} == systemd-networkd ]]; }
    install_packages() { fail 'installed connection packages over SSH'; }
    SSH_CONNECTION='client server'
    if connect_wifi >/dev/null 2>&1; then fail 'networkd changes allowed over SSH'; fi
)
(
    install_dependencies() { :; }
    find_interface() { echo wlan0; }
    systemctl() { return 0; }
    as_root() { fail 'changed ambiguous manager configuration'; }
    if connect_wifi >/dev/null 2>&1; then fail 'ambiguous managers accepted'; fi
)
echo 'All repair and connection safety checks passed.'
(
    install_dependencies() { :; }
    lspci() { echo 'Network controller [14e4:4331]'; }
    as_root() { [[ $1 == journalctl ]] || fail 'module loaded after package failure'; }
    rfkill() { :; }
    find_interfaces() { :; }
    module_loaded() { return 1; }
    modprobe() { [[ $1 == --showconfig ]] || fail 'module loaded after package failure'; }
    modinfo() { :; }
    grep() { [[ ${*: -1} == /proc/cmdline ]] && return 1; command grep "$@"; }
    confirm_action() { :; }
    apt-cache() { :; }
    install_packages() { return 1; }
    if repair_wifi >/dev/null 2>&1; then fail 'firmware installation failure ignored'; fi
)
echo 'Firmware failure stops module loading.'
(
    repaired=0
    install_dependencies() { :; }
    lspci() { echo 'Network controller [14e4:4331]'; }
    rfkill() { :; }
    find_interfaces() { if ((repaired)); then echo wlan0; fi; }
    module_loaded() { return 1; }
    modprobe() { [[ $1 == --showconfig ]]; }
    modinfo() { :; }
    grep() { [[ ${*: -1} == /proc/cmdline ]] && return 1; command grep "$@"; }
    confirm_action() { :; }
    apt-cache() { :; }
    install_packages() { [[ $1 == firmware-b43-installer ]] || fail 'wrong firmware package'; }
    as_root() {
        case $1 in
            journalctl) echo 'b43 firmware missing' ;;
            env) [[ $* == *dpkg-reconfigure* ]] || fail 'unexpected repair command' ;;
            modprobe) [[ $2 == b43 ]] || fail 'wrong driver'; repaired=1 ;;
            udevadm) : ;;
            *) fail "Unexpected repair operation: $*" ;;
        esac
    }
    diagnose() { [[ $(find_interfaces) == wlan0 ]]; }
    repair_wifi >/dev/null || fail 'supported firmware/load path failed'
    ((repaired)) || fail 'driver never loaded'
)
echo 'Supported BCM4331 firmware/load path passed.'
# A stale b43 probe is retried without removing its bus/network dependencies.
(
    loads=0
    install_dependencies() { :; }
    lspci() { echo 'Network controller [14e4:4331]'; }
    rfkill() { :; }
    find_interfaces() { if ((loads >= 2)); then echo wlp3s0b1; fi; }
    module_loaded() { [[ $1 == b43 ]]; }
    firmware_ready() { return 0; }
    modprobe() { [[ $1 == --showconfig ]]; }
    modinfo() { :; }
    grep() { [[ ${*: -1} == /proc/cmdline ]] && return 1; command grep "$@"; }
    confirm_action() { :; }
    install_packages() { fail 'existing firmware unnecessarily downloaded'; }
    as_root() {
        case $1 in
            journalctl|udevadm) : ;;
            modprobe) [[ $2 == b43 ]] || fail 'wrong module loaded'; loads=$((loads+1)) ;;
            rmmod) [[ $# == 2 && $2 == b43 ]] || fail 'dependency removal attempted' ;;
            *) fail "Unexpected operation: $*" ;;
        esac
    }
    diagnose() { [[ $(find_interfaces) == wlp3s0b1 ]]; }
    repair_wifi >/dev/null || fail 'stale probe recovery failed'
)
(
    install_dependencies() { :; }
    find_interfaces() { echo wlp3s0b1; }
    find_interface() { echo wlp3s0b1; }
    as_root() { [[ $* == 'ip link set dev wlp3s0b1 up' ]] || fail "Unexpected prepare operation: $*"; }
    repair_wifi() { fail 'repair invoked for existing interface'; }
    prepare_wifi || fail 'down interface was not prepared'
)
(
    automatic_connect() { echo automatic; }
    [[ $(main) == automatic ]] || fail 'default entry does not use automatic flow'
    [[ $(main --connect) == automatic ]] || fail 'connect entry does not use automatic flow'
)
echo 'Automatic preparation and stale-probe recovery passed.'
