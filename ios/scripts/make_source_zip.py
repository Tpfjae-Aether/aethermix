#!/usr/bin/env python3
"""Build the drag-and-drop bundle for the no-Mac IPA route.

`setup_github_build.sh` needs the GitHub CLI, which most people do not have.
The other way in is GitHub's web uploader: drop a folder into a new repository,
run the workflow, download the artifact. For that the upload has to be a
complete, self-consistent repository root, which is easy to get wrong by hand:

  * GitHub only reads workflows from `.github/workflows` at the REPOSITORY
    ROOT, so the standalone copy of the workflow has to be included at the top
    level (and a stray `ios/` prefix makes every path in it resolve to nothing),
  * dotfiles (`.github`, `.gitignore`) are skipped by most copy and zip tools,
  * `dist/`, `build/` and a generated `.xcodeproj` must not travel: they are
    either huge or stale, and a stale project file is worse than none.

This stages exactly what that repository root needs and writes
`ios/dist/AetherMix-ios-source.zip`, then asserts the entries the workflow and
the build script actually read are present.

    python ios/scripts/make_source_zip.py
"""
import io
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
IOS = os.path.dirname(HERE)                      # ios/
OUT = os.path.join(IOS, 'dist', 'AetherMix-ios-source.zip')

# Included verbatim when present. Directories are walked recursively.
INCLUDE_FILES = [
    '.gitignore',
    'project.yml',
    'README.md',
    '.github/workflows/ios-ipa.yml',
]
INCLUDE_DIRS = [
    'AetherMix',
    'tools',
    'scripts',
]
# Only the portable scripts belong in the standalone repo: setup_github_build.sh
# expects the monorepo layout (it reads ../.github) and would misbehave here.
EXCLUDE_NAMES = {
    'setup_github_build.sh', 'make_source_zip.py',
}
EXCLUDE_DIRS = {
    '__pycache__', 'dist', 'build', 'DerivedData', '.git', 'xcuserdata',
}
EXCLUDE_SUFFIX = ('.xcodeproj', '.xcuserstate', '.DS_Store', '.pyc')

# The workflow and build_ipa.sh read these; a bundle without them fails in CI
# after a five minute wait, which is exactly the confusing outcome to prevent.
REQUIRED = [
    '.github/workflows/ios-ipa.yml',
    'project.yml',
    'AetherMix/Info.plist',
    'AetherMix/Sources/AetherMixApp.swift',
    'AetherMix/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png',
    'scripts/build_ipa.sh',
    'scripts/verify_ipa.py',
    'tools/swift_check.py',
]


def wanted(rel):
    base = os.path.basename(rel)
    if base in EXCLUDE_NAMES or base.endswith(EXCLUDE_SUFFIX):
        return False
    return not any(part in EXCLUDE_DIRS for part in rel.split('/'))


def collect():
    out = []
    for f in INCLUDE_FILES:
        p = os.path.join(IOS, f)
        if os.path.isfile(p):
            out.append(f)
        else:
            print('warn  missing %s' % f)
    for d in INCLUDE_DIRS:
        root = os.path.join(IOS, d)
        for base, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if x not in EXCLUDE_DIRS]
            for name in files:
                rel = os.path.relpath(os.path.join(base, name), IOS).replace('\\', '/')
                if wanted(rel):
                    out.append(rel)
    return sorted(set(out))


def main():
    entries = collect()
    missing = [r for r in REQUIRED if r not in entries]
    if missing:
        for m in missing:
            print('FAIL  the bundle is missing %s' % m)
        return 1

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    # fixed timestamp so the same tree produces the same bytes; shell scripts
    # keep the executable bit because build_ipa.sh is run, not sourced
    with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as z:
        for rel in entries:
            info = zipfile.ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o755 if rel.endswith('.sh') else 0o644
            info.external_attr = (mode | 0o100000) << 16
            with io.open(os.path.join(IOS, rel), 'rb') as fh:
                z.writestr(info, fh.read())

    with zipfile.ZipFile(OUT) as z:
        names = z.namelist()
        bad = z.testzip()
    if bad:
        print('FAIL  corrupt entry: %s' % bad)
        return 1
    # duplicate names (the chmod pass re-adds entries) would silently shadow the
    # real file inside the archive
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        print('FAIL  duplicate entries: %s' % ', '.join(dupes))
        return 1
    if any(n.startswith('ios/') for n in names):
        print('FAIL  entries are prefixed with ios/ - the workflow paths would miss')
        return 1

    print('%d entries -> %s  (%.0f KiB)' % (
        len(names), os.path.relpath(OUT, IOS), os.path.getsize(OUT) / 1024.0))
    for n in names:
        print('  ' + n)
    print('PASS: upload the CONTENTS of this zip as the repository root')
    return 0


if __name__ == '__main__':
    sys.exit(main())
