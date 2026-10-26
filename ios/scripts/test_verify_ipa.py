#!/usr/bin/env python3
"""Prove that verify_ipa.py can tell a good IPA from a broken one.

The verifier is the gate in front of Sideloadly, so it has to fail on the
archive shapes that actually stop an install, not just print PASS. This builds
tiny synthetic archives in a temp dir (no Xcode) and asserts the verdict.

    python ios/scripts/test_verify_ipa.py
"""
import os
import plistlib
import struct
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
VERIFY = os.path.join(HERE, 'verify_ipa.py')

GOOD_PLIST = {
    'CFBundleIdentifier': 'app.aethermix.pocket',
    'CFBundleExecutable': 'AetherMix',
    'CFBundleName': 'AetherMix',
    'CFBundleDisplayName': 'AetherMix',
    'CFBundlePackageType': 'APPL',
    'CFBundleVersion': '1',
    'CFBundleShortVersionString': '1.0',
    'MinimumOSVersion': '16.0',
    'UIBackgroundModes': ['audio'],
    'NSLocalNetworkUsageDescription': 'streams your library',
    'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
    'UIFileSharingEnabled': True,
    'UILaunchScreen': {},
}


def macho(cputype=0x0100000C, magic=b'\xcf\xfa\xed\xfe'):
    # thin 64-bit header: magic, cputype, cpusubtype, filetype
    return magic + struct.pack('<I', cputype) + struct.pack('<I', 0) + struct.pack('<I', 2) + b'\x00' * 32


def build(path, exe=macho(), plist=None, app='AetherMix.app', extra=None):
    pl = dict(GOOD_PLIST)
    if plist:
        pl.update(plist)
        for k, v in list(pl.items()):
            if v is None:
                del pl[k]
    with zipfile.ZipFile(path, 'w') as z:
        root = 'Payload/%s/' % app
        z.writestr(root + 'Info.plist', plistlib.dumps(pl))
        z.writestr(root + 'AetherMix', exe)
        z.writestr(root + 'Assets.car', b'car')
        for name, data in (extra or {}).items():
            z.writestr(root + name, data)


def run(path):
    p = subprocess.run([sys.executable, VERIFY, path], capture_output=True, text=True)
    return p.returncode, (p.stdout or '') + (p.stderr or '')


def main():
    cases = []
    with tempfile.TemporaryDirectory() as d:
        def case(name, want, **kw):
            p = os.path.join(d, name + '.ipa')
            build(p, **kw)
            code, out = run(p)
            cases.append((name, want, code == 0, out))

        case('good', True)
        case('x86-simulator-slice', False, exe=macho(cputype=0x01000007))
        case('not-a-macho', False, exe=b'#!/bin/sh\necho hi\n')
        case('no-local-network-key', False, plist={'NSLocalNetworkUsageDescription': None})
        case('no-background-audio', False, plist={'UIBackgroundModes': []})
        case('no-ats-for-lan', False, plist={'NSAppTransportSecurity': None})
        case('wrong-package-type', False, plist={'CFBundlePackageType': 'XPLC'})
        case('fat-arm64', True,
             exe=b'\xca\xfe\xba\xbe' + struct.pack('>I', 1) + struct.pack('>I', 0x0100000C)
                 + struct.pack('>I', 0) + struct.pack('>I', 0) + struct.pack('>I', 0)
                 + struct.pack('>I', 0) + b'\x00' * 64)

        # an archive with the app one level too deep
        deep = os.path.join(d, 'wrong-layout.ipa')
        with zipfile.ZipFile(deep, 'w') as z:
            z.writestr('AetherMix.app/Info.plist', plistlib.dumps(GOOD_PLIST))
        code, out = run(deep)
        cases.append(('wrong-layout', False, code == 0, out))

        # not a zip at all
        junk = os.path.join(d, 'junk.ipa')
        open(junk, 'wb').write(b'not a zip')
        code, out = run(junk)
        cases.append(('not-a-zip', False, code == 0, out))

    bad = 0
    for name, want, got, out in cases:
        ok = want == got
        if not ok:
            bad += 1
        tail = [ln for ln in out.splitlines() if ln.startswith(('FAIL', 'PASS'))]
        print('%s  %-24s expected %s, got %s  %s' % (
            'ok  ' if ok else 'FAIL', name, 'PASS' if want else 'reject',
            'PASS' if got else 'reject', tail[-1][:70] if tail else ''))
        if not ok:
            print(out)
    print('\n%d/%d verifier cases behave as intended' % (len(cases) - bad, len(cases)))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
