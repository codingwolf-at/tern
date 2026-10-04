#!/bin/bash
# Builds Tern (Release), installs it at a stable path, points Claude Code's hooks at the
# installed helper and launches it. Run it again to upgrade.
#
#   scripts/install-tern.sh [--dest DIR] [--skip-build] [--no-hooks] [--no-launch] [--sign IDENTITY [--team ID] | --ad-hoc]
#
#   --dest DIR        install into DIR/Tern.app (default /Applications)
#   --skip-build      install the existing Release build without rebuilding
#   --no-hooks        leave Claude Code's settings alone
#   --no-launch       don't start Tern afterwards
#   --sign IDENTITY   code-signing identity (default: "Apple Development" when one is in the
#                     keychain). A stable identity keeps the Keychain's "Always Allow" for the
#                     Plane token across upgrades; ad-hoc builds are asked again after each one.
#   --team ID         development team for --sign (default: read from the certificate)
#   --ad-hoc          sign ad hoc even when a certificate is available
#
# Ordinary Xcode builds never touch Claude Code's settings; only this script (or
# scripts/install-claude-hooks.sh) does.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="/Applications"
build=1
hooks=1
launch=1
identity=""
team=""
ad_hoc=0
release_id="so.plane.tern"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest) dest="${2%/}"; shift 2 ;;
        --skip-build) build=0; shift ;;
        --no-hooks) hooks=0; shift ;;
        --no-launch) launch=0; shift ;;
        --sign) identity="$2"; shift 2 ;;
        --team) team="$2"; shift 2 ;;
        --ad-hoc) ad_hoc=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

derived="$root/build/DerivedData"
built="$derived/Build/Products/Release/Tern.app"
installed="$dest/Tern.app"

# 1. Build Release, signed with a stable identity when there is one.
if [[ $ad_hoc -eq 1 ]]; then
    identity=""
elif [[ -z "$identity" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Apple Development: '; then
    identity="Apple Development"
fi
if [[ $build -eq 1 ]]; then
    echo "Signing: ${identity:-ad hoc (the Keychain will ask again for this build)}"
    echo "Building Tern (Release)…"
    signing=()
    if [[ -n "$identity" ]]; then
        if [[ -z "$team" ]]; then
            # The team is the certificate subject's OU, e.g. "Apple Development: name (TEAMID)".
            team="$(security find-certificate -c "$identity" -p 2>/dev/null \
                | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
                | sed -n 's/^ *organizationalUnitName *= *//p' | head -n 1)"
        fi
        [[ -n "$team" ]] || { echo "Couldn't find a team for \"$identity\". Pass --team ID." >&2; exit 1; }
        signing=(CODE_SIGN_IDENTITY="$identity" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$team")
    fi
    xcodebuild -project "$root/Tern.xcodeproj" -scheme Tern -configuration Release \
        -derivedDataPath "$derived" -destination "generic/platform=macOS" ${signing[@]+"${signing[@]}"} build -quiet
fi
[[ -d "$built" ]] || { echo "No Release build at $built." >&2; exit 1; }
bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$built/Contents/Info.plist")"
[[ "$bundle_id" == "$release_id" ]] || { echo "$built is $bundle_id, not $release_id." >&2; exit 1; }
"$built/Contents/Helpers/tern-hook" --version >/dev/null || { echo "The built helper doesn't run." >&2; exit 1; }

# 2. Quit the running copy, wherever it was launched from.
if pgrep -xq Tern; then
    echo "Quitting Tern…"
    osascript -e "tell application id \"$release_id\" to quit" >/dev/null 2>&1 || true
    for _ in {1..50}; do pgrep -xq Tern || break; sleep 0.1; done
    pkill -x Tern 2>/dev/null || true
fi

# 3. Replace the installed app. Copy beside it first so a failed copy leaves the old one.
mkdir -p "$dest"
staging="$dest/.Tern.app.installing"
rm -rf "$staging"
ditto "$built" "$staging"
rm -rf "$installed"
mv "$staging" "$installed"
echo "Installed $installed"

# 4. Make the installed copy the tern:// handler; forget the build copy.
"$lsregister" -f -R "$installed"
"$lsregister" -u "$built" 2>/dev/null || true

# 5. Point Claude Code's hooks at the installed helper (no change if already there).
if [[ $hooks -eq 1 ]]; then
    "$root/scripts/install-claude-hooks.sh" install --app "$installed"
fi

# 6. Launch.
if [[ $launch -eq 1 ]]; then
    open "$installed"
    echo "Launched Tern."
fi
