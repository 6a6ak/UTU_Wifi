# UTU Wi-Fi

Prepare a Linux wireless adapter and connect to Wi-Fi from the terminal. UTU Wi-Fi installs missing tools, detects and enables the wireless interface, lists nearby networks, and prompts for the selected network's password.

**Existing internet routing and DNS are preserved.** Connecting with this tool adds a Wi-Fi connection without automatically making it the computer's primary internet connection.

## Requirements

- Ubuntu or a Debian-based Linux distribution with `apt-get` and systemd.
- A wireless adapter supported by the installed kernel.
- Root or sudo access for installation and network configuration.
- An existing internet connection if packages or firmware need downloading.
- Exactly one active supported network manager: **NetworkManager** or **systemd-networkd**.

Existing wireless interfaces can be prepared regardless of their name. Automatic hardware-specific driver and firmware repair currently targets **Broadcom BCM4331 [14e4:4331] on Ubuntu**. It is not a universal driver installer.

Supported networks: open networks and WPA personal networks. Enterprise authentication, WEP, WPA3-only networks, captive portal login, and static addressing require separate configuration.

## Install and connect

Open a terminal on the computer that needs Wi-Fi and run:

```bash
git clone https://github.com/6a6ak/UTU_Wifi.git
cd UTU_Wifi
bash index.sh
```

Git must already be installed to clone the repository. If it is missing on Ubuntu/Debian:

```bash
sudo apt-get update
sudo apt-get install git
```

The program will:

1. Install missing tools.
2. Detect the wireless interface and prepare it for scanning.
3. Attempt supported BCM4331 repairs if no wireless interface exists.
4. Display nearby networks with a number, signal strength, and security type.
5. Ask for the network number and Wi-Fi password.
6. Check association and IPv4 address assignment, then report the connection result.

Enter the **number from the displayed list**, not the network name. Password characters are hidden while typing. A sudo prompt asks for the local account password, which is separate from the Wi-Fi password.

Choose `0` to enter a hidden or missing network's SSID manually. Manual entry assumes a WPA personal network. Non-UTF-8 SSIDs are not listed.

After a successful connection, the relevant profile or authentication service is enabled for subsequent boots. If the wireless interface is already associated, the program preserves that connection.

### Multiple wireless adapters

List wireless interfaces:

```bash
iw dev
```

Select one explicitly when starting the program. Replace `wlan0` with the interface name shown on the computer:

```bash
WIFI_INTERFACE=wlan0 bash index.sh
```

### Update

Open a terminal **inside the cloned repository directory** and run:

```bash
git pull origin main
bash index.sh
```

## Verify the connection

The success message includes the interface name and assigned IPv4 address. To check them again, set the interface name from that message:

```bash
WIFI_INTERFACE=wlan0
iw dev "$WIFI_INTERFACE" link
ip -4 -brief address show dev "$WIFI_INTERFACE"
```

`iw` should show association with an access point, and `ip` should show an IPv4 address. DHCP addresses can change after renewal or reboot.

For systemd-networkd, check the authentication service and interface configuration:

```bash
systemctl is-enabled "utu-wifi-${WIFI_INTERFACE}.service"
systemctl status "utu-wifi-${WIFI_INTERFACE}.service" --no-pager
networkctl status "$WIFI_INTERFACE" --no-pager --full
```

For NetworkManager, check active profiles:

```bash
nmcli connection show --active
```

These checks can also be used after a planned reboot. An immediate reboot is not required to complete setup.

## Commands

Run these commands from the repository directory:

| Command | Action |
| --- | --- |
| `bash index.sh` | Prepare Wi-Fi automatically and connect |
| `bash index.sh --setup` | Same automatic flow |
| `bash index.sh --connect` | Same automatic flow |
| `bash index.sh --diagnose` | Read-only diagnostic report |
| `bash index.sh --install` | Install missing tools, then diagnose |
| `bash index.sh --repair` | Repair with step-by-step confirmations |
| `bash index.sh --menu` | Open the optional menu |
| `bash index.sh --help` | Show available options |

Installing tools does not guarantee that a hardware interface can be created. Diagnosis returns a nonzero status when no wireless interface exists, even if tool installation succeeded.

### Optional menu

| Option | Action |
| --- | --- |
| `1`, `3` | Prepare the interface and scan networks, frequencies, and signals |
| `2` | Show saved NetworkManager Wi-Fi passwords, subject to service status and profile permissions |
| `4` | Diagnose Wi-Fi |
| `5` | Repair with confirmations |
| `6` | Run automatic setup and connection |
| `0` | Exit |

## What setup changes

### Dependencies

Only missing tools are installed through apt:

| Tools | Package |
| --- | --- |
| `iw` | `iw` |
| `iwlist` | `wireless-tools` |
| `ip` | `iproute2` |
| `lspci` | `pciutils` |
| `rfkill` | `rfkill` |
| `modprobe`, `modinfo` | `kmod` |

