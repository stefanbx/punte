#!/usr/bin/env python3
# Proof that the anchor primitive delivers its one headline property:
#   a STOLEN operational key can be revoked WITHOUT losing the identity, its name, or its history.
# Run: python3 anchor/demo.py   (needs the venv with nanopy: ~/.xchat-mesh-node/venv/bin/python)
import anchor as A

def short(k): return k[:14] + '…'
def line():   return print('─' * 72)

T = [1000]                                   # deterministic, monotonic timestamps
def ts(): T[0] += 60; return T[0]

# ---- keys: one COLD root + a chain of operational keys (each holder-generated, next kept secret) ----
rootP, rootPub, ANCHOR = A.new_key()
o0p, o0, _ = A.new_key()
o1p, o1, _ = A.new_key()
o2p, o2, _ = A.new_key()
o3p, o3, _ = A.new_key()
oRp, oR, _ = A.new_key()

print('\nANCHOR (stable identity + payment address):\n  ', ANCHOR, '\n')

# ---- 1. inception: cold root delegates to o0, pre-commits o1 ----
log = [A.inception(rootP, o0, A.commit(o1), ts())]
r = A.resolve(log)
line(); print('1. INCEPTION      current op-key =', short(r['current_key']), '  (delegated by the cold root)')

# ---- 2. a normal rotation o0 -> o1 (reveal o1, self-signed, matches the commitment) ----
log.append(A.rotate(log[-1], o1p, o1, A.commit(o2), ts()))
r = A.resolve(log)
print('2. ROTATE  o0→o1  current op-key =', short(r['current_key']),
      '  anchor UNCHANGED:', r['anchor'] == ANCHOR)

# ---- 3. THEFT of the current operational key o1 ----
line(); print('3. THEFT — attacker steals the CURRENT operational key o1')
stolen_sig = dict(l.split(' ', 1) for l in A.xc._sign_lines(o1p, 'transfer everything to me'))
impersonates = A.xc.verify_msg(stolen_sig['pub'], 'transfer everything to me', stolen_sig['sig'])
print('   • attacker can SIGN as o1 (impersonation is real):', impersonates)

#   3a. attacker forges a rotation revealing a key THEY control (oX) — fails the pre-rotation commitment
axP, ax, _ = A.new_key()
forged = A.rotate(log[-1], axP, ax, A.commit(A.new_key()[1]), ts())
res = A.try_resolve(log + [forged])
print('   • attacker forges a rotation to their own key →', 'REJECTED' if not res['ok'] else 'ACCEPTED(!)')
print('       reason:', res.get('error'))

#   3b. attacker re-uses the stolen o1 itself to try to advance the chain — also fails the commitment
reuse = A.rotate(log[-1], o1p, o1, A.commit(ax), ts())
res2 = A.try_resolve(log + [reuse])
print('   • attacker re-signs with the stolen o1 →', 'REJECTED' if not res2['ok'] else 'ACCEPTED(!)')
print('       reason:', res2.get('error'))

# ---- 4. RECOVERY: the real holder reveals the pre-committed next key o2 and rotates away from o1 ----
line(); print('4. RECOVERY — holder reveals the pre-committed o2 (only they had it) and rotates o1→o2')
log.append(A.rotate(log[-1], o2p, o2, A.commit(o3), ts()))
r = A.resolve(log)
print('   current op-key =', short(r['current_key']), ' (o1 is now retired — the stolen key is dead)')
print('   anchor id UNCHANGED:', r['anchor'] == ANCHOR, '  history preserved: seq =', r['seq'])
#   the attacker STILL cannot advance the recovered chain (they never had o3)
res3 = A.try_resolve(log + [A.rotate(log[-1], axP, ax, A.commit(ax), ts())])
print('   attacker attempts to rotate the recovered chain →', 'REJECTED' if not res3['ok'] else 'ACCEPTED(!)')

# ---- 5. COLD-ROOT ESCAPE HATCH: pre-rotation chain lost → root re-establishes a fresh op key ----
line(); print('5. ROOT RECOVERY — pre-rotation material lost; the cold root re-establishes a fresh key')
log.append(A.root_recover(log[-1], rootP, oR, A.commit(A.new_key()[1]), ts()))
r = A.resolve(log)
print('   current op-key =', short(r['current_key']), ' (re-established by the cold root)')
print('   anchor id UNCHANGED:', r['anchor'] == ANCHOR, '  seq =', r['seq'])

line()
print('RESULT: identity survived a key theft AND a key loss; the anchor id never changed.')
print('        Fatal only if the COLD ROOT is lost — the one secret you keep offline. (concept note §9)\n')
