# Anchor — a rotatable, self-certifying identity (isolated prototype)

A standalone build of the highest-leverage primitive from the **Anchored Naming** concept note
(Layer 0, §4.2–4.4): an identity whose **operational key can rotate**, with KERI-style **pre-rotation**,
so a **stolen key can be revoked without losing the identity, its name, or its history**.

## It does not touch xchat

This directory is purely additive. `anchor.py` imports `../backend/xc_common.py` **read-only** for the
crypto (the same `sig_canon` signing discipline xchat uses), and edits no xchat file. Delete `anchor/`
and xchat is byte-for-byte unchanged. It runs, tests, and demos on its own.

## Run the proof

```bash
~/.xchat-mesh-node/venv/bin/python anchor/demo.py
```

It shows, on real keys:

1. Inception (cold root delegates an operational key) + a normal rotation.
2. **Theft** of the current operational key — the attacker can *impersonate* but **cannot advance the
   chain**: every forged rotation is rejected because it can't satisfy the pre-rotation commitment.
3. **Recovery** — the holder reveals the pre-committed next key, rotates away, and the stolen key dies.
   The anchor id and history are unchanged.
4. **Cold-root escape hatch** — if the pre-rotation material is lost, the offline root re-establishes a
   fresh operational key.

## What it defends, and what it doesn't

- **Defends:** theft / compromise of an operational key (revoke + rotate, keep the anchor).
- **Does not:** blind loss of *all* key material — that needs a social/threshold recovery layer, a
  later phase, and the concept note flags it honestly (§9). Fatal only if the **cold root** is lost.

## Files

- `anchor.py` — the primitive: keys, event log, pre-rotation, root recovery, and `resolve()` (a client
  validating an anchor's current key from its log).
- `demo.py` — the theft-and-recovery proof above.
