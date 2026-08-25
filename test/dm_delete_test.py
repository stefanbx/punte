#!/usr/bin/env python3
"""The relay is a TRANSIENT mailbox: once a recipient has archived a message locally it ACKs by
deleting it here (docs/SOVEREIGN-MAIL), so a delivered message stops existing on any operator.

POST /dm_delete {account, mids, ts, sig, pub} must:
  - remove ONLY the caller's OWN records, and only the mids named,
  - require a signature that proves mailbox ownership AND binds the exact mid set,
  - refuse a forged/expired signature or a key that does not derive the account,
  - never touch another account's mailbox.

Verified against a REAL relay on a spare port, in isolation.

    python3 test/dm_delete_test.py
"""
import hashlib, json, os, socket, subprocess, sys, time, urllib.error, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, 'backend'))
import xc_common as xc

fails, checks = [], 0


def check(ok, what, detail=''):
    global checks
    checks += 1
    print(('ok    ' if ok else 'FAIL  ') + what + (f'   {detail}' if detail and not ok else ''))
    if not ok:
        fails.append(what)


def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p


ALICE_SEED, MALLORY_SEED = 'a1' * 32, 'd4' * 32
ALICE, ALICE_PUB = xc.derive(ALICE_SEED)[0], xc.derive(ALICE_SEED)[1]
MALLORY, MALLORY_PUB = xc.derive(MALLORY_SEED)[0], xc.derive(MALLORY_SEED)[1]


def mids_hash(mids):
    return hashlib.sha256('\n'.join(sorted(set(mids))).encode()).hexdigest()


def del_body(seed, acct, mids, ts=None, mids_for_sig=None, pub=None):
    """A signed delete. mids_for_sig lets a test sign over a DIFFERENT set than it sends (to prove the
    signature binds the exact set); pub lets a test present a mismatched key."""
    ts = int(ts if ts is not None else time.time())
    canon = xc.sig_canon('dmdelete', acct, ts, mids_hash(mids_for_sig if mids_for_sig is not None else mids))
    d = dict(l.split(' ', 1) for l in xc._sign_lines(seed, canon))
    return json.dumps({'account': acct, 'mids': mids, 'ts': ts, 'sig': d['sig'],
                       'pub': pub if pub is not None else d['pub']}).encode()


class Relay:
    def __init__(self):
        self.port = free_port()
        self.base = f'http://127.0.0.1:{self.port}'
        env = dict(os.environ, XC_ISOLATE='1', XCHAT_BOOTSTRAP='http://127.0.0.1:1')
        self.state = f'/tmp/xc_dmdelete_test_{self.port}.json'
        self.p = subprocess.Popen([sys.executable, 'xc_relayd.py', str(self.port), self.state],
                                  cwd=os.path.join(REPO, 'relay'), env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        end = time.time() + 40
        while time.time() < end:
            try:
                urllib.request.urlopen(self.base + '/heads', timeout=2).read(); return
            except Exception:
                time.sleep(0.3)
        raise RuntimeError('relay did not start: ' + (self.p.stdout.read() or b'').decode()[:800])

    def seed(self, to, mid, frm=MALLORY):
        body = json.dumps({'to': to, 'from': frm, 'from_pk': 'aa' * 32, 'ct': 'SEALED-' + mid,
                           'ts': int(time.time()), 'mid': mid}).encode()
        urllib.request.urlopen(urllib.request.Request(
            self.base + '/dm', body, {'Content-Type': 'application/json'}), timeout=10).read()

    def mids_in(self, acct):
        r = urllib.request.urlopen(f'{self.base}/dm?account={acct}', timeout=10)
        return {m.get('mid') for m in json.loads(r.read()).get('dms', [])}

    def delete(self, body):
        try:
            r = urllib.request.urlopen(urllib.request.Request(
                self.base + '/dm_delete', body, {'Content-Type': 'application/json'}), timeout=10)
            return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b'{}')

    def stop(self):
        self.p.terminate()
        try:
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()
        try:
            os.remove(self.state)
        except Exception:
            pass


r = Relay()
try:
    for m in ('m1', 'm2', 'm3'):
        r.seed(ALICE, m)
    r.seed(MALLORY, 'x9')
    check(r.mids_in(ALICE) == {'m1', 'm2', 'm3'}, 'seeded three records into alice', str(r.mids_in(ALICE)))

    print('\n--- the owner clears exactly the messages she names ---')
    st, d = r.delete(del_body(ALICE_SEED, ALICE, ['m1']))
    check(st == 200 and d.get('removed') == 1, 'alice deletes m1', f'{st} {d}')
    check(r.mids_in(ALICE) == {'m2', 'm3'}, 'm1 is gone, m2/m3 remain', str(r.mids_in(ALICE)))

    st, d = r.delete(del_body(ALICE_SEED, ALICE, ['m2', 'm3']))
    check(st == 200 and d.get('removed') == 2, 'alice clears the rest', f'{st} {d}')
    check(r.mids_in(ALICE) == set(), 'her mailbox is now empty (transient)', str(r.mids_in(ALICE)))

    print('\n--- a delete only ever touches the CALLER\'S own bucket ---')
    r.seed(ALICE, 'm4')
    st, d = r.delete(del_body(ALICE_SEED, ALICE, ['x9']))  # x9 lives in mallory's mailbox
    check(st == 200 and d.get('removed') == 0, 'alice naming a foreign mid removes nothing', f'{st} {d}')
    check('x9' in r.mids_in(MALLORY), "mallory's message is untouched", str(r.mids_in(MALLORY)))

    print('\n--- forged / mismatched / expired deletes are refused ---')
    st, d = r.delete(del_body(ALICE_SEED, ALICE, ['m4'], pub=MALLORY_PUB))
    check(st == 403, 'a key that does not derive the account is refused', f'{st} {d}')
    check('m4' in r.mids_in(ALICE), 'and m4 survives the refused delete', str(r.mids_in(ALICE)))

    st, d = r.delete(del_body(MALLORY_SEED, ALICE, ['m4']))
    check(st == 403, "mallory cannot delete from alice's mailbox with her own key", f'{st} {d}')

    # sign over [m1] but send mids=[m4]: the signature binds the exact set, so this must fail.
    st, d = r.delete(del_body(ALICE_SEED, ALICE, ['m4'], mids_for_sig=['m1']))
    check(st == 403, 'a signature over a different mid set is refused', f'{st} {d}')
    check('m4' in r.mids_in(ALICE), 'm4 still survives every refused delete', str(r.mids_in(ALICE)))

    st, d = r.delete(del_body(ALICE_SEED, ALICE, ['m4'], ts=time.time() - 4000))
    check(st == 400 and 'expired' in (d.get('error') or ''), 'an hour-old delete token is expired', f'{st} {d}')
    st, d = r.delete(del_body(ALICE_SEED, ALICE, ['m4'], ts=time.time() + 4000))
    check(st == 400, 'a future-dated delete token is refused', f'{st} {d}')

    # the valid delete still works after all the refusals
    st, d = r.delete(del_body(ALICE_SEED, ALICE, ['m4']))
    check(st == 200 and d.get('removed') == 1 and r.mids_in(ALICE) == set(),
          'a correct delete still clears m4', f'{st} {d} {r.mids_in(ALICE)}')
finally:
    r.stop()

print('\n%s — %d checks, %d failure(s)' % ('FAIL' if fails else 'PASS', checks, len(fails)))
for f in fails:
    print('  - ' + f)
sys.exit(1 if fails else 0)
