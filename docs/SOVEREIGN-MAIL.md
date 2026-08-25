# Sovereign Mail — a modern encrypted email service on Knot

Status: design / roadmap (v0.1, 2026-08-25). Turns Knot's sealed DMs into an email-grade service:
**end-to-end encrypted in transit and at rest, with the relay as a TRANSIENT store that clears once
delivery is confirmed, and the CLIENT as the permanent, user-only encrypted archive.**

## The model (what the user asked for)

> "the relay stores them until receipt is confirmed, then stored encrypted and can be opened just by the
> user."

- **In transit:** a message is sealed to the recipient's key on the sender's device. The relay only ever
  holds ciphertext and (sealed-sender) never learns who sent it. *(Done — `lib/mail.dart`.)*
- **Relay = transient mailbox:** a message sits in the recipient's relay mailbox ONLY until the recipient
  has fetched it AND confirmed receipt. Then the relay **drops** it. The relay is store-and-forward
  transport (like SMTP that clears after delivery), never a permanent archive — which also shrinks the
  metadata that accumulates on any one operator over time.
- **Client = permanent local archive:** the recipient keeps every message in a local store, **encrypted at
  rest** with a key only the seed can derive, so a stolen device file is useless without the seed. The
  archive survives the relay dropping the message.
- **Openable only by the user:** at rest the message stays sealed to the user's own DM key (the ciphertext
  we already hold decrypts only with the seed), so "encrypted, user-only" is the same guarantee end to end.

## Delivery lifecycle

```
send ──▶ relay mailbox (ciphertext)
                 │  recipient polls (blind read: relay learns the mailbox, not the client IP)
                 ▼
        client fetches ──▶ writes to LOCAL encrypted archive ──▶ ACK (delete-by-mid) ──▶ relay DROPS it
                 │
                 └──▶ (optional) sealed read-receipt to the sender → "delivered"
```

- **ACK / delete:** after a message is safely in the local archive, the client sends a signed
  `delete {mids}` for its OWN mailbox (authenticated by mailbox ownership, exactly like the blind read's
  `_mailbox_ok`). The relay removes those records. Undelivered messages remain until their per-mailbox cap.
- **Confirmation to the sender (optional):** the recipient can send a small sealed read-receipt back so the
  sender's client shows "delivered". This is opt-in (it links recipient→sender at that moment) and off by
  default for privacy.
- **No double-drop:** the client deletes only AFTER a successful local write, and the local archive dedups
  by `mid`/ciphertext, so a re-fetch before the delete lands never duplicates or loses a message.

## Components (what to build)

1. **Relay: transient mailbox** — a signed `POST /dm_delete {account, mids, ts, sig, pub}` that removes the
   caller's own delivered messages (ownership-checked). Optionally a blind variant sealed to the relay key,
   so the delete doesn't re-expose the account (mirrors `/dm_sealed_read`).
2. **Client: local encrypted archive** — a persistent on-device store of received (and sent-self) messages,
   keyed by `mid`, encrypted at rest to the user's DM key. The Mail view reads from the archive first, then
   merges anything new off the relay; after writing new ones it fires the delete.
3. **Relay: push notices (FIRST PIECE, this iteration)** — the registrar/relay is itself a *sender*: as a
   subscription nears expiry it seals a renewal notice to the owner's published DM key and drops it in their
   mailbox. The owner receives it in Mail like any message. This closes the renewal loop with a real push,
   not just a locally-synthesized reminder.
4. **Read receipts (optional, later)** — opt-in sealed delivery confirmations.

## Privacy properties (kept)

- Relay holds ciphertext only; sealed-sender hides the sender; blind read hides the reader's IP; the
  transient model means a delivered message stops existing on the relay at all.
- The local archive is encrypted at rest to the seed — device theft ≠ mail disclosure.
- Read receipts are OPT-IN because a receipt necessarily links recipient→sender at send time.

## Build order

Push notices (3) now — they exercise the relay-as-sender path and immediately close the renewal loop. Then
the client local archive (2) + relay delete (1) to make the relay truly transient. Read receipts (4) last.
