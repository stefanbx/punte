#!/usr/bin/env python3
# ANCHOR — a self-certifying identity whose OPERATIONAL KEY can rotate, with KERI-style pre-rotation
# so a stolen key can be revoked WITHOUT losing the identity, its name, or its history.
#
# This is the highest-leverage primitive from the "Anchored Naming" concept note (Layer 0, §4.2–4.4),
# built as a STANDALONE module. It imports xchat's crypto (xc_common) READ-ONLY and edits no xchat
# file — delete this directory and xchat is byte-for-byte unchanged. The signing discipline is exactly
# xchat's (sig_canon: domain-separated, length-prefixed), so the two share proven crypto without coupling.
#
# Model
# -----
#   anchor id           = addr(k_root)  — a stable nano_ address; the identity AND the cold root.
#   operational key      = the day-to-day signing key (posts, DMs, TLS). Rotatable.
#   pre-rotation          = each event commits H(next operational key) BEFORE that key is used, so an
#                           attacker who steals the CURRENT operational key cannot rotate the identity
#                           (rotating needs the NEXT key, which the holder alone kept secret).
#   root recovery         = the cold root can always re-establish a fresh operational key (escape hatch
#                           for a broken/lost pre-rotation chain). Only losing k_root is fatal — and it
#                           is cold, backed up, and almost never used.
#
# Event log (an ordered, self-published chain per anchor — the same shape xchat's signed "heads" have):
#   { anchor, seq, prev, authority, op_key, next, endpoints, ts, sig, pub }
#     authority = 'root'         -> signed by k_root (inception, or a recovery override)
#     authority = 'pre-rotation' -> signed by the REVEALED op_key; H(op_key) must equal the prior `next`
#
# What it defends: THEFT / compromise of an operational key (revoke + rotate away, keep the anchor).
# What it does NOT: blind loss of ALL key material (needs a social/threshold layer — a later phase,
# and honestly flagged as unresolved in the concept note §9).

import os, json, hashlib, importlib.util

# --- import xchat's crypto read-only (same pattern xchat's own tools use) ---
_XC = os.path.join(os.path.dirname(__file__), '..', 'backend', 'xc_common.py')
_spec = importlib.util.spec_from_file_location('xc_common', _XC)
xc = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(xc)

DOMAIN = 'anchor-evt'   # sig_canon type tag → a disjoint preimage space, can't collide with xchat's


# ---------- keys ----------
def new_key():
    """A fresh operational/root keypair. Returns (priv_hex, pub_hex, nano_address)."""
    priv = os.urandom(32).hex()
    addr, pub = xc.derive(priv)
    return priv, pub, addr


def commit(pub_hex):
    """The pre-rotation commitment: BLAKE2b-256 of the NEXT operational public key."""
    return hashlib.blake2b(bytes.fromhex(pub_hex), digest_size=32).hexdigest()


# ---------- events ----------
def _canon(e):
    # Canonical signing preimage — xchat's sig_canon (length-prefixed, domain-tagged). Everything that
    # binds the event is inside it; sig/pub are the output and are excluded.
    return xc.sig_canon(DOMAIN, e['anchor'], e['seq'], e['prev'], e['authority'],
                        e['op_key'], e['next'],
                        json.dumps(e.get('endpoints', {}), sort_keys=True, separators=(',', ':')),
                        e['ts'])


def event_hash(e):
    return hashlib.blake2b(_canon(e).encode(), digest_size=32).hexdigest()


def _sign(e, priv):
    d = dict(l.split(' ', 1) for l in xc._sign_lines(priv, _canon(e)))
    e['sig'] = d['sig']; e['pub'] = d['pub']
    return e


def inception(root_priv, op_pub, next_commit, ts, endpoints=None):
    """Event 0. The cold root delegates authority to op_pub and pre-commits the next key."""
    addr, _ = xc.derive(root_priv)
    e = {'anchor': addr, 'seq': 0, 'prev': '', 'authority': 'root',
         'op_key': op_pub, 'next': next_commit, 'endpoints': endpoints or {}, 'ts': ts}
    return _sign(e, root_priv)


