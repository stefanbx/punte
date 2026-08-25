# Sovereign Naming — impersonation, and the plan to close the gaps

Status: design / roadmap (v0.1, 2026-08-25). Owns the answer to: *"if a key is the DNS, can
someone register a look‑alike name and trick users?"* — **yes, at the human‑name layer**, and this is
how we make that safe without reintroducing a naming authority.

## The two layers

1. **Self‑certifying layer — `nano_…` address = public key.** Globally unique, unforgeable. Nobody can
   claim your address; a link carrying the *anchor address* always reaches exactly that identity. No
   impersonation is possible here. This layer is done and load‑bearing.

2. **Human‑name layer — a lease binds `alice` → anchor.** This is where impersonation lives. Names are
   short, memorable, and **read by humans**, so they can be confused. Three concrete attacks:

   - **Homograph / confusable** — `alіce` (Cyrillic і), `а1ice`, full‑width or combining look‑alikes.
     Different byte strings ⇒ different leases ⇒ both allowed. Same class as the DNS IDN‑homograph attack.
   - **Typo / semantic squatting** — `alice-official`, `alice.xno`, `alice2`. Cheap, visually plausible.
   - **Naming fork (worse than DNS)** — leases are *first‑valid‑claim‑per‑label*, and there is **no
     global consensus**. If relay A accepts `alice→X` and relay B accepts `alice→Y` before they sync,
     `accept_lease` refuses to overwrite either, so they **disagree forever**. DNS has a root to
     arbitrate; a sovereign system, by design, does not.

## The principle

**Keys are truth; names are hints.** We do *not* try to make the string globally‑unique‑and‑safe — that
requires a naming authority, the very thing being replaced. Instead we anchor every trust decision on the
**key**, and treat the human name as a lookup convenience that must be *confirmed against a key* before it
carries trust. This is the escape from Zooko's triangle: memorable **or** global‑without‑authority, pick
per use via petnames + optional registry.

## The gaps and the fixes (roadmap)

Each item is a concrete, implementable defense. Tagged by where it lives: **[browser]**, **[relay]**,
**[publish]**, **[spec]**. Priority P0 (do first) → P3.

### P0 — make the key visible and stable
- **[browser] Show the anchor fingerprint.** Every page's chrome shows a short, styled fingerprint of the
  resolved anchor key (e.g. `X4F2‑9A1C‑…`), not only the name. Trust attaches to what is shown.
- **[browser] Trust‑on‑first‑use (TOFU) pinning.** On first visit, remember `name → anchor`. On any later
  visit where the name resolves to a **different** anchor, block with a full‑screen warning (SSH
  `known_hosts` model). Pin store lives on device next to the identity seed. This alone defeats the
  fork/hijack‑after‑trust case: a swapped key can never be silent.

### P1 — make links and identities carry the key
- **[spec/browser] Key‑bearing links.** Define `nano://<name>@<anchor>` (and a bare `nano://<anchor>`).
  A link that carries the anchor resolves the **key**, and the name is only a display label — so a shared
  link cannot be hijacked by a homograph. Rendered links from a page must use this form.
- **[browser] Petnames / address book.** Let the user (and, later, their social graph) assign a **local**
  trusted name to a key: `alice` in *my* book = key X regardless of any relay. Petnamed names render with a
  distinct “known contact” affordance; un‑petnamed names never borrow that affordance.

### P2 — reduce confusables at the source and at render
- **[browser] Confusable / mixed‑script warning.** Client‑side heuristic: flag labels that are NFKC‑
  confusable with a pinned/petnamed name, or that mix scripts (Latin+Cyrillic), or use non‑NFKC‑normal
  codepoints. A hint, not a block — and never an authority.
- **[publish/relay] Label policy at claim time.** Normalize labels to NFKC and restrict the claimable set
  (e.g. `[a-z0-9-]`, no leading/trailing/double `-`, length bounds, a reserved‑word list). Enforced in the
  publish tool and re‑checked in `accept_lease`. Shrinks the homograph surface without deciding *who* owns
  a name. **Back‑compat:** existing leases are grandfathered; policy applies to new claims.

