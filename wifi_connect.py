"""Scoped Wi-Fi connection wizard. No manager switches or global Netplan apply."""
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid

MARKER = '# Managed by UTU_Wifi\n'


def run(*args, check=True):
    result = subprocess.run(args, text=True, capture_output=True,
                            env={**os.environ, 'LC_ALL': 'C'})
    if check and result.returncode:
        # Commands never contain passwords, and configuration contents are not logged.
        raise RuntimeError(f'{args[0]} failed: {result.stderr.strip() or result.stdout.strip()}')
    return result


def active(name):
    return run('systemctl', 'is-active', '--quiet', name, check=False).returncode == 0


def parse_scan(output):
    networks = {}
    for block in re.split(r'(?m)^BSS ', output)[1:]:
        match = re.search(r'^\s*SSID: (.*)$', block, re.M)
        if not match or not match[1]:
            continue
        try:
            ssid = re.sub(rb'\\x([a-fA-F0-9]{2})',
                          lambda value: bytes.fromhex(value[1].decode()),
                          match[1].encode('utf-8')).decode('utf-8')
        except UnicodeDecodeError:
            continue
        signal = re.search(r'signal:\s*(-?[\d.]+)', block)
        signal = float(signal[1]) if signal else -999
        if re.search(r'Authentication suites:.*PSK', block):
            security = 'wpa'
        elif 'Privacy' in block or re.search(r'^\s*(RSN:|WPA:)', block, re.M):
            security = 'unsupported'
        else:
            security = 'open'
        if ssid not in networks or signal > networks[ssid]['signal']:
            networks[ssid] = dict(ssid=ssid, signal=signal, security=security)
    return sorted(networks.values(), key=lambda item: item['signal'], reverse=True)


def choose_network(interface):
    scan = run('iw', 'dev', interface, 'scan')
    networks = parse_scan(scan.stdout)
    for number, network in enumerate(networks, 1):
        # JSON escaping prevents an SSID from injecting terminal control sequences.
        print(f'{number}) {json.dumps(network["ssid"], ensure_ascii=True)}  '
              f'{network["signal"]:g} dBm  {network["security"]}')
    print('0) Enter a hidden/missing network name')
    while True:
        answer = input('Network number: ')
        if answer == '0':
            ssid = input('SSID: ')
            return dict(ssid=ssid, security='wpa')
        if answer.isdigit() and 1 <= int(answer) <= len(networks):
            selected = networks[int(answer) - 1]
            if selected['security'] == 'unsupported':
                print('Enterprise, WEP and WPA3-only networks need a different authentication setup.')
                continue
            return selected
        print('Select a number from the list.')


def supplicant_config(ssid, password):
    encoded = ssid.encode('utf-8')
    if not 1 <= len(encoded) <= 32:
        raise ValueError('SSID must contain 1-32 UTF-8 bytes.')
    if not password:
        authentication = 'key_mgmt=NONE'
    else:
        if len(password) == 64 and re.fullmatch('[0-9a-fA-F]{64}', password):
            psk = password.lower()
        elif password.isascii() and 8 <= len(password) <= 63:
            psk = hashlib.pbkdf2_hmac('sha1', password.encode(), encoded, 4096, 32).hex()
        else:
            raise ValueError('WPA password must be 8-63 ASCII characters or a 64-digit hex PSK.')
        authentication = f'key_mgmt=WPA-PSK\n    psk={psk}'
    return (MARKER + 'ctrl_interface=/run/wpa_supplicant\nupdate_config=0\nnetwork={\n'
            f'    ssid={encoded.hex()}\n    scan_ssid=1\n    {authentication}\n}}\n')


def network_config(interface):
    return (MARKER + f'[Match]\nName={interface}\n\n[Network]\nDHCP=ipv4\n'
            'IPv6AcceptRA=no\nLinkLocalAddressing=no\n\n[DHCPv4]\n'
            'UseRoutes=no\nUseGateway=no\nUseDNS=no\nUseNTP=no\n'
            'UseHostname=no\nUseDomains=no\nRouteMetric=2048\n')


