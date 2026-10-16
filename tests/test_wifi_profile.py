import unittest

import yaml

from wifi_profile import build_profile


class ProfileTests(unittest.TestCase):
    def test_special_characters_are_data(self):
        # Keep the SSID within the real 32-byte limit while exercising YAML syntax.
        ssid = "wifi: '#\nnetwork: {}"
        password = 'test: "#\\pass'
        profile = build_profile('wlx123', ssid, password)
        decoded = yaml.safe_load(yaml.safe_dump(profile))
        interface = decoded['network']['wifis']['wlx123']
        self.assertEqual(interface['renderer'], 'networkd')
        self.assertEqual(interface['access-points'][ssid]['password'], password)
        self.assertFalse(interface['dhcp4-overrides']['use-routes'])
        self.assertFalse(interface['dhcp4-overrides']['use-dns'])

    def test_open_network(self):
        self.assertEqual(build_profile('wlan0', 'open', '')['network']['wifis']['wlan0']['access-points']['open'], {})

    def test_reject_invalid_credentials(self):
        for ssid, password in [('', ''), ('a' * 33, ''), ('شبکه' * 9, ''), ('wifi', 'short'), ('wifi', 'z' * 64)]:
            with self.subTest(ssid=ssid, password=password):
                with self.assertRaises(ValueError):
                    build_profile('wlan0', ssid, password)

    def test_hex_psk(self):
        build_profile('wlan0', 'wifi', 'a' * 64)


if __name__ == '__main__':
    unittest.main()
