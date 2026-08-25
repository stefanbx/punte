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

### P3 — the fork / global‑uniqueness problem (the hard one)
No fully‑sovereign design gives global, authority‑free, unique human names. Offer a layered answer:

- **[relay] Surface disagreement, never hide it.** When the browser resolves a name, it queries *multiple*
  relays; if they return **different anchors** for the same label, show a “name is contested” warning and
  list the candidates with their fingerprints. A fork becomes visible instead of silently resolving to
  whichever relay answered first.
- **[spec] Deterministic tie‑break with anti‑backdate.** Move `accept_lease` from *first‑received* to
  *earliest‑valid‑ts wins*, where the lease preimage must include a **recent witness** (a recent ledger
  block hash or a relay‑countersigned receive receipt) so a claimant cannot fabricate an earlier ts than a
  known‑recent event. This lets independently‑forked relays **converge** on sync instead of diverging.
  Cost: a weak, bounded witness dependency — documented, not hidden.
- **[spec, optional] A canonical global namespace as an opt‑in layer.** For those who want one true
  `alice`, define a registry with real ordering — Harberger‑lease auction or stake‑ranked claim on a chain
  the client can verify. This is **opt‑in**: the base system stays petname‑first; the registry is just one
  more verifiable source, never the root of trust.

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
P0 (key display + TOFU) → P1 (key‑bearing links + petnames) → P2 (confusable warning + label policy) →
P3 (fork surfacing, then the ts/witness tie‑break, then the optional registry). P0 delivers most of the
real‑world protection for the least code.