### P3 — ownership: the paid‑subscription registrar (CHOSEN MODEL, 2026‑08‑25)

The decision on "who owns a name, and how is a second claimant kept out": **a name is a paid, renewable
subscription, and the Nano ledger — not any relay — is the ownership authority.** This is the DNS‑registrar
model, made sovereign: the on‑chain payment is a globally‑verifiable, unforgeable ordering, so forks can't
persist and a name can't be stolen while its subscription is live; and because ownership lives on the
ledger (not in a relay), a relay going down never costs you your name.

**Registration / renewal.** To claim or renew `shop`, the owner publishes a lease record that cites one or
more **on‑chain payment blocks** — a Nano send from the owner split across the serving relays' accounts for
the current period. The lease canon binds `label, anchor, period_start, period_end (= start + PERIOD),
payment_block_hashes`, signed by the anchor root key. Any relay AND the client verify: signature ok; the
cited blocks are CONFIRMED sends of ≥ the required share to the required relay accounts, dated within the
period. This reuses the existing on‑chain verification already used for pay‑to‑pin (`grant_pin`) —
confirmed, correct subtype, correct destination, consumed once.

**Ownership + conflict resolution (solves the same‑name collision).**
- A label is owned by the anchor whose subscription is **currently active** (`now < period_end`).
- Two competing claims → the one backed by the **earlier confirmed payment** wins. Confirmation order is on
  the ledger, so every relay and client computes the same winner; the later claimant's lease is rejected
  while an active one exists. A fork can't survive: a relay that briefly accepted Bob re‑checks the ledger,
  sees Alice's earlier active payment, and drops Bob's as invalid. **Convergence is forced by the chain.**
- Squatting is bounded by cost — every name (and every renewal) is a real payment.

**Dormant / unused domains (recurring fee, not one‑time).** A one‑time payment would let a squatter park a
name forever. The fee is a **recurring subscription**, so a dormant owner who stops paying lets the name
expire → grace → become reclaimable (below). The recurring fee is the *holding cost* that makes idle names
expensive to hoard and returns unused ones to the pool. (Harberger self‑assessed tax — declare a price, pay
a % of it, anyone may buy at that price — is a more aggressive anti‑squat variant to consider; flat
recurring + expiry is the understandable default.)

**Where the money goes — relays, not a burn.** The fee is **revenue to the relays** that store and serve
the name and its content — it funds the system running, and aligns incentives (relays earn by carrying
names). It is split across the K relays a registration names, so many relays are paid to keep each name
alive.

**Relay‑down resilience (concrete rule).** Verification sums confirmed sends to **any known relay account**
and requires the total ≥ price. So the payer pays whichever relays are **live**; a down or vanished relay
neither blocks registration/renewal nor can withhold a name (ownership is on‑chain and the lease replicates
to every relay via `backfill()`). A Nano account can receive while its relay server is offline, so even a
temporarily‑down relay still collects its share and serves once back.

**Expiry → notice → grace → reclaim (the lifecycle).**
- Within `RENEW_WINDOW` of `period_end`, relays send the owner a **renewal notice** — a Knot message,
  surfaced by the browser's mail agent (see Unified client below).
- At `period_end`, a `GRACE` period starts: the name still resolves but is flagged *expiring*, with more
  notices.
- After `period_end + GRACE` with no renewal, the name is **reclaimable** — a new claimant may register it
  with a fresh subscription (DNS‑style drop). The lapsed owner has lost it.

**Availability — "what if a relay goes down?" (answered).** Ownership does not depend on any single relay:
it is proven on the ledger, and the lease + payment references replicate to every relay via `backfill()`.
A downed relay changes nothing — other relays serve the same name and honour the same on‑chain ownership.
The payment is **split across K relay accounts**, so many relays are paid to carry the name → redundancy by
incentive, no single point of failure, and renewals can be paid to whichever relays are live.

**Parameters (tunable defaults).** `PERIOD` = 1 year · `PRICE` = small, per name · split across the top‑K
relay accounts · `RENEW_WINDOW` = 30 days · `GRACE` = 30 days · min confirmations before a payment counts.
Recommended: **per‑relay payments, no central registry account** (a central account would be a rug/SPOF);
the lease cites one payment block per relay share, each independently verifiable against a known relay
account.

