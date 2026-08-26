# Punte × Octad — Content Pages integration spec (v0.1, draft)

**Status:** design draft. Spans two repos: **Punte** (`~/xchat-alpha`, the Flutter app + relays)
and **Octad** (`~/keel-anchor`, the sovereign renderer/authoring stack). Nothing here is built yet.

## 0. Goal & non-goals

**Goal.** Let a Punte post be a **Octad page** — a *verified, rich* content document (layout,
styling, images, forms, later mini-apps) instead of plain text — rendered in the app with the
same content-integrity + zero-JS safety the games hub already relies on, and authored with the
Octad dialect/IDE we just built.

**Non-goals (explicitly out of scope).**
- Rewriting the Punte **app shell** in Octad. The shell (keys, relays, wallet, camera, push,
  storage) stays Flutter — it needs ambient capabilities Octad deliberately forbids. Octad is the
  **content/render layer only**, exactly as `browser_app.kl` (native, trusted) hosts sandboxed
  Octad *content* in Octad's own browser.
- A native mobile Octad renderer (Level C below) — deferred; the WebView path ships first.
- Turning the arcade games into Octad pages. Games are interactive JS/canvas mini-apps (a
  different content type); Octad content pages are **zero-JS verified documents**.

## 1. Trust model — three levels, ship A → target B → defer C

An Octad page has two artifacts: the signed **source** (the bundled `.kl`, cid `S`) and the
**rendered zero-JS HTML** (cid `H`). Who renders `S→H`, and what the client trusts, defines the level.

- **Level A — content-integrity (SHIP FIRST).** Content-address the **rendered HTML** blob `H`
  (exactly like games today). App fetches `H` by cid via `/api/media?cid=`, renders in a
  locked-down WebView. Trust = cid integrity + **zero-JS** (render_html emits no `<script>`, so
  the blob cannot execute) + WebView sandbox. Weaker than full verify-then-run (you trust that
  `H` is what the author published, not that it derived from a signed Octad source), but strictly
  **safer than the current games** (which run arbitrary JS). Ships on the existing app with
  near-zero new native work.
- **Level B — attested render (TARGET).** Content-address the signed **source** `S` (author signs
  it as a Punte event). Independent attestors run `keel … render_html` on `S` and attest
  **"source S renders to HTML H"** — the *identical* K-of-N reproducible-build model Punte already
  specs for releases (whitepaper §"Plural attestors (K-of-N)"; `deploy/reproduce/`). The client
  accepts `H` iff: (a) the author signed `S`, and (b) ≥K user-chosen attestors bind `S→H`. No
  keel runtime on the phone; full chain of trust; reuses an existing mechanism.
- **Level C — native client render (DEFER).** The app renders `S→UiNode→native` itself (a Dart
  port of `render_html`/the ~15-primitive renderer, or an embedded keel runtime). Removes the
  WebView. Big lift (WF-5-mobile). Honestly may never be necessary if B is solid.

**Decision:** build **A** now (rich zero-JS pages in the WebView), wire **B** as the trust upgrade
(reuse the reproduce/attestor tooling), leave **C** as a future track.

## 2. The content unit — a `page` event

Reuse the existing `Post` event model (`app/lib/main.dart:1229`, `kind ∈ {post,photo,poll,article,…}`).
Add **`kind: 'page'`**. Its payload references the artifacts by cid (no inline HTML in the event):

```
Post{ kind:'page', account, handle, ts,
      title,                       // feed-card title (plain text, unstyled)
      html_cid: "sha256-…",        // the rendered zero-JS HTML blob (Level A trust unit)
      src_cid:  "sha256-…",        // the signed bundled Octad source (Level B trust unit)
      attest:   [ …optional K-of-N render attestations… ],  // Level B
      preview:  "…120 chars plain text…" }                  // feed fallback + a11y
```
Signed on-device with the existing `postEventMsg`/`signMsg` path (main.dart:2034) — a `page` event
is just another signed event on the relays. Published like any post (`/api/post`), artifacts pushed
as content-addressed blobs via the existing `/api/blob_put` (main.dart:2788).

