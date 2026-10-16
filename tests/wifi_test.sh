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
    command() { return 0; }
    as_root() { echo 'RF-kill blocked' >&2; return 1; }
    output=$(scan_wifi 2>&1) && fail 'scan failure reported success'
    [[ $output == *'RF-kill blocked'* ]] || fail 'scan error hidden'
)
echo 'All mocked regression checks passed.'
