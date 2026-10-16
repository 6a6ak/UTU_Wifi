# UTU Wi-Fi

Automatic Wi-Fi preparation, diagnosis, and connection for Ubuntu and Debian-based systems. Run the program, select a network by number, and enter its password. It installs missing tools, detects and enables the wireless interface, and handles known BCM4331 firmware and driver initialization failures.

**The existing internet route and DNS configuration are preserved.** This tool adds a Wi-Fi connection; it does not automatically make Wi-Fi the server's primary internet connection.

## Quick start

### First installation

```bash
git clone https://github.com/6a6ak/UTU_Wifi.git
cd UTU_Wifi
bash index.sh
```

### Update an existing checkout

Run inside the project directory:

```bash
git pull origin main
bash index.sh
```

If needed, enter the directory first. Use the location where you cloned the repository; for example:

```bash
cd ~/codes/UTU_Wifi
```

### What happens next

1. Missing tools are installed when necessary.
2. The wireless interface is detected and prepared. Known BCM4331 driver and firmware problems are checked when no interface exists.
3. Nearby networks are listed with a number, signal strength, and security type.
4. Enter the **network number**, then its Wi-Fi password. Password characters are hidden.
5. The program checks Wi-Fi association and IPv4 address assignment, then reports the result.

Sudo may also request your server account password for administrative operations. That is separate from the Wi-Fi password. The automatic flow does not ask for a separate YES confirmation at every step.

Choose `0` to enter a hidden or missing network's SSID manually. This manual entry path assumes a WPA personal network.

## Requirements and support

- Ubuntu or a Debian-based Linux system with `apt-get`. The hardware-specific repair path targets Ubuntu.
- Administrative access through root or sudo.
- An existing internet connection when packages or firmware must be downloaded.
- A wireless adapter and a compatible kernel driver.
- Exactly one supported network manager active: **NetworkManager** or **systemd-networkd**.

If both managers are active, or neither is active, automatic connection stops rather than changing managers or guessing ownership.

General interface preparation works with existing wireless interfaces. **Hardware-specific automatic driver and firmware repair currently targets Broadcom BCM4331 [14e4:4331].** Unsupported hardware, physical faults, and every possible kernel/driver combination cannot be repaired automatically.

## Automatic preparation

### Install missing tools

The program checks command availability and installs missing packages:

| Command | Package |
| --- | --- |
| `iw` | `iw` |
| `iwlist` | `wireless-tools` |
| `ip` | `iproute2` |
| `lspci` | `pciutils` |
| `rfkill` | `rfkill` |
| `modprobe`, `modinfo` | `kmod` |

Connection setup also installs `python3` and, for networkd, `wpasupplicant` if missing. Package and download errors remain visible and stop the relevant workflow. Package operations set `NEEDRESTART_MODE=l` to suppress automatic service restarts by needrestart.

### Detect and enable the interface

Wireless interfaces are discovered through sysfs; no interface name is hardcoded. The automatic flow clears a software block on the selected radio and brings its interface up.

If multiple adapters exist, choose one explicitly. Replace the example name with your interface:

```bash
WIFI_INTERFACE=wlan0 bash index.sh
```

A hardware radio block cannot be cleared by software. Enable the physical switch or BIOS radio setting before retrying.

### Repair the supported Broadcom adapter

When no wireless interface exists, the program checks module availability, firmware, module blacklists, and conflicting drivers. When necessary, it installs the matching Ubuntu extra-modules package and firmware installer:

```text
linux-modules-extra-<kernel-version>
firmware-b43-installer
```

Ubuntu multiverse may be enabled to obtain the firmware installer. This requires access to the configured package repositories and firmware downloads.

If b43 failed before firmware was installed, the program can retry that module after the required firmware is available, **only when no wireless interfaces exist**:

```bash
rmmod b43
modprobe b43
```

It does not remove bcma, ssb, Ethernet modules, or other dependencies. Conflicting drivers, explicit blacklists, and unsupported kernels produce a clear stop rather than an automatic replacement or blacklist edit.

## How connection works

### NetworkManager

The program creates a new Wi-Fi profile and uses nmcli's interactive secret prompt. A failed connection removes the new profile. After success, autoconnection is enabled for that profile.

### systemd-networkd

The program creates a network definition and an authentication service for the selected interface, reloads network definitions, and reconfigures that Wi-Fi link:

```text
networkctl reload
networkctl reconfigure <interface>
```

The automatic flow does not run global Netplan apply/try or restart systemd-networkd. A networkctl reload can also pick up unrelated pending administrator changes, so avoid concurrent network configuration work.

Per-interface files are stored at these paths; `INTERFACE` is replaced with the actual interface name:

```text
/etc/systemd/network/00-00-utu-INTERFACE.network
/etc/wpa_supplicant/utu-INTERFACE.conf
/etc/systemd/system/utu-wifi-INTERFACE.service
```

The supplicant configuration containing the Wi-Fi key remains private with mode `0600`. The network definition contains no credentials and uses mode `0644` so the systemd-network user can read it.

Existing external files at these paths are not overwritten. A supplicant owned by another service is not stopped. On connection failure, the program attempts to restore its previous per-interface files and service state. Successful connections enable the authentication service for subsequent boots.

## Existing connections and credentials

