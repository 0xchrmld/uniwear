#!/usr/bin/env python3
"""Restore UniWear branding after generating Flutter platform files.

Run from the app root: python3 tool/apply_branding.py
No extra Python packages are required.
"""
import json
import plistlib
from pathlib import Path
import shutil
import re

root = Path(__file__).resolve().parents[1]
icons = root / 'tool' / 'icons'

# Build a COMPLETE, correctly named iOS AppIcon asset catalog. The Flutter
# default app icon can return after `flutter create`; run this script AFTER
# generating your iOS project and BEFORE rebuilding in the simulator.
# All PNG sources are bundled, so Pillow, Homebrew, and the network are not needed.
icon_slots = [
    ('iphone', '20x20', '2x', 40),
    ('iphone', '20x20', '3x', 60),
    ('iphone', '29x29', '1x', 29),
    ('iphone', '29x29', '2x', 58),
    ('iphone', '29x29', '3x', 87),
    ('iphone', '40x40', '2x', 80),
    ('iphone', '40x40', '3x', 120),
    ('iphone', '60x60', '2x', 120),
    ('iphone', '60x60', '3x', 180),
    ('ipad', '20x20', '1x', 20),
    ('ipad', '20x20', '2x', 40),
    ('ipad', '29x29', '1x', 29),
    ('ipad', '29x29', '2x', 58),
    ('ipad', '40x40', '1x', 40),
    ('ipad', '40x40', '2x', 80),
    ('ipad', '76x76', '1x', 76),
    ('ipad', '76x76', '2x', 152),
    ('ipad', '83.5x83.5', '2x', 167),
    ('ios-marketing', '1024x1024', '1x', 1024),
]

def install_ios_icons():
    ios = root / 'ios'
    if not (ios / 'Runner.xcodeproj').exists():
        print('iOS project missing: first run flutter create --platforms=ios,android .')
        return
    appicon = ios / 'Runner' / 'Assets.xcassets' / 'AppIcon.appiconset'
    appicon.mkdir(parents=True, exist_ok=True)
    images = []
    for idiom, size, scale, px in icon_slots:
        source = icons / f'{px}.png'
        if not source.is_file():
            raise FileNotFoundError(f'Missing UniWear icon: {source}')
        filename = f'Icon-App-{size}@{scale}.png'
        shutil.copyfile(source, appicon / filename)
        images.append({'size': size, 'idiom': idiom, 'filename': filename, 'scale': scale})
    contents = {'images': images, 'info': {'version': 1, 'author': 'xcode'}}
    (appicon / 'Contents.json').write_text(json.dumps(contents, indent=2) + '\n')

    plist = ios / 'Runner' / 'Info.plist'
    if plist.is_file():
        with plist.open('rb') as f:
            props = plistlib.load(f)
        props['CFBundleDisplayName'] = 'UniWear'
        props['CFBundleIconName'] = 'AppIcon'
        props['CADisableMinimumFrameDurationOnPhone'] = True
        with plist.open('wb') as f:
            plistlib.dump(props, f, sort_keys=False)

    project = ios / 'Runner.xcodeproj' / 'project.pbxproj'
    if project.is_file():
        value = project.read_text()
        new_value, n = re.subn(
            r'ASSETCATALOG_COMPILER_APPICON_NAME\s*=\s*[^;]+;',
            'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;', value)
        if n:
            project.write_text(new_value)
        else:
            print('Warning: no explicit app icon build setting found in Xcode project')
    print(f'UniWear iOS launcher icon installed: {len(images)} image slots')
    print('UniWear display name and iPhone ProMotion configuration applied.')

install_ios_icons()

# Android launcher icon, keeping the Flutter-generated adaptive icon if present.
android = root / 'android' / 'app' / 'src' / 'main'
for qualifier, px in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    target = android / 'res' / f'mipmap-{qualifier}' / 'ic_launcher.png'
    if target.parent.exists():
        shutil.copyfile(icons / f'{px}.png', target)
manifest = android / 'AndroidManifest.xml'
if manifest.exists():
    text = manifest.read_text()
    import re
    text = re.sub(r'android:label="[^"]*"', 'android:label="UniWear"', text, count=1)
    manifest.write_text(text)
    print('Updated Android icon + UniWear display name')
print('Branding installation complete.')
