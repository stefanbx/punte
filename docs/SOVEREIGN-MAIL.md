# Sovereign Mail — a modern encrypted email service on Punte

Status: design / roadmap (v0.1, 2026-08-25). Turns Punte's sealed DMs into an email-grade service:
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

1. **Relay: transient mailbox (DONE)** — a signed `POST /dm_delete {account, mids, ts, sig, pub}` removes the
   caller's own delivered messages, matched by `mid`. The signature is over
   `sig_canon('dmdelete', acc, ts, sha256(sorted mids))`, so it proves mailbox ownership AND binds the exact
   mid set — a captured token can neither delete a different set nor another mailbox; the same
   `DM_SIG_WINDOW` bounds its lifetime. Only the caller's own bucket is ever touched (`_dm_delete`). Tested
   by `test/dm_delete_test.py` (15 checks). *(A blind variant sealed to the relay key, so the delete doesn't
   re-expose the account like `/dm_sealed_read`, is a later refinement.)*
2. **Client: local encrypted archive (DONE)** — `lib/mail_archive.dart`: a persistent on-device store of
   received (and sent-self) messages, keyed by `mid`, **encrypted at rest** with a self-box to the user's DM
   key (only the seed opens it; written temp-then-rename so a crash never truncates it). `inbox()` now
   decrypts fresh records, writes them to the archive FIRST, then ACK-deletes them off every relay, and
   returns archive ∪ this poll — so a delivered message stops existing on the relay yet persists locally.
   Proven end to end by `test/mail_archive_test.dart` (archived → relay drops → survives the drop → on-disk
   bytes are ciphertext).
3. **Relay: push notices (DONE)** — the registrar/relay is itself a *sender*: as a
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

Push notices (3) ✅ → client local archive (2) + relay transient delete (1) ✅ — the relay is now truly
transient: a delivered message is archived locally (encrypted to the seed) and dropped from every relay.
Remaining: read receipts (4, optional), and the blind sealed delete variant.
