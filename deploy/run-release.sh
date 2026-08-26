#!/usr/bin/env bash
# run-release.sh — the key-gated tail of the Punte release (runbook Phases 3, 3b, 5, 6, 7).
#
# Prerequisite (already done by hand for 2.5.12): APK built + pushed to punte, /chat web bundle
# built, landing page stamped. This script does the parts that need the PUBLISHER KEY and fly:
#   3   sign + publish the release record   (backend/xc_release.py publish)
#   3b  publish the games directory          (backend/xc_gamespub.py)
#   5   deploy the node   (./deploy/deploy.sh — also re-stamps page + re-signs banner ->Punte)
#   6   deploy the relay  (./deploy/relay/deploy.sh)
#   7   verify live
#
# Usage:
#   ./deploy/run-release.sh                 # preflight -> confirm -> 3,3b,5,6,7
#   ./deploy/run-release.sh --yes           # skip the confirmation prompt
#   ./deploy/run-release.sh --verify-only   # run only Phase 7 (read-only; safe)
#   ./deploy/run-release.sh --skip-games    # omit Phase 3b
#   CHANGELOG="..." ./deploy/run-release.sh # override the release-record changelog line
#
# The publisher key must be reachable: XC_PUBLISHER_KEY, or ~/.xchat/publisher.key (0600).
set -euo pipefail
cd "$(dirname "$0")/.."

YES=0; VERIFY_ONLY=0; SKIP_GAMES=0
for a in "$@"; do case "$a" in
  --yes) YES=1 ;;
  --verify-only) VERIFY_ONLY=1 ;;
  --skip-games) SKIP_GAMES=1 ;;
  *) echo "run-release: unknown option: $a" >&2; exit 1 ;;
esac; done

NODE_URL="https://xchat-alpha-node.fly.dev"
MIRROR="https://raw.githubusercontent.com/stefanbx/punte/master/apk/xchat-alpha.apk"
APK="apk/xchat-alpha.apk"
say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }
die(){ printf '\033[31mrun-release: %s\033[0m\n' "$*" >&2; exit 1; }

VER=$(sed -n 's/^version: *\([0-9][0-9.]*\).*/\1/p' app/pubspec.yaml)
[ -n "$VER" ] || die "could not read version from app/pubspec.yaml"

# ---------------------------------------------------------------- Phase 7 (also standalone)
verify() {
  say "Phase 7 — verify live (read-only)"
  local ok=1
  echo "- announcement names v$VER + is Punte:"
  python3 deploy/sign-announcement.py "$VER" --check || ok=0
  echo "- landing page <title>:"
  curl -fsS "$NODE_URL/" | grep -o '<title>[^<]*</title>' | head -1 || ok=0
  echo "- APK mirror resolves on punte:"
  curl -fsIL "$MIRROR" | grep -iE '^HTTP|content-length' | tail -2 || ok=0
  echo "- installer one-liner points at punte (count >=1):"
  curl -fsS "$NODE_URL/relay.sh" | grep -c 'stefanbx/punte' || ok=0
  echo "- newest signed release record:"
  python3 backend/xc_release.py check || ok=0
  echo "- games directory (expect 3, author Punte):"
  curl -fsS "$NODE_URL/api/games" | python3 -c '
import sys, json
d = json.load(sys.stdin)
g = d if isinstance(d, list) else d.get("games", [])
for x in g:
    print("  " + str(x.get("title")) + " — " + str(x.get("author")))
' || ok=0
  [ "$ok" = 1 ] && say "verify: all checks returned" || say "verify: some checks failed — review above"
}

if [ "$VERIFY_ONLY" = 1 ]; then verify; exit 0; fi

# ---------------------------------------------------------------- preflight
say "Preflight (v$VER)"
[ -f "$APK" ] || die "missing $APK — build the APK first (runbook Phase 1)"
if [ -z "${XC_PUBLISHER_KEY:-}" ] && [ ! -f "$HOME/.xchat/publisher.key" ]; then
  die "no publisher key (XC_PUBLISHER_KEY or ~/.xchat/publisher.key). Phases 3/3b/5 need it."
fi
command -v fly >/dev/null || die "fly CLI not found on PATH"
fly auth whoami >/dev/null 2>&1 || die "fly not authenticated — run: fly auth login"
# APK version must match pubspec (aapt if available)
AAPT=$(ls "${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"/build-tools/*/aapt 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$AAPT" ]; then
  AV=$("$AAPT" dump badging "$APK" 2>/dev/null | sed -n "s/.*versionName='\([^']*\)'.*/\1/p")
  [ "$AV" = "$VER" ] || die "APK versionName ($AV) != pubspec ($VER) — rebuild the APK"
fi
# /chat must be fresh, or deploy.sh (Phase 5) will refuse it
WEB=app/build/web/main.dart.js
[ -f "$WEB" ] || die "no $WEB — build /chat: (cd app && flutter build web --release --base-href /chat/)"
STALE=$(find app/lib app/web app/pubspec.yaml app/pubspec.lock -newer "$WEB" 2>/dev/null || true)
[ -z "$STALE" ] || die "/chat web build is STALE — rebuild it (see runbook Phase 4)"
SHA=$(shasum -a 256 "$APK" | cut -d' ' -f1)
echo "  APK      $APK  ($(python3 -c "import os;print(f'{os.path.getsize(\"$APK\")/1e6:.1f} MB')"))"
echo "  sha256   $SHA"
echo "  publish  release record + games -> relays; deploy node + relay -> fly"
echo "  targets  $NODE_URL  +  xchat-relay-1"

if [ "$YES" != 1 ]; then
  printf '\nThis SIGNS + DEPLOYS to production. Type "ship" to proceed: '
  read -r reply
  [ "$reply" = "ship" ] || die "aborted (got '$reply')"
fi

# ---------------------------------------------------------------- Phase 3 — release record
say "Phase 3 — sign + publish the release record"
echo "$PWD/$APK"                              > /tmp/xc_rel_apk.txt
echo "$VER"                                   > /tmp/xc_rel_version.txt
echo "${CHANGELOG:-Rebrand to Punte (new name + icon); Send > Scan camera fix}" > /tmp/xc_rel_changelog.txt
python3 backend/xc_release.py publish
python3 backend/xc_release.py check

# ---------------------------------------------------------------- Phase 3b — games
if [ "$SKIP_GAMES" != 1 ]; then
  say "Phase 3b — publish the games directory"
  ( cd backend && python3 xc_gamespub.py )
else
  echo "(skipping Phase 3b — games, per --skip-games)"
fi

# ---------------------------------------------------------------- Phase 5 — node
say "Phase 5 — deploy the node (re-stamps page + re-signs banner ->Punte)"
./deploy/deploy.sh

# ---------------------------------------------------------------- Phase 6 — relay
say "Phase 6 — deploy the relay"
./deploy/relay/deploy.sh

# ---------------------------------------------------------------- Phase 7 — verify
verify
say "Release v$VER shipped. (Delete stefanbx/xchat-alpha only after the 10-day window — runbook Phase 8.)"
