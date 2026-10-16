import hashlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import wifi_connect as wifi


class WizardTests(unittest.TestCase):
    def test_scan_deduplicates_and_detects_security(self):
        scan = '''BSS 00:11:22:33:44:55(on wlan0)
    signal: -70.0 dBm
    SSID: home
    RSN:
         Authentication suites: PSK
BSS 00:11:22:33:44:66(on wlan0)
    signal: -30.0 dBm
    SSID: home
    RSN:
         Authentication suites: PSK SAE
BSS 00:11:22:33:44:77(on wlan0)
    signal: -40.0 dBm
    SSID: guest
BSS 00:11:22:33:44:88(on wlan0)
    signal: -50.0 dBm
    SSID: enterprise
    RSN:
         Authentication suites: IEEE 802.1X
'''
        networks = wifi.parse_scan(scan)
        self.assertEqual([n['ssid'] for n in networks], ['home', 'guest', 'enterprise'])
        self.assertEqual([n['security'] for n in networks], ['wpa', 'open', 'unsupported'])
        self.assertEqual(networks[0]['signal'], -30)

    def test_escaped_ssid(self):
        result = wifi.parse_scan('BSS 00:00:00:00:00:00\n SSID: wifi\\x0aother\n signal: -20\n')
        self.assertEqual(result[0]['ssid'], 'wifi\nother')

    def test_secrets_are_hashed_and_ssid_is_hex(self):
        ssid = 'wifi"\nnetwork={}'
        password = 'password123'
        config = wifi.supplicant_config(ssid, password)
        self.assertNotIn(password, config)
        self.assertNotIn(ssid, config)
        self.assertIn('ssid=' + ssid.encode().hex(), config)
        expected = hashlib.pbkdf2_hmac('sha1', password.encode(), ssid.encode(), 4096, 32).hex()
        self.assertIn('psk=' + expected, config)
        with self.assertRaises(ValueError):
            wifi.supplicant_config('wifi', 'short')

    def test_routes_and_dns_preserved(self):
        config = wifi.network_config('wlp3s0b1')
        self.assertIn('Name=wlp3s0b1\n', config)
        for setting in ('UseRoutes=no', 'UseGateway=no', 'UseDNS=no', 'IPv6AcceptRA=no'):
            self.assertIn(setting, config)

    def exercise_networkd(self, fail=False):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            commands = []
            paths = [base / 'etc/wpa_supplicant/utu-wlan0.conf',
                     base / 'etc/systemd/network/00-00-utu-wlan0.network',
                     base / 'etc/systemd/system/utu-wifi-wlan0.service']
            if fail:
                for path in paths:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(wifi.MARKER + 'previous configuration')

            def execute(*args, check=True):
                commands.append(args)
                output = '  Network File: ' + str(paths[1]) if args[:2] == ('networkctl', '--no-pager') else ''
                return subprocess.CompletedProcess(args, 0, stdout=output, stderr='')

            def write(path, content):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)

            with patch.object(wifi, 'Path', side_effect=lambda name: base / name.lstrip('/')), \
                 patch.object(wifi, 'run', side_effect=execute), \
                 patch.object(wifi, 'active', return_value=False), \
                 patch.object(wifi, 'write_private', side_effect=write), \
                 patch.object(wifi.shutil, 'which', return_value='/sbin/wpa_supplicant'), \
                 patch.object(wifi, 'wait_address', side_effect=RuntimeError('bad password') if fail else None):
                if fail:
                    with self.assertRaisesRegex(RuntimeError, 'bad password'):
                        wifi.connect_networkd('wlan0', 'home', 'password123')
                    for path in paths:
                        self.assertEqual(path.read_text(), wifi.MARKER + 'previous configuration')
                else:
                    wifi.connect_networkd('wlan0', 'home', 'password123')
                    self.assertIn('psk=', paths[0].read_text())
            self.assertIn(('networkctl', 'reconfigure', 'wlan0'), commands)
            start_index = commands.index(('systemctl', 'start', 'utu-wifi-wlan0.service'))
            status_index = next(i for i, cmd in enumerate(commands) if cmd[:2] == ('networkctl', '--no-pager'))
            self.assertLess(start_index, status_index)
            for command in commands:
                self.assertNotIn('password123', ' '.join(command))
                self.assertNotIn('netplan', command)
                self.assertNotIn('restart', command)
                self.assertNotIn('systemd-networkd', command)

    def test_networkd_success_is_scoped(self):
        self.exercise_networkd()

    def test_networkd_failure_restores_files(self):
        self.exercise_networkd(fail=True)

    def test_network_file_waits_for_reconfiguration(self):
        expected = Path('/etc/systemd/network/00-00-utu-wlp3s0b1.network')
        outputs = ['Network File: /run/systemd/network/00-netplan-default.network',
                   'Network File: ' + str(expected)]
        with patch.object(wifi, 'run', side_effect=[subprocess.CompletedProcess([], 0, text) for text in outputs]) as execute, \
             patch.object(wifi.time, 'sleep'):
            wifi.wait_network_file('wlp3s0b1', expected)
        self.assertEqual(execute.call_count, 2)
        self.assertIn('--full', execute.call_args.args)

    def test_network_file_error_reports_actual_owner(self):
        with patch.object(wifi, 'run', return_value=subprocess.CompletedProcess([], 0, 'Network File: /run/systemd/network/00-other.network')):
            with self.assertRaisesRegex(RuntimeError, 'selected: /run/systemd/network/00-other.network'):
                wifi.wait_network_file('wlan0', Path('/etc/systemd/network/00-00-utu-wlan0.network'), timeout=0)

    def test_generated_file_precedes_common_defaults(self):
        name = '00-00-utu-wlp3s0b1.network'
        for default in ('00-netplan-wifi.network', '00-default.network', '10-netplan-wlan0.network'):
            self.assertLess(name, default)

    def test_network_definition_readable_but_contains_no_secret(self):
        path = Path('/etc/systemd/network/00-00-utu-wlan0.network')
        with patch.object(wifi, 'write_private') as write, patch.object(wifi.os, 'chmod') as chmod:
            wifi.write_network(path, 'wlan0')
            chmod.assert_called_once_with(path, 0o644)
            content = write.call_args.args[1]
            self.assertNotIn('psk=', content)
            self.assertNotIn('password', content)

    def test_already_connected_requires_no_prompt(self):
        with patch.object(wifi, 'active', side_effect=[False, True]), \
             patch.object(wifi, 'run', return_value=subprocess.CompletedProcess([], 0, 'Connected to aa:bb')), \
             patch.object(wifi, 'choose_network') as choose:
            wifi.main('wlp3s0b1')
            choose.assert_not_called()


if __name__ == '__main__':
    unittest.main()