Connection setup also installs `python3` and, for networkd, `wpasupplicant` when missing. Package operations set `NEEDRESTART_MODE=l` to suppress needrestart's automatic service restarts. Download or installation failures stop the relevant workflow and leave the error visible.

### Interface and driver preparation

The automatic flow detects wireless interfaces through sysfs, clears a software block on the selected radio, and brings its interface up. Hardware radio blocks require the physical switch or BIOS setting to be enabled manually.

For BCM4331 without a wireless interface, setup checks module availability, firmware, blacklists, and conflicting drivers. It may install:

```text
linux-modules-extra-<kernel-version>
firmware-b43-installer
```

Ubuntu multiverse may be enabled to obtain the firmware installer. If b43 previously failed before firmware installation, setup can retry only that module after the required firmware is available, and only when no wireless interfaces exist. Bus modules, Ethernet modules, and other dependencies are not removed.

Unsupported kernels, conflicting drivers, and explicit module blacklists cause a clear stop rather than an automatic driver replacement or blacklist edit.

### NetworkManager connections

A new Wi-Fi profile is created, and nmcli handles the interactive password prompt. A failed connection removes the newly created profile. Successful connections enable profile autoconnection.

### systemd-networkd connections

Setup creates a network definition and an authentication service for the selected interface. It runs `networkctl reload` and reconfigures that Wi-Fi interface without restarting the network manager or running global Netplan apply/try.

A reload can also pick up unrelated pending administrator changes. Avoid changing network configuration with another tool during setup.

Files are created at the following paths, with `INTERFACE` replaced by the selected interface name:

```text
/etc/systemd/network/00-00-utu-INTERFACE.network
/etc/wpa_supplicant/utu-INTERFACE.conf
/etc/systemd/system/utu-wifi-INTERFACE.service
```

The supplicant configuration contains a derived WPA key and remains private with mode `0600`. The network definition contains no credentials and uses mode `0644` so the systemd-network user can read it.

Existing external files at these paths are not overwritten, and a supplicant owned by another service is not stopped. On failure, setup attempts to restore its previous per-interface files and service state.

## Existing connectivity and credentials

- The active network manager is not automatically replaced, installed, or enabled.
- Ethernet and tunnel settings are not directly edited.
- Wi-Fi DHCP default routes and DNS are ignored. The networkd profile also disables IPv6 router advertisements.
- The system is never rebooted automatically.
- Passwords are not passed in command-line arguments.

The Wi-Fi address is usable on its local subnet. **Making Wi-Fi the primary internet route requires separate administrator configuration.**

A derived WPA key is still a usable credential. Do not publish connection files or logs containing secrets.

## Troubleshooting

### No wireless interface

Run:

```bash
bash index.sh --diagnose
```

Hardware detection alone does not prove that a Wi-Fi driver initialized. The automatic flow attempts known repairs for the supported Broadcom adapter. Other hardware, physical faults, incompatible kernels, or explicit blacklists may require manual repair.

If kernel logs are restricted, diagnosis prints a privileged command to read them.

### Network is down or the radio is blocked

The automatic flow brings the interface up and clears its software radio block. If the error persists, inspect the diagnostic output for driver errors or a hardware block. A physical or BIOS radio switch must be enabled manually.

### Incorrect password or no IPv4 address

Check the network password, security type, and the access point's DHCP service, then rerun:

```bash
bash index.sh
```

The networkd path waits up to 45 seconds for association and an IPv4 address after selecting its network definition. Failure produces an error and attempted rollback.

### Connected, but internet still uses another interface

This is expected: setup preserves the current default route and DNS. It does not automatically switch internet traffic to Wi-Fi.

### Both network managers are active

Automatic connection requires exactly one supported active manager. Determine which manager should own the wireless interface before retrying; the program does not switch managers automatically.

### Inspect networkd authentication errors

Set the actual interface name before running:

```bash
WIFI_INTERFACE=wlan0
sudo journalctl -b -u "utu-wifi-${WIFI_INTERFACE}.service" --no-pager -n 60
```

### Legacy Netplan workflow

An alternative console-only workflow is available:

```bash
bash index.sh --connect-netplan
```

This is not part of automatic setup. It can reconfigure other interfaces and refuses detected SSH sessions. Use the normal automatic flow unless the Netplan workflow is specifically required.

## Development

```bash
bash -n index.sh
bash tests/wifi_test.sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

Tests mock administrative operations and cover interface preparation, stale driver probe recovery, installation failures, scan parsing, credential handling, configuration permissions, and rollback. The legacy Netplan profile tests require PyYAML.

Mocked tests do not replace validation on actual hardware. Supported driver repair and successful connection on one system do not guarantee compatibility with every adapter or kernel.
