#!/usr/bin/env python3
"""Build an isolated macOS App Intent fixture, including Xcode-extracted metadata."""
import argparse
import json
import platform
import plistlib
import subprocess
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir', type=Path, default=repo / '.build/app-intent-fixture')
args = parser.parse_args()
root = args.output_dir.resolve()
app = root / 'OCU Intent Fixture.app'
resources = app / 'Contents/Resources'
macos = app / 'Contents/MacOS'
resources.mkdir(parents=True, exist_ok=True)
macos.mkdir(exist_ok=True)
source = repo / 'apps/OpenComputerUseIntentFixture/main.swift'
info = {'CFBundleIdentifier': 'dev.ocu.IntentFixture', 'CFBundleName': 'OCU Intent Fixture',
        'CFBundleDisplayName': 'OCU Intent Fixture', 'CFBundleExecutable': 'OCUIntentFixture',
        'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
        'LSUIElement': True, 'LSMinimumSystemVersion': '14.0'}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
toolchain = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip()) / 'Toolchains/XcodeDefault.xctoolchain'
protocol_file = toolchain / 'usr/share/swift/SwiftConstantValues/AppIntents.json'
protocols = json.loads(protocol_file.read_text())
(root / 'protocols.json').write_text(json.dumps(protocols.get('constValueProtocols', []) if isinstance(protocols, dict) else protocols))
triple = platform.machine() + '-apple-macos14.0'
obj = root / 'fixture.o'
values = root / 'fixture.swiftconstvalues'
subprocess.run(['xcrun', 'swiftc', '-c', '-parse-as-library', str(source), '-module-name', 'OCUIntentFixture',
                '-target', triple, '-o', str(obj), '-emit-const-values-path', str(values), '-Xfrontend',
                '-const-gather-protocols-file', '-Xfrontend', str(root / 'protocols.json')], check=True)
subprocess.run(['xcrun', 'swiftc', str(obj), '-target', triple, '-o', str(macos / 'OCUIntentFixture')], check=True)
(root / 'sources.txt').write_text(str(source) + '\n')
(root / 'const-values.txt').write_text(str(values) + '\n')
sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
version = subprocess.check_output(['xcodebuild', '-version'], text=True).split('Build version ')[-1].strip()
subprocess.run(['xcrun', 'appintentsmetadataprocessor', '--output', str(resources), '--toolchain-dir', str(toolchain),
                '--module-name', 'OCUIntentFixture', '--sdk-root', sdk, '--xcode-version', version,
                '--platform-family', 'macOS', '--deployment-target', '14.0', '--target-triple', triple,
                '--bundle-identifier', info['CFBundleIdentifier'], '--binary-file', str(macos / 'OCUIntentFixture'),
                '--compile-time-extraction', '--deployment-aware-processing',
                '--source-file-list', str(root / 'sources.txt'), '--swift-const-vals-list', str(root / 'const-values.txt')], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
print(app)
