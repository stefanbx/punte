# Punte release + backend redeploy checklist

The one-time migration that makes **Punte / stefanbx/punte** canonical, then the
repeatable release flow. Derived from the actual scripts (`deploy/deploy.sh`,
`deploy/relay/deploy.sh`, `deploy/stamp-release.sh`, `backend/xc_release.py`,
`deploy/sign-announcement.py`).

## What this changes vs. doesn't
- **Changes:** the *served* landing page, `/chat`, and `/relay.sh` (now Punte-branded,
  URLs point at `github.com/stefanbx/punte`); the signed in-app banner (ӾChat → Punte,
  regenerated automatically at deploy time); the signed release record's APK mirror URL.
- **Unchanged (infra, on purpose):** the Fly **app names** `xchat-alpha-node` and
  `xchat-relay-1`, all `*.fly.dev` hosts, and every wire/storage identity. Deleting the
  GitHub repo later does **not** touch Fly.

## Version (decided)
This release is **2.5.12** — the Punte reveal (new name + bridge icon) plus the Send → Scan
camera fix. Already set: `app/pubspec.yaml` (`2.5.12+22512`), `app/lib/main.dart`
(`kAppVersion = '2.5.12'`), and `deploy/announce-text.txt` (names 2.5.12).

## Prerequisites
- [ ] `fly auth whoami` → butucea.stefan@gmail.com ✅ (already authed)
- [ ] Publisher key present: `~/.xchat/publisher.key` (0600) — needed for the signed release
      **and** the announcement. `xc_release.py check`/`fetch` don't need it; `publish` does.
- [ ] Android build env (SDK/JDK are Homebrew, not on PATH):
      ```bash
      source deploy/reproduce/buildenv.sh   # sets JAVA_HOME (openjdk@17), ANDROID_SDK_ROOT, PATH
      export FLUTTER_HOME="$HOME/flutter"    # buildenv.sh expects this
      ```

---

## Phase 1 — Build the Punte APK (name + bridge icon)
- [ ] Confirm icon/name are in (already committed): `PunteApp`, `android:label="Punte"`,
      bridge mipmaps.
- [ ] Build the release APK:
      ```bash
      source deploy/reproduce/buildenv.sh; export FLUTTER_HOME="$HOME/flutter"
      cd app && flutter build apk --release --target-platform android-arm64 && cd ..
      cp app/build/app/outputs/flutter-apk/app-release.apk apk/xchat-alpha.apk
      ```
      (The artifact filename `xchat-alpha.apk` is kept — it's infra; the URLs already expect it.)
- [ ] Sanity: `shasum -a 256 apk/xchat-alpha.apk` and note it matches what the page will show.

## Phase 2 — Push the new APK to punte (so the repointed mirror serves it)
The release record's mirror is now `raw.githubusercontent.com/stefanbx/punte/master/apk/xchat-alpha.apk`.
That file must be the NEW build before you publish the record.
- [ ] ```bash
      git add apk/xchat-alpha.apk && git commit -m "release <ver>: Punte APK"
      git push punte master
      ```

## Phase 3 — Sign + publish the release record (root of trust for self-update)
- [ ] ```bash
      echo "$PWD/apk/xchat-alpha.apk" > /tmp/xc_rel_apk.txt
      echo "2.5.12"                    > /tmp/xc_rel_version.txt   # match your chosen version
      echo "Rebrand to Punte (new name + icon); QR-scanner fix" > /tmp/xc_rel_changelog.txt
      python3 backend/xc_release.py publish
      ```
      This content-addresses the APK, pins it to the relays/IPFS, and publishes the
      publisher-**signed** release record. `rec['url']` defaults to the punte mirror
      (override with `XC_RELEASE_URL` if needed).
- [ ] Verify: `python3 backend/xc_release.py check` → newest signed release = your version.

## Phase 3b — Publish the games directory (same key; relay-delivered, NOT in the APK)
Games are self-contained HTML pinned to the relays as content-addressed blobs, named by a
publisher-signed directory (`xc_gamespub.py`) — deliberately **not** baked into the APK, so they
update without an app release. Refresh them with the release so they're current + authored "Punte".
- [ ] Preview (no key): `cd backend && python3 xc_gamespub.py --check && cd ..`
- [ ] Publish:
      ```bash
      cd backend && python3 xc_gamespub.py && cd ..   # pins blobs + signs + pushes /gamesdir to every relay
      ```
- [ ] Verify live: `curl -s https://xchat-alpha-node.fly.dev/api/games | python3 -m json.tool | grep -E '"title"|"author"'`
      → 3 games (Ӿnake / Ӿ Stack / Ӿ Catch), author "Punte".

## Phase 4 — Build the web app (/chat)
`deploy.sh` refuses to ship a stale `/chat`.
- [ ] ```bash
      cd app && flutter build web --release --base-href /chat/ && cd ..
      ```

## Phase 5 — Deploy the node (`xchat-alpha-node`)
- [ ] ```bash
      ./deploy/deploy.sh
      ```
      This runs `stamp-release.sh` (rewrites `download.html`'s APK version/size/SHA from the
      real artifact **and** re-signs `announcement.json` from `announce-text.txt` → the banner
      flips ӾChat→Punte automatically), stages backend/html/json + relay + `/chat`, and
      `fly deploy`s the node. Backend-only change with an intentionally stale web build:
      `./deploy/deploy.sh --allow-stale-web`.

## Phase 6 — Deploy the relay (`xchat-relay-1`)
- [ ] ```bash
      ./deploy/relay/deploy.sh
      ```

## Phase 7 — Verify live
- [ ] Banner is current + Punte-named: `python3 deploy/sign-announcement.py 2.5.12 --check`
- [ ] Landing page rebranded: `curl -s https://xchat-alpha-node.fly.dev/ | grep -o '<title>[^<]*'`
      → `Punte`
- [ ] APK mirror resolves on punte: `curl -sIL https://github.com/stefanbx/punte/raw/master/apk/xchat-alpha.apk | grep -E 'HTTP|location'`
- [ ] Installer one-liner points at punte:
      `curl -s https://xchat-alpha-node.fly.dev/relay.sh | grep -c 'stefanbx/punte'` → ≥1
- [ ] In the app: launch → the update sheet / banner shows **Punte 2.5.12**, and a fresh
      install shows the bridge icon + "Punte".

## Phase 8 — After the 10-day retention: delete xchat-alpha (your call, destructive)
Existing installs are safe — self-update is relay-based + content-addressed; GitHub is only a
fast mirror with relay fallback. Do this only after Phase 7 is green and the window has passed.
- [ ] `gh repo delete stefanbx/xchat-alpha` (irreversible; GitHub will prompt to confirm)
- [ ] Reminder: this deletes only the **GitHub repo**. The Fly apps `xchat-alpha-node` /
      `xchat-relay-1` are separate infra and keep running. (Renaming those Fly apps is a
      distinct, later task and is **not** required by the rebrand.)

---
### Notes
- `announce-text.txt` and `sign-announcement.py` are already Punte; the signed
  `announcement.json` only flips when Phase 5 (or `./deploy/stamp-release.sh`) runs with the
  publisher key. Without a key, the banner is left unchanged with a warning (CI-safe).
- Optional integrity step: after Phase 1, `deploy/reproduce/reproduce.sh` reproduces the APK
  content hash for the "verify the checksum" trust chain.
