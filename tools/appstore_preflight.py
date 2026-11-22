#!/usr/bin/env python3
"""Static App Store readiness checks that run on Linux. Exit 1 on failure."""
import plistlib, struct, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
errors = []

def load(rel):
    try:
        return plistlib.loads((root / rel).read_bytes())
    except Exception as e:
        errors.append(f'{rel}: {e}')
        return {}

info = load('App/Info.plist')
for k in ('CFBundleShortVersionString', 'CFBundleVersion', 'ITSAppUsesNonExemptEncryption',
          'LSApplicationCategoryType', 'UIRequiredDeviceCapabilities', 'NSHumanReadableCopyright'):
    if k not in info:
        errors.append(f'Info.plist missing {k}')
if info.get('ITSAppUsesNonExemptEncryption') is not False:
    errors.append('ITSAppUsesNonExemptEncryption must be false')

priv = load('App/PrivacyInfo.xcprivacy')
if priv.get('NSPrivacyTracking') is not False:
    errors.append('NSPrivacyTracking must be false')
if priv.get('NSPrivacyCollectedDataTypes'):
    errors.append('NSPrivacyCollectedDataTypes must be empty (label says Data Not Collected)')
for a in priv.get('NSPrivacyAccessedAPITypes', []):
    if not a.get('NSPrivacyAccessedAPITypeReasons'):
        errors.append(f"privacy manifest: no reason for {a.get('NSPrivacyAccessedAPIType')}")

ent = load('App/SKYFORGE.entitlements')
if ent.get('com.apple.security.app-sandbox') is not True:
    errors.append('macOS App Sandbox must be enabled')

icons = root / 'App/Assets.xcassets/AppIcon.appiconset'
png = icons / 'icon-1024.png'
if not png.exists():
    errors.append('missing icon-1024.png')
else:
    d = png.read_bytes()
    w, h = struct.unpack('>II', d[16:24])
    if (w, h) != (1024, 1024):
        errors.append(f'icon-1024.png is {w}x{h}')
    if d[25] in (4, 6):  # colour type with alpha
        errors.append('icon-1024.png must not have an alpha channel')

for rel in ('docs/appstore/METADATA.md', 'docs/appstore/PRIVACY_POLICY.md', 'docs/appstore/REVIEW_NOTES.md',
            'tools/appstore/ExportOptions-ios.plist', 'tools/appstore/ExportOptions-macos.plist',
            'THIRD_PARTY_NOTICES.md', 'NOTICE', 'LICENSE'):
    if not (root / rel).exists():
        errors.append(f'missing {rel}')

if not (root / 'Packages/SkyforgeKit/Sources/SFUI/AcknowledgementsView.swift').exists():
    errors.append('in-app acknowledgements view missing (ODbL/CC BY attribution)')

for e in errors:
    print('FAIL', e)
print('appstore_preflight:', 'FAILED' if errors else 'ok')
sys.exit(1 if errors else 0)
