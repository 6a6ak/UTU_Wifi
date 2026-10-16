# Wi-Fi Viewer

Ubuntu/Debian Wi-Fi scanner. Run with Bash:

```sh
bash index.sh --install
bash index.sh
bash index.sh --diagnose
```

Startup checks and installs missing `iw`, `wireless-tools`, `iproute2`,
`pciutils`, and `rfkill` packages using apt (sudo is needed for non-root users).
Installation failures stop startup with the apt error visible. NetworkManager
and nmcli are optional and are not installed or enabled. Tool installation
suppresses automatic service restarts by needrestart.

Wireless interfaces are detected from sysfs, regardless of their name or network
manager. When multiple adapters exist, choose explicitly:

```sh
WIFI_INTERFACE=wlan0 bash index.sh
```

Scanning uses `iw` and requires root privileges. Errors remain visible, including
blocked radios and interfaces that are down. The program does not bring links
up/down, unblock radios, restart services, change Netplan, replace the network
manager, unload drivers, or reboot. Saved NetworkManager passwords are shown
only when that service is active and profiles are readable.

## Missing wireless interface

`--diagnose` is read-only and reports service status, missing tools, PCI drivers,
interfaces, radio blocks and relevant kernel messages. It returns a nonzero
status when no wireless interface exists. If kernel logs require privileges,
it prints a command to inspect them. Dependency installation can succeed while
hardware diagnosis still fails; installing scanning tools cannot create a
missing hardware interface.

For BCM4331, `bcma-pci-bridge` identifies the bus bridge. Check kernel logs for
`b43` probe or firmware failures. Only when missing b43 firmware is confirmed,
consider Ubuntu's `firmware-b43-installer` package from multiverse. Firmware
installation requires downloads; this program leaves driver/firmware repair to
the administrator to avoid disturbing the current connection. No driver conflict
or missing firmware is inferred solely from the PCI bridge name.

Driver reference: [Linux Wireless b43 documentation](https://wireless.docs.kernel.org/en/latest/en/users/drivers/b43.html).

## Reported diagnostic output

User-provided baseline (not generated on the development machine):

```text
Ubuntu 24.04.5 LTS
NetworkManager: inactive
systemd-networkd: active
nmcli / iwlist / iw: not found
Wi-Fi: Broadcom BCM4331 [14e4:4331]
Kernel driver: bcma-pci-bridge
Interfaces: enp2s0f0, lo, tailscale0
```
