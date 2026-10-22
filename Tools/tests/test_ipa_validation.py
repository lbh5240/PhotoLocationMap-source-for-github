"""Synthetic in-memory Mach-O fixtures test rejection rules; no distributable IPA is produced."""
import io
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_ipa import verify


def fixture(platform=2, cpu=0x0100000C, binary=None, supported='iPhoneOS'):
    if binary is None:
        binary = struct.pack('<8I', 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0)
        binary += struct.pack('<6I', 0x32, 24, platform, 27 << 16, 27 << 16, 0)
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w') as archive:
        info = {'CFBundleExecutable': 'ZORA', 'CFBundleIdentifier': 'fixture.only',
                'CFBundleSupportedPlatforms': [supported], 'MinimumOSVersion': '27.0'}
        archive.writestr('Payload/ZORA.app/Info.plist', plistlib.dumps(info))
        archive.writestr('Payload/ZORA.app/ZORA', binary)
    data.seek(0)
    return data


class IPATests(unittest.TestCase):
    def test_device_header_is_recognized_without_claiming_signature(self):
        result = verify(fixture())
        self.assertEqual(result['platform'], 'iPhoneOS')
        self.assertFalse(result['signature_verified'])

    def test_rejects_source_disguised_as_binary(self):
        with self.assertRaises(ValueError): verify(fixture(binary=b'import SwiftUI\n' * 10))

    def test_rejects_arm64_simulator(self):
        with self.assertRaises(ValueError): verify(fixture(platform=7))

    def test_rejects_x86_simulator_and_wrong_plist(self):
        with self.assertRaises(ValueError): verify(fixture(cpu=0x01000007))
        with self.assertRaises(ValueError): verify(fixture(supported='iPhoneSimulator'))

    def test_rejects_truncated_load_commands(self):
        with self.assertRaises(ValueError): verify(fixture(binary=struct.pack('<8I',0xFEEDFACF,0x0100000C,0,2,1,999,0,0)))

    @unittest.skipIf(sys.platform == 'darwin', 'Windows/Linux environment gate test')
    def test_non_mac_fails_before_producing_any_artifact(self):
        result = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1]/'build_ipa.py'), '--unsigned'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('No IPA was created', result.stderr)


if __name__ == '__main__': unittest.main()