def wait_address(interface, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        link = run('iw', 'dev', interface, 'link', check=False).stdout
        addresses = json.loads(run('ip', '-j', '-4', 'address', 'show', 'dev', interface).stdout)
        ips = [item['local'] for link_info in addresses
               for item in link_info.get('addr_info', []) if item.get('scope') == 'global']
        if 'Connected to ' in link and ips:
            print(f'Connected on {interface}. IPv4: {", ".join(ips)}')
            print('The existing internet default route and DNS are preserved.')
            return
        time.sleep(1)
    raise RuntimeError('No authenticated Wi-Fi/IPv4 connection after 45 seconds. '
                       'Check password, AP compatibility and DHCP availability.')


def write_private(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise RuntimeError(f'Refusing symbolic link: {path}')
    # Files containing PSKs are never world readable, even during creation.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(content)


def connect_networkd(interface, ssid, password):
    unit = f'utu-wifi-{interface}.service'
    conf = Path(f'/etc/wpa_supplicant/utu-{interface}.conf')
    network = Path(f'/etc/systemd/network/00-utu-{interface}.network')
    service = Path('/etc/systemd/system') / unit
    files = (conf, network, service)
    for path in files:
        if path.is_symlink() or (path.exists() and not path.read_text().startswith(MARKER)):
            raise RuntimeError(f'Refusing to overwrite an external configuration: {path}')
    was_active = active(unit)
    was_enabled = run('systemctl', 'is-enabled', '--quiet', unit, check=False).returncode == 0
    if not was_active and run('wpa_cli', '-i', interface, 'ping', check=False).stdout.strip() == 'PONG':
        raise RuntimeError('Another supplicant owns this interface; no service was stopped.')
    previous = {path: path.read_text() if path.exists() else None for path in files}
    executable = shutil.which('wpa_supplicant')
    if not executable:
        raise RuntimeError('wpa_supplicant is missing.')
    contents = supplicant_config(ssid, password)
    try:
        if was_active:
            run('systemctl', 'stop', unit)
        write_private(conf, contents)
        write_private(network, network_config(interface))
        write_private(service, MARKER + '[Unit]\nDescription=UTU Wi-Fi authentication\n'
                      f'BindsTo=sys-subsystem-net-devices-{interface}.device\n'
                      f'After=sys-subsystem-net-devices-{interface}.device\n\n'
                      f'[Service]\nExecStart={executable} -i {interface} -c {conf}\n'
                      'Restart=on-failure\nRestartSec=3\n\n[Install]\nWantedBy=multi-user.target\n')
        run('systemctl', 'daemon-reload')
        run('networkctl', 'reload')
        run('networkctl', 'reconfigure', interface)
        status = run('networkctl', '--no-pager', 'status', interface).stdout
        if str(network) not in status:
            raise RuntimeError('An earlier networkd configuration owns this interface; automatic override refused.')
        run('systemctl', 'start', unit)
        wait_address(interface)
        run('systemctl', 'enable', unit)
    except (Exception, KeyboardInterrupt):
        # Restore only this tool's per-interface files and service.
        run('systemctl', 'stop', unit, check=False)
        if not was_enabled:
            run('systemctl', 'disable', unit, check=False)
        for path, original in previous.items():
            if original is None:
                path.unlink(missing_ok=True)
            else:
                write_private(path, original)
        run('systemctl', 'daemon-reload', check=False)
        run('networkctl', 'reload', check=False)
        run('networkctl', 'reconfigure', interface, check=False)
        if was_active:
            run('systemctl', 'start', unit, check=False)
        raise


def connect_nm(interface, ssid, security):
    profile = f'utu-wifi-{uuid.uuid4()}'
    args = ['nmcli', 'connection', 'add', 'type', 'wifi', 'ifname', interface,
            'con-name', profile, 'ssid', ssid, 'connection.autoconnect', 'no',
            'ipv4.method', 'auto', 'ipv4.never-default', 'yes',
            'ipv4.ignore-auto-dns', 'yes', 'ipv4.route-metric', '2048', 'ipv6.method', 'disabled']
    if security == 'wpa':
        args += ['wifi-sec.key-mgmt', 'wpa-psk']
    run(*args)
    try:
        # nmcli owns the secret prompt; no password in argv or logs.
        subprocess.run(['nmcli', '--ask', 'connection', 'up', 'id', profile], check=True)
        wait_address(interface)
        run('nmcli', 'connection', 'modify', 'id', profile, 'connection.autoconnect', 'yes')
    except (Exception, KeyboardInterrupt):
        run('nmcli', 'connection', 'delete', 'id', profile, check=False)
        raise


def main(interface):
    if not re.fullmatch(r'[A-Za-z0-9_]{1,15}', interface):
        raise ValueError('Unsupported interface name; use a plain alphanumeric Linux interface name.')
    nm, networkd = active('NetworkManager'), active('systemd-networkd')
    if nm == networkd:
        raise RuntimeError('Expected exactly one active network manager; no manager will be changed.')
    if 'Connected to ' in run('iw', 'dev', interface, 'link').stdout:
        print('This wireless interface is already connected; keeping the current connection.')
        return
    selected = choose_network(interface)
    if nm:
        connect_nm(interface, selected['ssid'], selected['security'])
    else:
        password = getpass.getpass('Wi-Fi password: ') if selected['security'] == 'wpa' else ''
        connect_networkd(interface, selected['ssid'], password)


if __name__ == '__main__':
    try:
        if os.geteuid() != 0:
            raise RuntimeError('Run through bash index.sh so privileges and dependencies are prepared.')
        main(sys.argv[1])
    except (Exception, KeyboardInterrupt) as exc:
        print(f'Wi-Fi setup failed: {exc}', file=sys.stderr)
        sys.exit(1)