**Anonymity of the payment (must not de‑anonymize owners).** A naive design — pay for `shop` from your
main wallet — publishes a `funding‑account → domain` link on the public ledger forever. The registrar is
built to avoid that:
- **The payer is NOT the anchor.** Ownership is proven by the anchor's *signature* on the lease; the payment
  only has to be a confirmed send of the right amount to the relay accounts. So the money can come from ANY
  account — never require, or assume, that the payer equals the anchor.
- **Pay from a fresh, unlinked account** (funded via a fresh receive) per domain / per renewal, so the trail
  reads "some throwaway account paid," not "your identity paid." The client should make a fresh payer the
  default.
- **Residual, stated plainly:** the lease cites the payment block, so `lease → payment → payer` is a public
  link; strong anonymity is the owner's choice of how they fund. A future blind/zk payment proof could
  remove even this. Serving anonymity is separate: the tunnel hides the anchor account from entries (routing
  by ephemeral token), but not the node's IP or a visitor's IP+cid — that needs the Layer‑B mix hop.

**Why this is still sovereign.** The relay never decides ownership — it only *checks the ledger* and serves.
The authority is the chain, which anyone can read; the relay can fail to serve or lie, but a client
verifies the payments itself, so a lying relay is caught. No CA, no central root, no external service.

**Build order for this model:** (1) relay: paid‑lease verification (`paid_until`, cite+verify payment
blocks, reject a later claim over an active sub) reusing the pay‑to‑pin machinery; (2) client: verify the
payment + show `paid_until`/owner fingerprint, plus the P0 TOFU pin as the belt‑and‑braces user protection;
(3) renewal notices over Knot messages; (4) expiry/grace/reclaim state machine; (5) split‑payment settlement
across relay accounts. Keep P0 (TOFU + fingerprint) regardless — it protects users during the transition and
against any relay that misreports the ledger.

## Unified client — browser + mail + IDE, one key

Direction (2026‑08‑25): the app is not just a browser. It is one sovereign client with three faces over a
single identity key:
- **Browser** — resolve, verify, and render sovereign pages (done).
- **Mail agent** — the user's messages, built on Knot's existing signed DMs. System notices (renewal
  reminders, expiry warnings, "your name is contested") arrive here. This is also how the registrar reaches
  a name's owner.
- **IDE / publisher** — author Keel pages, publish under a name, share files, and serve services from the
  local node (done: Publish panel + `xc_node.py`).

One identity signs pages, receives mail, and owns names — so "email me to renew" and "verify who owns this
page" are the same key. The mail agent is the natural carrier for the registrar's renewal lifecycle above.

## Non‑negotiable invariants (so fixes don't undo the model)
- The relay is **never** an authority. Every naming answer is verified on device; a relay can fail to
  serve or disagree, never forge.
- No fix may require a single global root, a CA, or an external service.
- Every trust affordance in the UI must be backed by a **key**, not a string.

## Current state (what exists today, 2026‑08‑25)
- Leases: first‑valid‑claim‑per‑label, signed by the anchor root key, propagated via `backfill()`.
  ⇒ fork risk (P3) is real and unmitigated today.
- No key display, no TOFU pin, no petnames, no confusable check, no label policy, no key‑bearing links.
  ⇒ P0–P2 are all open.
- The self‑certifying layer (addresses = keys) is complete and correct.

## Suggested order of work
Ownership model is now decided (P3 = paid‑subscription registrar). Recommended sequence:
1. **P0 client safety first** (key fingerprint + TOFU pin + multi‑relay "contested" check) — small, and it
   protects users during the whole registrar build and against any relay that misreports the ledger.
2. **Registrar core** — relay paid‑lease verification (`paid_until`, cite+verify on‑chain payments, reject a
   later claim over an active subscription) reusing the pay‑to‑pin machinery; client verifies the payment
   and shows `paid_until` + owner fingerprint.
3. **Lifecycle** — renewal notices over Knot mail, then expiry/grace/reclaim.
4. **Split‑payment settlement** across relay accounts.
5. **P1/P2 polish** — key‑bearing links, petnames, confusable + label policy.
