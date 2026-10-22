"""Compile with Xcode before packaging. Never constructs an IPA from source files."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from verify_ipa import verify

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, cwd=ROOT, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--unsigned', action='store_true', help='Device IPA requiring subsequent signing')
    mode.add_argument('--signed', action='store_true', help='Use signing assets already available on the Mac')
    parser.add_argument('--team-id')
    parser.add_argument('--bundle-id', default='app.zora.camera')
    parser.add_argument('--export-options', type=Path, help='ExportOptions.plist exported by your Xcode')
    parser.add_argument('--output', type=Path, default=ROOT/'Builds')
    args = parser.parse_args()
    if sys.platform != 'darwin' or not shutil.which('xcodebuild'):
        parser.exit(2, 'Cannot build IPA: macOS with Xcode and iOS 27 SDK is required. No IPA was created.\n')
    if args.signed and (not args.team_id or not args.export_options):
        parser.error('--signed requires --team-id and --export-options; signing assets stay on the Mac')
    if args.export_options:
        with args.export_options.open('rb') as file: options = plistlib.load(file)
        if options.get('destination', 'export') != 'export':
            parser.error('ExportOptions.plist must export locally, not upload to a service')
    sdk = run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], capture_output=True, text=True).stdout.strip()
    if int(sdk.split('.')[0]) < 27:
        parser.exit(2, f'Installed iOS SDK is {sdk}; select Xcode 27. No IPA was created.\n')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    build = Path(tempfile.mkdtemp(prefix='zora-', dir=args.output))
    archive = build/'ZORACamera.xcarchive'
    run([sys.executable, ROOT/'Tools/generate_project.py'])
    command = ['xcodebuild', '-project', ROOT/'ZORACamera.xcodeproj', '-scheme', 'ZORACamera',
               '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
               '-archivePath', archive, '-derivedDataPath', build/'DerivedData',
               'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=NO', f'PRODUCT_BUNDLE_IDENTIFIER={args.bundle_id}', 'archive']
    if args.unsigned:
        command += ['CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=']
    else: command += [f'DEVELOPMENT_TEAM={args.team_id}']
    with (build/'archive.log').open('w', encoding='utf-8') as log:
        # Stream logs to both CI and disk; preserve errors for repair.
        process = subprocess.Popen([str(x) for x in command], cwd=ROOT, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            print(line, end=''); log.write(line)
        if process.wait() != 0: raise RuntimeError(f'Xcode archive failed. See {build / "archive.log"}')
    app = archive/'Products/Applications/ZORACamera.app'
    if not app.is_dir(): raise RuntimeError('Xcode did not produce the app bundle')
    if args.signed:
        run(['codesign', '--verify', '--deep', '--strict', app])
        run(['xcodebuild', '-exportArchive', '-archivePath', archive, '-exportPath', build/'Export',
             '-exportOptionsPlist', args.export_options.resolve()])
        exports = list((build/'Export').glob('*.ipa'))
        if len(exports) != 1: raise RuntimeError('Xcode export did not produce exactly one IPA')
        ipa = exports[0]
    else:
        stage = build/'Stage'; (stage/'Payload').mkdir(parents=True)
        run(['ditto', app, stage/'Payload/ZORACamera.app'])
        ipa = build/'ZORACamera-unsigned.ipa'
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', stage/'Payload', ipa])
    result = verify(ipa)
    if args.signed:
        with tempfile.TemporaryDirectory(prefix='zora-verify-') as temporary:
            run(['ditto', '-x', '-k', ipa, temporary])
            exported_app = next((Path(temporary)/'Payload').glob('*.app'))
            if not (exported_app/'embedded.mobileprovision').is_file(): raise RuntimeError('Missing provisioning profile')
            run(['codesign', '--verify', '--deep', '--strict', exported_app])
        result['signature_verified'] = True
    result.update(built_at=datetime.now(timezone.utc).isoformat(), sdk=sdk, unsigned=args.unsigned,
                  ipa=ipa.name, sha256=hashlib.sha256(ipa.read_bytes()).hexdigest())
    (ipa.parent/'IPA_BUILD_REPORT.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(f'IPA created and device binary validated: {ipa}')
    if args.unsigned: print('UNSIGNED: requires signing before installation. Hotspot entitlement also needs an appropriate profile.')


if __name__ == '__main__':
    try: main()
    except (subprocess.CalledProcessError, RuntimeError, ValueError) as error:
        print(str(error), file=sys.stderr); sys.exit(1)
