"""Prompt locally for a WPA personal/open profile; never pass secrets in argv."""
import getpass
import os
import sys

import yaml


def build_profile(interface, ssid, password):
    if not ssid or len(ssid.encode('utf-8')) > 32:
        raise ValueError('SSID must contain 1 to 32 UTF-8 bytes.')
    if password and not (
        8 <= len(password) <= 63 and password.isascii()
        or len(password) == 64 and all(c in '0123456789abcdefABCDEF' for c in password)
    ):
        raise ValueError('Use an 8-63 ASCII character WPA passphrase or a 64-digit hex PSK.')
    return {'network': {'version': 2, 'wifis': {interface: {
        'renderer': 'networkd', 'optional': True, 'dhcp4': True,
        'dhcp4-overrides': {'use-routes': False, 'use-dns': False},
        'accept-ra': False,
        'access-points': {ssid: {'password': password} if password else {}},
    }}}}


if __name__ == '__main__':
    try:
        ssid = input('Wi-Fi SSID: ')
        password = getpass.getpass('WPA password (blank for open network): ')
        profile = build_profile(sys.argv[1], ssid, password)
        # The shell creates this file privately before this process runs.
        with open(sys.argv[2], 'w', encoding='utf-8') as stream:
            os.chmod(sys.argv[2], 0o600)
            yaml.safe_dump(profile, stream, allow_unicode=True)
    except (ValueError, EOFError, KeyboardInterrupt) as exc:
        print(f'Profile cancelled/invalid: {exc}', file=sys.stderr)
        sys.exit(1)
