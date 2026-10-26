#!/usr/bin/env python3
"""Verify that an .ipa is the kind Sideloadly can sign and an iPhone can run.

This is deliberately independent of Xcode, so it runs on the Windows PC that
will do the sideloading. It checks the failures that actually stop an install:

  * a proper Payload/<App>.app at the archive root,
  * a Mach-O executable for arm64 (not a simulator x86_64 slice),
  * the Info.plist keys Sideloadly and iOS validate,
  * the declarations the app needs (background audio, local network, files),
  * an app icon that iOS can render.

Usage: python verify_ipa.py path/to/AetherMix-unsigned.ipa
Exit code 0 means the archive passes every check; warnings do not fail it.
"""
import plistlib
import struct
import sys
import zipfile

MAGIC_LE64 = b"\xcf\xfa\xed\xfe"
MAGIC_LE32 = b"\xce\xfa\xed\xfe"
FAT_MAGIC = b"\xca\xfe\xba\xbe"
CPU_ARM64 = 0x0100000C
CPU_ARM64E = 0x0100000C  # same cputype, subtype distinguishes e


def fail(msg):
    print("FAIL  " + msg)
    return False


def warn(msg):
    print("warn  " + msg)


def check_macho(data, label):
    if len(data) < 8:
        return fail("%s: file is too small to be Mach-O" % label)
    if data[:4] == FAT_MAGIC:
        # big-endian fat header: nfat_arch then arch entries
        n = struct.unpack(">I", data[4:8])[0]
        found = False
        for i in range(n):
            off = 8 + i * 20
            if len(data) < off + 20:
                break
            cputype = struct.unpack(">I", data[off:off + 4])[0]
            if cputype == CPU_ARM64:
                found = True
        if not found:
            return fail("%s: fat binary has no arm64 slice" % label)
        print("ok    %s: fat Mach-O with arm64" % label)
        return True
    if data[:4] not in (MAGIC_LE64, MAGIC_LE32):
        return fail("%s: not a Mach-O executable (magic %s)" % (label, data[:4].hex()))
    if data[:4] == MAGIC_LE32:
        warn("%s: 32-bit Mach-O; a modern iPhone needs 64-bit" % label)
    cputype = struct.unpack("<I", data[4:8])[0]
    if cputype != CPU_ARM64:
        return fail("%s: cputype 0x%x is not arm64 (simulator or Mac slice)" % (label, cputype))
    print("ok    %s: arm64 Mach-O" % label)
    return True


def main(path):
    ok = True
    try:
        z = zipfile.ZipFile(path)
    except Exception as e:
        return fail("not a zip/ipa: %s" % e)

    names = z.namelist()
    apps = sorted({n.split("/")[1] for n in names
                   if n.startswith("Payload/") and len(n.split("/")) > 2})
    apps = [a for a in apps if a.endswith(".app")]
    if len(apps) != 1:
        return fail("expected exactly one Payload/<App>.app, found %r" % apps)
    app = apps[0]
    root = "Payload/%s/" % app
    print("ok    bundle: %s" % app)

    plist_name = root + "Info.plist"
    if plist_name not in names:
        return fail("Info.plist missing at %s" % plist_name)
    raw = z.read(plist_name)
    try:
        pl = plistlib.loads(raw)
    except Exception as e:
        return fail("Info.plist is not a valid property list: %s" % e)

    for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleVersion",
                "CFBundleShortVersionString", "CFBundlePackageType"):
        if not pl.get(key):
            ok = fail("Info.plist missing %s" % key)
    if pl.get("CFBundlePackageType") not in (None, "APPL"):
        ok = fail("CFBundlePackageType is %r, expected APPL" % pl.get("CFBundlePackageType"))
    print("ok    id: %s  version: %s (%s)" % (
        pl.get("CFBundleIdentifier"), pl.get("CFBundleShortVersionString"),
        pl.get("CFBundleVersion")))

    exe = pl.get("CFBundleExecutable")
    exe_path = root + str(exe)
    if exe_path not in names:
        ok = fail("CFBundleExecutable %r is not in the bundle" % exe)
    else:
        ok = check_macho(z.read(exe_path), exe) and ok

    if not pl.get("MinimumOSVersion"):
        warn("MinimumOSVersion missing (Xcode normally injects it; Sideloadly may add it)")
    else:
        print("ok    minimum iOS: %s" % pl["MinimumOSVersion"])

    modes = pl.get("UIBackgroundModes") or []
    if "audio" in modes:
        print("ok    background audio declared")
    else:
        # the whole point of this client is the phone playing with the screen
        # off; a bundle without the mode is the wrong build
        ok = fail("UIBackgroundModes does not contain audio: playback stops when locked") and ok

    if pl.get("NSLocalNetworkUsageDescription"):
        print("ok    local network usage description present")
    else:
        ok = fail("NSLocalNetworkUsageDescription missing: iOS will block the bridge")
    if pl.get("NSAppTransportSecurity", {}).get("NSAllowsLocalNetworking") or \
       pl.get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads"):
        print("ok    ATS allows the LAN bridge")
    else:
        # without this the phone cannot reach the bridge at all, so the app
        # installs and then does nothing usable
        ok = fail("ATS does not allow local http; the bridge at 192.168.x.x will fail") and ok
    if pl.get("UIFileSharingEnabled"):
        print("ok    Documents visible in Files")
    else:
        warn("UIFileSharingEnabled missing: imports only work through the picker")

    if "UILaunchScreen" not in pl and "UILaunchStoryboardName" not in pl:
        warn("no launch screen; the app may letterbox on newer iPhones")

    icons = [n for n in names if n.startswith(root) and "AppIcon" in n.split("/")[-1]]
    if icons or (root + "Assets.car") in names:
        print("ok    app icon assets present")
    else:
        warn("no app icon in the bundle; the home screen will show a blank tile")

    print()
    print("PASS: %s is ready for Sideloadly" % path if ok else "FAILED: fix the lines above")
    return ok


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: python verify_ipa.py path/to/file.ipa")
        sys.exit(2)
    sys.exit(0 if main(sys.argv[1]) else 1)