- The active network manager is not automatically replaced, installed, or enabled.
- Ethernet and tunnel settings are not directly edited.
- Wi-Fi DHCP default routes and DNS are ignored to preserve the current internet path. The networkd configuration also disables IPv6 router advertisements.
- An already associated wireless interface is left connected.
- The server is never rebooted automatically.
- Passwords are not passed as command-line arguments.

The networkd backend stores a derived WPA PSK rather than the plaintext passphrase. **That PSK is still a usable credential.** Keep connection files and any output containing credentials private.

The Wi-Fi IPv4 address is usable on its local subnet. Making Wi-Fi the primary internet route is a separate administrator action.

## Commands

| Command | Behavior |
| --- | --- |
| `bash index.sh` | Automatic preparation and connection |
| `bash index.sh --setup` | Same automatic flow |
| `bash index.sh --connect` | Same automatic flow |
| `bash index.sh --diagnose` | Read-only diagnostic report |
| `bash index.sh --install` | Install missing tools, then diagnose |
| `bash index.sh --repair` | Manual repair with step-by-step confirmations |
| `bash index.sh --menu` | Open the optional menu |
| `bash index.sh --help` | Show available options |

Installing tools does not itself create a missing hardware interface. Diagnosis returns a nonzero status when no wireless interface exists, even if tool installation succeeded.

The optional menu provides:

| Option | Action |
| --- | --- |
| `1`, `3` | Prepare the interface automatically and scan networks, frequencies, and signals |
| `2` | Show saved NetworkManager Wi-Fi passwords when that manager is active and profiles are readable |
| `4` | Diagnose Wi-Fi |
| `5` | Run manual repair |
| `6` | Run automatic preparation and connection |
| `0` | Exit |

The legacy Netplan connection workflow remains available for deliberate console use:

```bash
bash index.sh --connect-netplan
```

It is not used by automatic setup. It can reconfigure other interfaces and refuses detected SSH sessions.

## Troubleshooting

### No wireless interface

PCI detection does not prove that the Wi-Fi driver initialized. For the supported adapter, the automatic flow attempts known repairs. If it stops, inspect its error and diagnostic report:

```bash
bash index.sh --diagnose
```

If kernel logs are restricted, diagnosis prints a privileged command to read them. The repair flow reads kernel logs with administrative access.

### Network is down

The current automatic flow and menu scans bring the wireless interface up. Update the repository if you still see the old manual-preparation message. Persistent failures can indicate a driver problem or blocked radio.

### Wrong password or no IPv4 address

Check the password, network security type, and the access point's DHCP service, then rerun the program. The networkd path waits up to 45 seconds for association and an IPv4 address after selecting its network definition. Failures trigger an error and attempted rollback.

### Connected, but internet still uses Ethernet

This is intentional. Wi-Fi does not replace the existing default route or DNS. Changing the server's primary internet connection requires separate configuration.

### Unsupported authentication

The wizard supports open and WPA personal networks. Enterprise authentication, WEP, WPA3-only networks, captive portal login, and static addressing require different configuration. Non-UTF-8 SSIDs are not listed.

## Reported real-world connection

A user reported successful connection on the supported Broadcom adapter after updating the repository, selecting a network, and entering its password:

```text
Connected on wlp3s0b1. IPv4: 192.168.88.245
The existing internet default route and DNS are preserved.
```

This confirms association and IPv4 assignment in that run. The address is an example from that server and can differ on another machine or after DHCP renewal. The report does not establish internet access through Wi-Fi, remote reachability from other networks, or successful reconnection after reboot.

## Verify connection after a planned reboot

Successful setup enables the relevant service or profile for subsequent boots. There is no need to reboot immediately for verification. After your next planned reboot, check the connection using your actual interface name:

```bash
iw dev wlp3s0b1 link
ip -4 -brief address show dev wlp3s0b1
```

The first command should show association with an access point. The second should show the assigned IPv4 address; it does not have to match the previous address.

For systemd-networkd, check the tool's authentication service and interface status:

```bash
systemctl is-enabled utu-wifi-wlp3s0b1.service
systemctl status utu-wifi-wlp3s0b1.service --no-pager
networkctl status wlp3s0b1 --no-pager --full
```

For NetworkManager, check active profiles instead:

```bash
nmcli connection show --active
```

If connection fails, collect diagnostics. For the networkd backend, also inspect the per-interface service log:

```bash
bash index.sh --diagnose
sudo journalctl -b -u utu-wifi-wlp3s0b1.service --no-pager -n 60
```

Retry preparation and connection with:

```bash
bash index.sh
```

An already associated wireless interface is preserved. Review diagnostic output before sharing it, and do not publish credential files.

## Development checks

```bash
bash -n index.sh
bash tests/wifi_test.sh
python3 -m unittest discover -s tests -p 'test_*.py'
```

Tests mock administrative operations and cover interface preparation, stale driver probe recovery, installation failures, scan parsing, credential handling, network-definition permissions, and rollback. The legacy Netplan profile tests require PyYAML.

These checks do not replace validation on actual Ubuntu hardware.

## Original diagnostic baseline

User-provided state before repair:

```text
Ubuntu 24.04.5 LTS
NetworkManager: inactive
systemd-networkd: active
nmcli / iwlist / iw: not found
Wi-Fi: Broadcom BCM4331 [14e4:4331]
Kernel driver: bcma-pci-bridge
Interfaces: enp2s0f0, lo, tailscale0
```
