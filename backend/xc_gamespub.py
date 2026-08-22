#!/usr/bin/env python3
# PUBLISH THE GAMES DIRECTORY — the one command that adds or updates a game WITHOUT a node redeploy.
#
# Games are self-contained HTML, pinned to the relays as content-addressed blobs (cid = sha256 of the
# bytes), and named by a PUBLISHER-SIGNED directory record that also lives on the relays — exactly the
# release model (xc_release.py), applied to games. So shipping a new game, or changing an existing one,
# is: edit the HTML, run this. The node reads the signed record from the relays at request time; nothing
# is baked into its image, so it never needs redeploying for a game change.
#
# This reads backend/games.json (the game METADATA: id/title/author/icon + `file`), computes each game's
# cid from backend/games/<file>, PINS the bytes to every relay, rewrites games.json's cid so the local
# fallback matches, SIGNS the directory with the publisher key, and PUSHES it to every relay's /gamesdir.
#
#   python3 xc_gamespub.py            # pin blobs + sign + push the directory
#   python3 xc_gamespub.py --check    # print what WOULD be published (no signing key needed)
#
# The publisher key is the SAME secret that signs releases: XC_PUBLISHER_KEY or ~/.xchat/publisher.key
# (0600, made by `xc_release.py keygen`). Only publishing needs it; the app/node need only the account.
import json, os, sys, time, base64, hashlib, urllib.request
import importlib.util
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

HERE = os.path.dirname(__file__)
GAMES_FILE = os.path.join(HERE, 'games.json')
GAMES_DIR = os.path.join(HERE, 'games')
KEY_FILE = os.path.expanduser(os.environ.get('XC_PUBLISHER_KEY_FILE', '~/.xchat/publisher.key'))
PUBLISHER_PINNED = 'nano_3nefzmwosgqdo97pt6rzjiiazrgx5sf58eksbsbbhrmca7cg3fxisora1dp8'
PUBLISHER = os.environ.get('XC_PUBLISHER_ACCOUNT', '') or PUBLISHER_PINNED

RELAYS = xc.discover_relays()
mode = sys.argv[1] if len(sys.argv) > 1 else 'publish'


def rd(p, d=''):
    try:
        return open(p).read().strip() or d
    except Exception:
        return d


def publisher_key():
    k = os.environ.get('XC_PUBLISHER_KEY', '') or rd(KEY_FILE)
    return k if len(k) == 64 else ''


def post(path, obj):
    sent = 0
    for r in RELAYS:
        try:
            urllib.request.urlopen(urllib.request.Request(r + path, json.dumps(obj).encode(),
                                   {'Content-Type': 'application/json'}), timeout=15).read()
            sent += 1
        except Exception:
            pass
    return sent


def build_directory():
    # Resolve every game's cid from its bytes, pinning as we go. Returns (published_list, pinned_count).
    meta = json.load(open(GAMES_FILE))
    games, pinned = [], 0
    for g in meta:
        entry = {'id': g['id'], 'title': g.get('title', g['id']),
                 'author': g.get('author', ''), 'icon': g.get('icon', '🎮')}
        f = g.get('file', '')
        if f:
            data = open(os.path.join(GAMES_DIR, f), 'rb').read()
            cid = 'sha256-' + hashlib.sha256(data).hexdigest()
            entry['cid'] = cid
            if mode != '--check':
                pinned += 1 if post('/blob', {'cid': cid, 'b64': base64.b64encode(data).decode()}) else 0
            g['cid'] = cid                                  # keep games.json's fallback cid in step
        else:
            entry['cid'] = g.get('cid', '')
        games.append(entry)
    if mode != '--check':
        json.dump(meta, open(GAMES_FILE, 'w'), ensure_ascii=False, indent=2); open(GAMES_FILE, 'a').write('\n')
    return games, pinned


if mode == '--check':
    games, _ = build_directory()
    print(json.dumps({'publisher': PUBLISHER, 'games': games}, ensure_ascii=False, indent=2))
    sys.exit(0)

key = publisher_key()
if not key:
    print(f'no publisher key (XC_PUBLISHER_KEY or {KEY_FILE}) — the games directory names code the app '
          'runs, so it must be signed by the pinned publisher. Run `xc_release.py keygen` first.')
    sys.exit(1)
signer = xc.derive(key)[0]
if signer != PUBLISHER:
    print(f'this key signs as {signer}, but the pinned publisher is {PUBLISHER} — the node/app would '
          'ignore the record. Set XC_PUBLISHER_ACCOUNT or use the right key.')
    sys.exit(1)

games, pinned = build_directory()
rec = {'publisher': PUBLISHER, 'games': games, 'ts': int(time.time())}
d = dict(l.split(' ', 1) for l in xc._sign_lines(key, xc.gamesdir_canon(rec)))
rec['sig'] = d['sig']; rec['pub'] = d['pub']
pushed = post('/gamesdir', rec)
print(json.dumps({'ok': True, 'publisher': PUBLISHER, 'games': len(games),
                  'pinned_relays': pinned, 'record_relays': pushed, 'ts': rec['ts']}, indent=2))
