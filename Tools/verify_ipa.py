"""Validate an IPA's device executable. This does not replace Apple signature verification."""
import argparse
import json
import plistlib
import struct
import zipfile


def verify(source):
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        candidates = [n for n in names if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        if len(candidates) != 1:
            raise ValueError('Expected exactly one Payload/*.app/Info.plist')
        info_path = candidates[0]
        info = plistlib.loads(archive.read(info_path))
        executable = info.get('CFBundleExecutable', '')
        if not executable or '/' in executable or '\\' in executable:
            raise ValueError('Invalid CFBundleExecutable')
        if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
            raise ValueError('Not an iPhone device build')
        binary = archive.read(info_path.rsplit('/', 1)[0] + '/' + executable)
        if len(binary) < 32:
            raise ValueError('Missing compiled Mach-O executable')
        magic, cpu, _, filetype, count, command_bytes, _, _ = struct.unpack_from('<8I', binary)
        if magic != 0xFEEDFACF or cpu != 0x0100000C or filetype != 2:
            raise ValueError('Expected a thin ARM64 Mach-O executable')
        if command_bytes > len(binary) - 32 or count > command_bytes // 8:
            raise ValueError('Truncated Mach-O load commands')
        offset, device = 32, False
        for _ in range(count):
            if offset + 8 > 32 + command_bytes:
                raise ValueError('Truncated load command')
            command, size = struct.unpack_from('<II', binary, offset)
            if size < 8 or offset + size > 32 + command_bytes:
                raise ValueError('Invalid load command length')
            if command == 0x32:
                if size < 24: raise ValueError('Invalid LC_BUILD_VERSION')
                platform = struct.unpack_from('<I', binary, offset + 8)[0]
                if platform != 2: raise ValueError('Mach-O is not built for iOS devices')
                device = True
            offset += size
        if not device: raise ValueError('Missing iOS device LC_BUILD_VERSION')
        return {'bundle_id': info.get('CFBundleIdentifier'), 'version': info.get('CFBundleShortVersionString'),
                'minimum_ios': info.get('MinimumOSVersion'), 'architecture': 'arm64', 'platform': 'iPhoneOS',
                'signature_verified': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa')
    args = parser.parse_args()
    print(json.dumps(verify(args.ipa), indent=2))