## 3. Authoring & publish flow (reuses everything we just built)

```
author writes a page in the Octad dialect  (dialect.kl / ide_app.kl live preview — WF-4.1/4.2)
      │  transpile
      ▼
plain Foundation Octad  (view/update/init over the UiNode vocabulary)
      │  kl_bundle  (bundle.kl — inline ui.kl+kit into ONE self-contained blob, WF-3.4)
      ▼
signed source blob  S = sha256(bundle)      ← author signs S (Punte key)
      │  keel render_html  (render_html.kl → zero-JS HTML; images inlined as data: URIs, §5)
      ▼
rendered HTML blob  H = sha256(html)
      │  publish
      ▼
POST /api/blob_put  S  and  H     +     sign & POST a `page` event referencing {html_cid:H, src_cid:S}
      (Level B: attestors independently render S→H and publish S→H attestations)
```
Publishing runs through the **existing** Punte pipeline (blob_put + signed event). The **only new
backend** is `/api/media?cid=` already resolving these blobs (it does — same path games use).

## 4. App-side rendering (extend the games WebView path)

The games already do fetch-by-cid → `loadHtmlString` (`main.dart:1792` gameHtml, `:10951` WebView).
A page renderer is a sibling of that, hardened for untrusted zero-JS content:

1. `media(html_cid)` → the HTML bytes (verify sha256 == cid before use).
2. **Enforce zero-JS**: reject the blob if it contains a `<script`, `on*=` handler, `javascript:`
   URL, or external `src/href` to a non-`data:`/non-`knot:` scheme (render_html never emits these;
   this is the belt-and-braces gate for a Level-A blob whose provenance isn't yet attested).
3. Render in a WebView with a strict CSP meta: `default-src 'none'; img-src data:; style-src
   'unsafe-inline'; script-src 'none'; connect-src 'none'` — no script, no network, images only
   from inlined `data:` URIs.
4. **Navigation is intercepted natively** (`onNavigationRequest`): the WebView NEVER navigates
   itself. Links use app schemes:
   - `punte://page/<name-or-cid>` → resolve + load that page (Octad `Link` lowers to this).
   - `punte://acct/<account>` / `@handle` → open the profile natively.
   - `punte://tip/<account>` , `punte://follow/<account>` → native tip/follow action (the app owns
     the wallet + social graph; the page can only *request* via a link, never execute).
   Everything else is denied.

**Feed integration.** A `page` post renders in the timeline as a **card** (title + preview + a
"rich page" affordance); tapping opens the full WebView render. Reuses the existing post-card +
detail routing; the card never runs the page (preview text only), so scrolling the feed is cheap.

## 5. Images & assets — content-addressed, inlined (no WebView network)

Octad's model forbids arbitrary-URL fetch. A page's `Img` node carries a **cid**, not a URL. At
render/publish time the pipeline resolves each `Img` cid and **inlines it as a `data:` URI** into
the HTML, so `H` is fully self-contained and the WebView makes **zero network requests**
(`connect-src 'none'`, `img-src data:`). Trade-off: `H` includes its images (bigger blob) — fine
for posts; for image-heavy pages, Level C native render could fetch-by-cid instead. This keeps the
Level-A blob a single verifiable unit and matches the "content-addressed, never a URL" invariant.

## 6. Interactivity — static first, then a native re-render bridge

- **Phase 1 (static):** `view(state)` with the initial state → one HTML render. Perfect for
  rich posts, announcements, profiles, docs, changelogs. No `update`/effects at runtime.
- **Phase 2 (interactive):** buttons/forms/polls. A page ships its Octad `update` logic; a button
  in the rendered HTML is a `punte://ev/<n>` link the app intercepts → the app asks a **render
  service** (or a bundled keel step) to compute `update(state, n, value)` → next state → re-render
  → reload the WebView. This is the `serve_anchor_live.kl` server-authoritative model, but
  **client-mediated** (the app is the loop, the relay/render-service is stateless). Polls map
  naturally onto the existing `kind:'poll'` tallying. Gated on a reachable render service (Level B
  attestors can double as renderers) — a real dependency, flag it.
- **Effects** (`fetch NAME`, `every Ns`) degrade exactly as documented in WEB_PARITY_SPEC_2 §1.9
  (fetch = resolve another verified page; timers → poll). Interactive Octad pages are thus
  "server-round-trip" interactive, not 60fps — appropriate for content, not for the arcade games.

## 7. Security summary (what makes this safe)

- **Zero-JS**: render_html emits no script; the app additionally *gates* on it (step 4.2) and pins
  a no-script CSP. A page cannot run code, period.
- **No ambient authority**: no network from the WebView (`connect-src 'none'`), images inlined,
  navigation intercepted. A page can only *request* app actions (tip/follow/open) via intercepted
  links — the app decides.
- **Integrity**: every artifact is fetched by cid and hash-checked (Level A). Level B adds
  author-signature over the source + K-of-N attestation that `S→H`.
- **Publish-time caps gate**: the source is bundled + `br_scan_caps`/`br_scan_imports`-gated (the
  Octad WF-3.4/Foundation gates) before it's a page — so even the *source* can't carry denied
  capability tokens or unbundled imports.

## 8. Reuse map (little is new)

| Need | Reused from |
|---|---|
| Author + live preview | Octad `dialect.kl`, `ide_app.kl` (WF-4.1/4.2) |
| One self-contained verified blob | Octad `bundle.kl` `kl_bundle` (WF-3.4) |
| Octad → zero-JS HTML | Octad `render_html.kl` |
| Fetch blob by cid | Punte `media(cid)` / `/api/media?cid=` |
| Render HTML in-app | Punte WebView (`loadHtmlString`, the games path) |
| Publish a blob | Punte `/api/blob_put` |
| Signed content event | Punte `Post` + `postEventMsg`/`signMsg`, new `kind:'page'` |
| Source→HTML trust (Level B) | Punte K-of-N reproducible-build attestation (`deploy/reproduce/`, whitepaper §) |
| Tips / follow / profile from a page | Punte native, via intercepted `punte://` links |

**Genuinely new:** the `page` post kind + card/detail UI; the zero-JS gate + CSP WebView config;
the `punte://` link scheme + navigation interceptor; the publish glue (dialect→bundle→render_html
→two blobs→event); and (Phase 2) the client-mediated re-render bridge.

## 9. Phasing

- **P1 — static pages, Level A (proof).** Author one real page in the Octad dialect (e.g. a styled
  Punte **announcement / changelog** or a rich **profile page**), publish it, render it in-app as a
  `page` post. Ships on the current app; proves the whole spine. *Smallest end-to-end slice.*
- **P2 — Level B trust.** Wire the author-signature over `S` + the K-of-N `S→H` attestation
  (reuse `deploy/reproduce/`), and the client's accept-if-≥K check. Now it's true verify-then-run
  content, no phone-side keel runtime.
- **P3 — interactive pages.** The client-mediated re-render bridge (forms/polls/buttons) via a
  render service. Gated on that service.
- **P4 — native mobile render (Level C), optional.** Drop the WebView; a Dart/native Octad
  renderer. Only if the WebView path proves limiting.

## 10. Open decisions (owner)

1. **Render location for Level B/interactive:** a hosted render service (who runs it, trust?) vs.
   attestor-run render vs. eventual on-device (Level C). Default: attestors double as renderers.
2. **`Img` inlining vs. fetch-by-cid** for image-heavy pages (blob size vs. WebView network).
   Default: inline for P1, revisit at P3/P4.
3. **Do page events count toward the feed/tip economy** like normal posts (repost shares, tips)?
   Likely yes — a `page` is just a richer post. Confirm.
4. **Cross-repo build:** the publish pipeline needs the `keel` toolchain (macOS ARM64) at publish
   time. Fine for authors on Mac / a CI publisher; note it (the phone never needs keel at Levels A/B).
```
