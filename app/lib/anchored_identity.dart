// ANCHORED NAMING — Phase A3 (resolver only): "honor the current key" for an account's identity.
//
// ADDITIVE + FLAG-GATED SUBSTRATE. This file adds NO UI and touches NO signing/publishing/verification on
// the core path. It only answers one question, cheaply and safely: "does this account have a VERIFIED
// recoverable anchor, and — per its own KERI chain — what is its CURRENT operational key and rotation
// generation?" That is the on-device meaning of A3: the app derives the account's current key from the
// anchor chain instead of assuming the raw account key is the only truth.
//
// It is deliberately the resolver ONLY. The protective step where the network SIGNS with and VERIFIES the
// operational key (and rejects a rotated-away key) is a coordinated signing-path change requiring universal
// client rollout — out of scope here. This layer is the substrate that step would build on.
//
// Design rules (same discipline as A2/B3/B4):
//   * FAIL-SAFE   — any network/verify failure yields AnchorIdentity.none (never an exception, never a
//                   false "anchored" claim). A transient network error is NOT cached, so a later lookup can
//                   still succeed; a definitive answer (no log, or an invalid/tampered log) IS cached.
//   * NON-BLOCKING— resolution is async and cached per account for the session, with in-flight de-dup so
//                   concurrent callers (e.g. many post cards for the same author) share one request.
//   * READ-ONLY   — uses only anchor.dart's fetchAnchorLog + verifyLog over the existing /anchor endpoint.

import 'package:http/http.dart' as http;

import 'anchor.dart';

/// The verified anchor state of one account. `hasAnchor` is only ever true when a full KERI-chain
/// verification passed, so `currentKey`/`seq` can be trusted when it is.
class AnchorIdentity {
  final String account; // the queried account (== the anchor id when anchored)
  final bool hasAnchor; // a VERIFIED anchor log exists for this account
  final String? currentKey; // tip operational public key (hex) — the CURRENT key per the chain
  final int seq; // tip sequence: 0 = inception (enabled, never rotated), N = rotated N times; -1 = none

  const AnchorIdentity._({
    required this.account,
    required this.hasAnchor,
    required this.currentKey,
    required this.seq,
  });

  /// No verified anchor for this account (unenrolled, empty, or unverifiable).
  factory AnchorIdentity.none(String account) =>
      AnchorIdentity._(account: account, hasAnchor: false, currentKey: null, seq: -1);

  /// A verified anchor: [currentKey] is the tip operational key, [seq] the rotation generation.
  factory AnchorIdentity.anchored(String account, String currentKey, int seq) =>
      AnchorIdentity._(account: account, hasAnchor: true, currentKey: currentKey, seq: seq);

  /// How many times the operational key has been rotated (seq 0 = enabled but never rotated).
  int get rotations => hasAnchor ? seq : 0;

  @override
  String toString() => hasAnchor
      ? 'AnchorIdentity(anchored $account, key=${currentKey!.substring(0, 8)}…, seq=$seq)'
      : 'AnchorIdentity(none $account)';
}

/// A session cache resolving accounts to their verified anchor identity. Best-effort and fail-safe: a
/// lookup NEVER throws and NEVER blocks a caller on more than one shared network request per account.
class AnchorIdentityCache {
  AnchorIdentityCache._();
  static final AnchorIdentityCache I = AnchorIdentityCache._();

  final Map<String, AnchorIdentity> _cache = {};
  final Map<String, Future<AnchorIdentity>> _inflight = {};

  /// The cached identity for [account], if one has already resolved this session; else null. Synchronous —
  /// for a widget that wants to render the badge immediately when it's known and trigger [identify] when not.
  AnchorIdentity? peek(String account) => _cache[account];

  /// Resolve [account]'s anchor identity, using the session cache and de-duplicating concurrent lookups.
  Future<AnchorIdentity> identify(
    String account, {
    http.Client? client,
    List<String> relays = kAnchorRelays,
  }) {
    final cached = _cache[account];
    if (cached != null) return Future.value(cached);
    final pending = _inflight[account];
    if (pending != null) return pending;
    final f = _resolve(account, client, relays);
    _inflight[account] = f;
    return f;
  }

  Future<AnchorIdentity> _resolve(
      String account, http.Client? client, List<String> relays) async {
    try {
      List<Map<String, dynamic>> log;
      try {
        log = await fetchAnchorLog(account, client: client, relays: relays);
      } catch (_) {
        // Transient (network/relay) failure — do NOT cache, so a retry can still find the anchor.
        return AnchorIdentity.none(account);
      }
      if (log.isEmpty) {
        // Definitive: this account has never published an anchor.
        return _store(account, AnchorIdentity.none(account));
      }
      try {
        final tip = verifyLog(log);
        if (tip['anchor'] != account) {
          return _store(account, AnchorIdentity.none(account));
        }
        return _store(
            account, AnchorIdentity.anchored(account, tip['op_key'] as String, tip['seq'] as int));
      } catch (_) {
        // A log exists but doesn't verify (invalid/tampered) — definitively not a trustable anchor.
        return _store(account, AnchorIdentity.none(account));
      }
    } finally {
      _inflight.remove(account);
    }
  }

  AnchorIdentity _store(String account, AnchorIdentity id) {
    _cache[account] = id;
    return id;
  }

  /// Drop [account]'s cached entry so the next [identify] re-resolves (e.g. after the user rotates).
  void forget(String account) => _cache.remove(account);

  /// Clear everything (e.g. on wallet switch).
  void clear() => _cache.clear();
}
