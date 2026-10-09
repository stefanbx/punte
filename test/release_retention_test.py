#!/usr/bin/env python3
"""Superseded release binaries are dropped even when this relay is a "responsible" placement holder.

reconcile_release_pins spared any cid the relay was responsible for. With a placement tier no bigger
than its replica count (2 stable relays, 2 replicas) every relay is responsible for every cid, so no
old build was ever dropped: on 2026-10-09 relay-1 held 21 superseded APKs (~381 MB) next to ~10 MB of
user content. Now only the newest-N window and paid pins keep a release's bytes.

Extracts and runs the real reconcile_release_pins from xc_relayd.py (importing the module would start
its HTTP server), with _responsible stubbed to True for every cid.

    python3 test/release_retention_test.py
"""
import os, re, sys, threading

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = open(os.path.join(REPO, 'relay', 'xc_relayd.py')).read()

fails, checks = [], 0
def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)

m = re.search(r'\ndef reconcile_release_pins\(\):.*?(?=\ndef )', SRC, re.S)
check(m is not None, 'found reconcile_release_pins in xc_relayd.py')

class FakeDB:
    def __init__(self): self.deleted = []
    def execute(self, sql, args=()):
        if sql.startswith('DELETE FROM blob'):
            self.deleted.append(args[0])
    def commit(self): pass

db = FakeDB()
ns = {
    'releases': {'pubA': [{'cid': c, 'version': v} for c, v in
                          [('old1', '2.5.8'), ('old2', '2.5.9'), ('paid', '2.5.10'),
                           ('k1', '2.5.12'), ('k2', '2.5.13'), ('k3', '2.5.14')]]},
    'pinned': {'old1': 9e18, 'k1': 9e18, 'k2': 9e18, 'k3': 9e18},
    'pins_paid': {'someone': 'paid'},
    'blob_meta': {c: {'size': 1} for c in ('old1', 'old2', 'paid', 'k1', 'k2', 'k3', 'user_photo')},
    '_release_pin_cids': lambda: {'k1', 'k2', 'k3'},
    '_responsible': lambda cid, sets=None: True,   # small tier: responsible for EVERYTHING
    '_blob_lock': threading.Lock(),
    '_db': db,
}
if m:
    exec(m.group(0), ns)
    ns['reconcile_release_pins']()

print('\n--- every relay responsible for every cid (2 relays, 2 replicas) ---')
check(sorted(db.deleted) == ['old1', 'old2'], 'superseded builds are deleted', f'deleted={db.deleted}')
check('old1' not in ns['pinned'], "a superseded build's pin is lifted")
for c in ('k1', 'k2', 'k3'):
    check(c in ns['blob_meta'] and c not in db.deleted, f'newest-window build {c} is kept')
check('paid' in ns['blob_meta'], 'a paid-pinned old build is kept')
check('user_photo' in ns['blob_meta'], 'non-release content is never touched')

print(f'\n{checks - len(fails)}/{checks} checks passed')
sys.exit(1 if fails else 0)
