#!/usr/bin/env bash
# Build the unsigned IPA on a GitHub macOS runner — the no-Mac route.
#
#   ./scripts/setup_github_build.sh [repo-name]
#
# It stages ONLY the iOS project and the workflow into a temporary git repo, so
# your music library, caches and the desktop sources are never uploaded. Then it
# creates a private repository, starts the workflow, waits, and drops the .ipa in
# ios/dist/.
#
# Requires the GitHub CLI (`gh`) and `gh auth login` once. Run this yourself: it
# creates a repository in your account.
set -euo pipefail

REPO_NAME="${1:-aethermix-pocket}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # ios/
ROOT="$(cd "$HERE/.." && pwd)"                            # project root

command -v gh >/dev/null 2>&1 || { echo "error: install the GitHub CLI first (https://cli.github.com)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || gh auth login

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/ios" "$STAGE/.github/workflows"
# the sources, manifest, plist, assets and scripts - never dist/build
( cd "$HERE" && tar --exclude=dist --exclude=build --exclude='*.xcodeproj' -cf - . ) | ( cd "$STAGE/ios" && tar -xf - )
cp "$ROOT/.github/workflows/ios-ipa.yml" "$STAGE/.github/workflows/ios-ipa.yml"

cd "$STAGE"
git init -q
git add ios .github
git -c user.name="AetherMix" -c user.email="aethermix@localhost" commit -qm "AetherMix Pocket: iOS client + IPA workflow"
git branch -M main

echo "== creating private repo $REPO_NAME =="
gh repo create "$REPO_NAME" --private --source=. --remote=origin --push

echo "== starting the macOS build =="
gh workflow run ios-ipa.yml
sleep 6
RUN_ID="$(gh run list --workflow=ios-ipa.yml --limit=1 --json databaseId --jq '.[0].databaseId')"
gh run watch "$RUN_ID" --exit-status

mkdir -p "$ROOT/ios/dist"
gh run download "$RUN_ID" --name AetherMix-unsigned-ipa --dir "$ROOT/ios/dist"
IPA="$(find "$ROOT/ios/dist" -name '*.ipa' | head -1)"
echo "== ipa: $IPA =="
python3 "$HERE/scripts/verify_ipa.py" "$IPA" || true
