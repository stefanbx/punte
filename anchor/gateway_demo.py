#!/usr/bin/env python3
# Proof that the gateway resolves an anchored name and routes it correctly — all three modes, plus the
# available-name and wrong-host paths, and the trustless /.well-known/anchor.json proof.
# Run: ~/.xchat-mesh-node/venv/bin/python anchor/gateway_demo.py
import hashlib, json
import anchor as A
import gateway as G

T = [1000]
def ts(): T[0] += 60; return T[0]

def mk(endpoints):
    """A fresh anchor with a one-event log carrying `endpoints`. Returns (anchor_id, root_priv, log)."""
    rootP, _, anchor = A.new_key()
    o0p, o0, _ = A.new_key()
    o1p, o1, _ = A.new_key()
    log = [A.inception(rootP, o0, A.commit(o1), ts(), endpoints)]
    return anchor, rootP, log

# alice → redirects to her own server; bob → default profile; carol → signed static content
alice, aliceRoot, aliceLog = mk({'web': 'redirect:https://alice.example.dev', 'display': 'Alice'})
bob,   bobRoot,   bobLog   = mk({'web': '', 'display': 'Bob Léon'})
page = b'<!doctype html><title>Carol</title><h1>Carol, served hash-verified</h1>'
cid = 'sha256-' + hashlib.sha256(page).hexdigest()
carol, carolRoot, carolLog = mk({'web': 'content:' + cid, 'display': 'Carol'})

state = {
    'leases': [
        G.make_lease('alice', alice, aliceRoot, ts()),
        G.make_lease('bob',   bob,   bobRoot,   ts()),
        G.make_lease('carol', carol, carolRoot, ts()),
    ],
    'anchors': {alice: aliceLog, bob: bobLog, carol: carolLog},
    'blobs': {cid: page},
}

def show(host, path='/'):
    r = G.resolve_request(host, path, state)
    loc = r['headers'].get('Location', '')
    extra = f" → {loc}" if loc else ''
    if r['status'] == 200 and 'json' not in r['headers']['Content-Type']:
        extra = f"  ({len(r['body'])} bytes html, X-Anchor={r['headers'].get('X-Anchor','')[:18]}…)"
    print(f"  {host+path:<42} {r['status']}  {r['headers']['Content-Type'].split(';')[0]:<16}{extra}")
    return r

print('\nRESOLVER ROUTING  (base = %s)\n' % G.BASE)
show('alice.xno.name', '/')                 # → 307 redirect to her server
show('bob.xno.name', '/')                   # → 200 default profile
show('carol.xno.name', '/')                 # → 200 hash-verified static content
show('nobody.xno.name', '/')               # → 404 claim page (name available)
show('deep.alice.xno.name', '/')           # → 421 (wildcard cert covers ONE level)
show('alice.evil.com', '/')                # → 421 (not our zone)
show('_acme-challenge.xno.name', '/')      # → 404 (reserved; ACME handled at the DNS layer)

print('\nTRUSTLESS PROOF  /.well-known/anchor.json  (anchor-aware client re-verifies the chain itself)')
r = G.resolve_request('alice.xno.name', '/.well-known/anchor.json', state)
doc = json.loads(r['body'])
print('  anchor      :', doc['anchor'])
print('  current_key :', doc['current_key'][:24], '…   seq =', doc['seq'])
# a client verifies WITHOUT trusting the gateway: re-run resolve() on the served log
verified = A.resolve(doc['log'])
print('  client re-verifies log →', 'current_key matches:',
      verified['current_key'] == doc['current_key'])

print('\nTAMPER CHECK  (gateway lies about the current key in a forged log)')
forged = [dict(doc['log'][0])]; forged[0]['op_key'] = A.new_key()[1]     # swap the key, keep the sig
bad = A.try_resolve(forged)
print('  client re-verifies tampered log →', 'REJECTED' if not bad['ok'] else 'ACCEPTED(!)',
      '—', bad.get('error', '')[:52])
print()
