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

# ---- directory (content-addressed games registered in backend/games.json) ---------------------------
def directory():
    try:
        games = json.load(open(GAMES_FILE))
    except Exception:
        games = []
    return {"ok": True, "games": games}
