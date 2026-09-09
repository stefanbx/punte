#!/usr/bin/env python3
"""A notification names the post it is about, end to end.

Notifications used to carry only {from, kind, text, ts}. That is enough to SAY "alice liked your
post" and not enough to GO there — tapping one in the app could only ever do nothing, because the
post it refers to was never on the wire. This adds post_id and checks the whole path:

    /notify_push {post_id: ...}   →   the relay's queue   →   /notify

Also checks the compatibility direction that actually matters in a live mesh: a push from an OLDER
client (no post_id) must still be stored and served, with an empty id, not rejected — otherwise
rolling this out would drop every notification from a phone that hasn't updated.

Runs a REAL relay on a spare port, isolated (XC_ISOLATE=1 + a dead RPC), so it never touches the
live mesh.

    python3 test/notify_post_id_test.py
"""
import json, os, socket, subprocess, sys, time, urllib.error, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RELAY_DIR = os.path.join(REPO, 'relay')

PASS = FAIL = 0
def check(cond, label, extra=None):
    global PASS, FAIL
    if cond: PASS += 1; print(f'  ✓ {label}')
    else:    FAIL += 1; print(f'  ✗ {label}' + (f'   |  {extra}' if extra is not None else ''))

def free_port():
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

def req(url, data=None, timeout=10):
    try:
        r = urllib.request.Request(url, data=data,
                                   headers={'Content-Type': 'application/json'} if data else {})
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.getcode(), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(e).encode()

def wait_up(url, tries=80, delay=0.2):
    for _ in range(tries):
        c, _b = req(url, timeout=2)
        if c and c < 500: return True
        time.sleep(delay)
    return False

def main():
    port = free_port()
    store = f'/tmp/xc_notifid_{port}.json'
    for suffix in ('', '.id'):
        try: os.remove(store + suffix)
        except OSError: pass
    env = {**os.environ, 'XC_ISOLATE': '1', 'XC_NANO_RPC': 'http://127.0.0.1:1'}
    proc = subprocess.Popen([sys.executable, 'xc_relayd.py', str(port), store],
                            cwd=RELAY_DIR, env=env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = f'http://127.0.0.1:{port}'
    try:
        if not wait_up(base + '/health'):
            print('relay did not come up'); return 1
        acct = 'nano_1recipient'

        push = lambda o: req(base + '/notify_push', json.dumps(o).encode())
        code, _ = push({'to': acct, 'from': 'alice.xno', 'kind': 'like',
                        'text': 'liked: hello', 'ts': 1700000000, 'post_id': 'post_abc'})
        check(code == 200, 'a push carrying post_id is accepted', code)

        code, _ = push({'to': acct, 'from': 'bob.xno', 'kind': 'comment',
                        'text': 'commented on your post', 'ts': 1700000001})
        check(code == 200, 'a push from an older client (no post_id) is still accepted', code)

        code, body = req(base + '/notify?handle=' + acct)
        got = json.loads(body).get('notifs', []) if code == 200 else []
        by = {n.get('from'): n for n in got}
        check(len(got) == 2, 'both notifications are queued', got)
        check(by.get('alice.xno', {}).get('post_id') == 'post_abc',
              'post_id survives the queue and is served back', by.get('alice.xno'))
        check(by.get('bob.xno', {}).get('post_id') == '',
              "an older client's notification reads back with an empty id, not a missing key",
              by.get('bob.xno'))
        check(by.get('alice.xno', {}).get('text') == 'liked: hello',
              'the rest of the payload is untouched', by.get('alice.xno'))
    finally:
        proc.terminate()
        try: proc.wait(timeout=5)
        except Exception: proc.kill()
        for suffix in ('', '.id'):
            try: os.remove(store + suffix)
            except OSError: pass
    print(f'\n{PASS} passed, {FAIL} failed')
    return 1 if FAIL else 0

if __name__ == '__main__':
    sys.exit(main())
