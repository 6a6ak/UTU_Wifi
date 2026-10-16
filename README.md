# Wi-Fi setup and repair

Ubuntu/Debian tool installation, diagnosis and interactive Wi-Fi repair.

```sh
git pull origin main
bash index.sh
```

Menu: **4 diagnose**, **5 repair**, **6 connect**. Direct commands:

```sh
bash index.sh --install
bash index.sh --diagnose
bash index.sh --repair
bash index.sh --connect
```

## BCM4331 repair

Choose repair from the existing wired session. The wizard reads privileged
kernel logs and checks hardware, radio blocks, b43 availability, blacklists
and loaded conflicting wl modules. For BCM4331 it offers:

- The matching Ubuntu extra-modules package if b43 is unavailable.
- Installation/reconfiguration of `firmware-b43-installer` and, if necessary,
  explicit enablement of Ubuntu multiverse.
- Loading b43 without unloading other drivers.
- Explicit unblocking and bringing up the detected wireless interface.

Every modifying step requires confirmation. Package/download/loading failures
stop repair and show their errors. Firmware requires internet access. If no
interface appears after loading, a previously failed probe may require a controlled
reload or reboot; neither is automatic. Run repair again once the interface
exists to enable/scan it, then select connect.

## Connection

The wizard preserves the active manager; ambiguous or absent managers cause a stop.

- **NetworkManager:** creates an open/WPA personal profile, using nmcli's secret
  prompt. An already connected wireless interface is left alone.
- **systemd-networkd:** installs Netplan/WPA tools, prompts for credentials and
  builds a private Wi-Fi-only profile. Existing Netplan Wi-Fi definitions are
  not merged or overwritten. Uses `netplan try --config-file` with a 120-second
  confirmation timeout and Netplan's configuration backup. Accepted profiles
  persist. Run from a local/out-of-band console: detected SSH sessions are refused
  because Netplan can reconfigure other interfaces and rollback is not guaranteed.

Both connection paths ignore Wi-Fi DHCP default routes and DNS, preserving the
existing internet path. The new Wi-Fi address is usable on its local subnet;
making Wi-Fi the server's internet route is a separate administrator action.
The networkd profile disables IPv6 router advertisements for the same reason.
Only open and WPA personal networks are supported by the wizard; enterprise,
captive portal, static addressing and WPA3-only setups require manual configuration.

Check Netplan's accept/revert message, runtime state and files under `/etc/netplan`
after trying a connection. Exit code alone does not establish acceptance. Verify
rollback before rebooting. Passwords never enter command arguments; persistent
connection profiles contain secrets and require appropriate permissions.

## Diagnosis and scope

`--diagnose` is read-only. It reports missing tools, PCI drivers, services,
interfaces, rfkill and relevant kernel messages. Restricted kernel logs get an
explicit privileged command; repair reads them with sudo. Missing interfaces
return a nonzero diagnostic status.

Startup installs missing `iw`, `wireless-tools`, `iproute2`, `pciutils`, `rfkill`
and `kmod` with apt. NetworkManager is never installed/enabled automatically.
`NEEDRESTART_MODE=l` suppresses needrestart service restarts during installation.
No workflow unloads drivers, edits blacklists, switches managers or reboots.

Interfaces are detected from sysfs. For multiple adapters select explicitly:

```sh
WIFI_INTERFACE=wlan0 bash index.sh
```

Hardware-specific automatic repair targets **BCM4331 [14e4:4331]**. Unsupported
hardware, conflicting drivers/blacklists, custom kernels, hardware radio switches,
Secure Boot errors and physical faults receive diagnostics or a clear stop.
This cannot guarantee repair of every hardware/kernel configuration.
`bcma-pci-bridge` alone does not establish a firmware failure.

References: [Linux Wireless b43](https://wireless.docs.kernel.org/en/latest/en/users/drivers/b43.html),
[Ubuntu firmware package](https://packages.ubuntu.com/search?keywords=firmware-b43-installer),
[Netplan try and rollback limitations](https://netplan.readthedocs.io/en/stable/netplan-try/).

## Development checks

```sh
bash -n index.sh
bash tests/wifi_test.sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

Shell checks mock privileged operations; Python checks require PyYAML. Actual
Ubuntu driver/connection behavior still requires testing on real hardware.

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