def rotate(prev_event, new_op_priv, new_op_pub, next_commit, ts, endpoints=None):
    """A pre-rotation rotation. Reveals new_op_pub (must match the prior commitment) and self-signs it."""
    e = {'anchor': prev_event['anchor'], 'seq': prev_event['seq'] + 1, 'prev': event_hash(prev_event),
         'authority': 'pre-rotation', 'op_key': new_op_pub, 'next': next_commit,
         'endpoints': endpoints or {}, 'ts': ts}
    return _sign(e, new_op_priv)


def root_recover(prev_event, root_priv, new_op_pub, next_commit, ts, endpoints=None):
    """The cold-root escape hatch: re-establish a fresh operational key regardless of the pre-rotation
    chain (for a lost/broken next key). Signed by k_root."""
    e = {'anchor': prev_event['anchor'], 'seq': prev_event['seq'] + 1, 'prev': event_hash(prev_event),
         'authority': 'root', 'op_key': new_op_pub, 'next': next_commit,
         'endpoints': endpoints or {}, 'ts': ts}
    return _sign(e, root_priv)


# ---------- resolution (a client validating an anchor's CURRENT key from its log) ----------
class Invalid(Exception):
    pass


def resolve(events):
    """Validate the whole event log and return {ok, anchor, current_key, seq, endpoints, log:[...]}.
    Raises Invalid on the first rule violation, naming the failing event — a resolver either trusts the
    tip or it doesn't; a silently-accepted bad event is exactly the failure this primitive exists to stop.
    """
    if not events:
        raise Invalid('empty log')
    ev = sorted(events, key=lambda e: e['seq'])
    # contiguous, unique sequence — a fork (two events at one seq) is rejected, not silently merged.
    for i, e in enumerate(ev):
        if e['seq'] != i:
            raise Invalid(f'non-contiguous/duplicate seq at index {i}: got seq={e["seq"]}')

    trail = []
    anchor = ev[0]['anchor']
    pending = None          # H(next expected operational key)
    prev_hash = ''
    current = None

    for e in ev:
        # signature must verify over the canonical event
        if not xc.verify_msg(e.get('pub', ''), _canon(e), e.get('sig', '')):
            raise Invalid(f'seq {e["seq"]}: bad signature')
        # chain integrity
        if e['prev'] != prev_hash:
            raise Invalid(f'seq {e["seq"]}: prev hash mismatch (log tampered or reordered)')

        if e['authority'] == 'root':
            # inception or root override: the signer must be the anchor's root key itself
            if xc.pub_to_addr(e['pub']) != anchor:
                raise Invalid(f'seq {e["seq"]}: root event not signed by the anchor root key')
        elif e['authority'] == 'pre-rotation':
            if pending is None:
                raise Invalid(f'seq {e["seq"]}: pre-rotation before any commitment')
            # THE PRE-ROTATION CHECK: the revealed key must match the digest committed last time.
            if commit(e['op_key']) != pending:
                raise Invalid(f'seq {e["seq"]}: revealed key does not match the pre-rotation commitment '
                              '(a stolen current key cannot satisfy this)')
            # and the event must be SELF-signed by that revealed key
            if e['pub'] != e['op_key']:
                raise Invalid(f'seq {e["seq"]}: pre-rotation not self-signed by the revealed key')
        else:
            raise Invalid(f'seq {e["seq"]}: unknown authority {e["authority"]!r}')

        current = e['op_key']
        pending = e['next']
        prev_hash = event_hash(e)
        trail.append({'seq': e['seq'], 'authority': e['authority'], 'op_key': e['op_key'][:16] + '…'})

    return {'ok': True, 'anchor': anchor, 'current_key': current, 'seq': ev[-1]['seq'],
            'endpoints': ev[-1].get('endpoints', {}), 'log': trail}


def try_resolve(events):
    """resolve() but returns {'ok': False, 'error': ...} instead of raising — for the attacker paths."""
    try:
        return resolve(events)
    except Invalid as ex:
        return {'ok': False, 'error': str(ex)}
