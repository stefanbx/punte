#!/usr/bin/env python3
# GAMES: signed high-score leaderboards + a content-addressed game directory. Scores are SIGNED by the
# player's account (canon: sig_canon('score', account, game, score, ts)), so a rank can't be forged. The
# node fans a signed score out to every relay's /score, aggregates /leaderboard reads (max per account,
# since relays converge), and reads the local directory from backend/games.json. Same shape as xc_engage:
# a post() write fan-out + a ThreadPoolExecutor read aggregation. Imported and called IN-PROCESS by the node.
import json, os, urllib.request, urllib.parse
import importlib.util
from concurrent.futures import ThreadPoolExecutor
spec = importlib.util.spec_from_file_location("xc_common", os.path.join(os.path.dirname(__file__), "xc_common.py"))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

GAMES_FILE = os.path.join(os.path.dirname(__file__), 'games.json')
# The publisher the app pins for signed content (releases AND the games directory) — same account, so a
# stolen relay can't inject a hostile game. Overridable for a self-run network.
PUBLISHER = os.environ.get('XC_PUBLISHER_ACCOUNT',
                           'nano_3nefzmwosgqdo97pt6rzjiiazrgx5sf58eksbsbbhrmca7cg3fxisora1dp8')


def discover_relays():
    return xc.discover_relays()                      # cached (onchain 120s + parallel BFS); cheap per call

def post(path, obj, relays=None):
    for r in (relays or discover_relays()):
        try:
            urllib.request.urlopen(urllib.request.Request(r + path, json.dumps(obj).encode(),
                                   {'Content-Type': 'application/json'}), timeout=4).read()
        except Exception:
            pass

# ---- write (fire-and-forget the app-SIGNED score to every relay) ------------------------------------
def submit(rec):
    # rec is the app-signed record {game, account, name, avatar, score, ts, sig, pub}; the relay verifies
    # the signature before recording it, so the node only forwards it.
    post('/score', rec)
    return {"ok": True}

# ---- read (aggregate the leaderboard across relays) -------------------------------------------------
def leaderboard(game):
    relays = discover_relays()
    qsg = urllib.parse.urlencode({'game': game})
    def _fetch(r):
        try:
            return json.loads(urllib.request.urlopen(r + '/leaderboard?' + qsg, timeout=4).read()).get('scores', [])
        except Exception:
            return None
    if relays:                                        # PARALLEL fan-out (leaderboards are polled/hot)
        with ThreadPoolExecutor(max_workers=min(16, len(relays))) as ex:
            results = list(ex.map(_fetch, relays))
    else:
        results = []
    best = {}                                         # account -> highest-scoring record seen
    for rows in results:
        if not rows:
            continue
        for row in rows:
            acc = row.get('account')
            if not acc:
                continue
            cur = best.get(acc)
            if cur is None or int(row.get('score', 0)) > int(cur.get('score', 0)):
                best[acc] = row
    ranked = sorted(best.values(), key=lambda r: int(r.get('score', 0)), reverse=True)
    return {"ok": True, "scores": ranked[:50]}

# ---- directory ---------------------------------------------------------------------------------------
# The games directory lives on the RELAYS as a publisher-SIGNED record (xc_gamespub.py publishes it), so
# a new or updated game is a re-sign + re-push — NEVER a node redeploy. We fetch every relay's copy, keep
# the newest record that carries a VALID pinned-publisher signature, and return its games. backend/games.json
# is only a local fallback for a cold network that has no signed record yet.
def _verify_dir(rec):
    try:
        if rec.get('publisher') != PUBLISHER:
            return False
        return xc.pub_to_addr(rec.get('pub', '')) == PUBLISHER and \
            xc.verify_msg(rec.get('pub', ''), xc.gamesdir_canon(rec), rec.get('sig', ''))
    except Exception:
        return False

def directory():
    relays = discover_relays()
    def _fetch(r):
        try:
            return json.loads(urllib.request.urlopen(r + '/gamesdir', timeout=4).read()).get('records', [])
        except Exception:
            return None
    results = []
    if relays:
        with ThreadPoolExecutor(max_workers=min(16, len(relays))) as ex:
            results = list(ex.map(_fetch, relays))
    best = None
    for recs in results:
        for rec in (recs or []):
            if _verify_dir(rec) and (best is None or int(rec.get('ts', 0) or 0) > int(best.get('ts', 0) or 0)):
                best = rec
    if best is not None:
        return {"ok": True, "games": best.get('games', []), "signed": True}
    try:                                              # cold-start fallback: local file, unsigned
        games = json.load(open(GAMES_FILE))
    except Exception:
        games = []
    return {"ok": True, "games": games, "signed": False}
