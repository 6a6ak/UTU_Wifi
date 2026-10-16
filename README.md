# Automatic Wi-Fi setup

On Ubuntu/Debian, update and run:

```sh
git pull origin main
bash index.sh
```

The default flow now prepares Wi-Fi automatically, shows nearby networks, asks
for a network number and the Wi-Fi password, then connects. Sudo may ask for the
system account password once. There are no repeated YES prompts in this flow.

```sh
bash index.sh --setup
bash index.sh --connect
```

Both commands run the same automatic flow. Use `--menu` for the old menu.
Menu option 6 also runs the automatic flow. Scanning (options 1/3) now prepares
the interface automatically instead of stopping with `Network is down`.

## Automatic preparation

- Installs missing scanning, PCI, radio and module tools using apt.
- Detects the wireless interface from sysfs; no fixed interface name.
- For BCM4331 without an interface, checks b43 availability, module conflicts,
  blacklists and firmware; installs the matching module/firmware packages when
  necessary. Ubuntu multiverse can be enabled to obtain the firmware package.
- If b43 previously failed before firmware installation, retries only b43 using
  `rmmod b43` and `modprobe b43`, and only when no wireless interfaces exist.
  It never removes bcma, ssb, Ethernet modules or other dependencies.
- Unblocks the selected radio when software blocked, and brings the detected
  Wi-Fi interface up. A physical/BIOS radio block is reported instead.

Unknown hardware, incompatible kernels, conflicting drivers and explicit
blacklists cause a clear stop rather than an unsafe driver replacement.
For multiple adapters select one explicitly:

```sh
WIFI_INTERFACE=wlan0 bash index.sh
```

## Connection and protection of the current link

The active manager is preserved. If both NetworkManager and systemd-networkd are
active, or neither is active, the wizard stops instead of guessing ownership.
An already connected wireless interface is left connected.

**NetworkManager:** creates a scoped Wi-Fi profile and uses nmcli's secret prompt.
A failed connection removes the newly created profile.

**systemd-networkd:** uses a Wi-Fi-only `.network` file and an authentication
service for the selected interface. It does not run Netplan apply/try, restart
systemd-networkd, or touch Ethernet/Tailscale settings. `networkctl reload` loads
the new definition and `networkctl reconfigure` targets the selected Wi-Fi link.
As with any networkctl reload, unrelated pending administrator configuration
changes can also be picked up; avoid concurrent network configuration work.

The per-interface files are stored under:

```text
/etc/systemd/network/00-utu-INTERFACE.network
/etc/wpa_supplicant/utu-INTERFACE.conf
/etc/systemd/system/utu-wifi-INTERFACE.service
```

Files are private and marked as managed by this repo. Existing external files or
a supplicant owned by another service are not overwritten/stopped. On failure,
the tool restores its previous per-interface files/service state. Successful
connections are enabled for subsequent boots. No reboot is automatic.

Both paths ignore Wi-Fi DHCP default routes and DNS, keeping the existing
internet path; networkd also disables IPv6 router advertisements. The Wi-Fi
address is usable from its local subnet. Making Wi-Fi the primary internet route
is a separate administrator action. Success requires association and an IPv4
address; incorrect passwords or DHCP failure time out with an explicit error.

Passwords never enter command arguments. The networkd profile stores a derived
WPA PSK rather than the plaintext password, still protected as a secret with
mode 0600. Open/WPA personal networks are supported. Enterprise, WEP, WPA3-only,
captive portals and static addressing require different configuration. Hidden
networks can be entered manually as WPA personal. Non-UTF-8 SSIDs are not listed.

## Other commands

```sh
bash index.sh --diagnose
bash index.sh --install
bash index.sh --repair
bash index.sh --menu
```

Diagnosis is read-only; it reports services, hardware, drivers, interfaces, radio
state and kernel errors. Manual `--repair` retains step confirmations. The old
Netplan workflow is retained as `--connect-netplan` for deliberate console use;
it is not part of automatic setup.

Tool packages are `iw`, `wireless-tools`, `iproute2`, `pciutils`, `rfkill`, `kmod`.
Connection adds Python and, for networkd, wpasupplicant if missing. Package
operations use `NEEDRESTART_MODE=l` to suppress needrestart service restarts.
Actual Ubuntu hardware validation is still required; no universal repair of
physical faults or unsupported drivers is promised.

## Development checks

```sh
bash -n index.sh
bash tests/wifi_test.sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

Tests mock privileged operations and cover automatic preparation, stale b43 probe
recovery, failed package installation, scoped connection, rollback, scan parsing,
secret handling, and preserving default-route/DNS configuration. The legacy
Netplan profile tests require PyYAML.

References: [b43 driver](https://wireless.docs.kernel.org/en/latest/en/users/drivers/b43.html),
[systemd networkctl](https://www.freedesktop.org/software/systemd/man/latest/networkctl.html),
[systemd network configuration](https://www.freedesktop.org/software/systemd/man/latest/systemd.network.html).

## Reported diagnostic output

User-provided baseline:

```text
Ubuntu 24.04.5 LTS
NetworkManager: inactive
systemd-networkd: active
nmcli / iwlist / iw: not found
Wi-Fi: Broadcom BCM4331 [14e4:4331]
Kernel driver: bcma-pci-bridge
Interfaces: enp2s0f0, lo, tailscale0
```
