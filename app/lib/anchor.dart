// ANCHORED NAMING — client-side resolver/verifier + rotation signer (Dart).
//
// This is the on-device mirror of anchor/anchor.py + anchor/gateway.py: it takes a human name, fetches
// the signed lease and the KERI-style anchor event log from a relay, and VERIFIES every link itself so
// it can trust the tip key and the content bytes WITHOUT trusting the relay that served them. A resolver
// either trusts the tip or it doesn't — a silently-accepted bad event is exactly the failure the anchor
// primitive exists to stop, so every check here throws rather than degrades.
//
// ADDITIVE + FLAG-GATED. Nothing in the app imports this file yet; with kAnchoredEnabled=false the app is
// byte-for-byte unchanged. It reuses xchat's proven crypto and does NOT reinvent any of it:
//   * Ed25519-Blake2b signature VERIFY   -> NanoWallet.verifySig  (wallet.dart, the BigInt backend)
//   * signing (for the publisher part)    -> NanoWallet.signMsg
//   * pubkey -> nano_ address             -> NanoAccounts.createAccount (== xc_common.pub_to_addr)
//   * Blake2b-256                         -> nanodart Blake2b.digest256 (Nano's hash)
//   * content cids                        -> package:crypto sha256 (already a dependency)
// The only thing rebuilt here is the sig_canon STRING FORMAT (not crypto): byte-identical to
// NanoWallet.sigCanon / xc_common.sig_canon, replicated because that method is an instance method and the
// verifier has no wallet — keep it in lockstep with those two.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;
import 'package:nanodart/nanodart.dart'
    show Blake2b, NanoHelpers, NanoAccounts, NanoAccountType;

import 'wallet.dart';

/// The relays that serve leases/anchor-logs/blobs. Primary first, then fallback — exactly the two live
/// hosts the rest of the app already talks to.
const List<String> kAnchorRelays = [
  'https://xchat-relay-1.fly.dev',
  'https://xchat-alpha-node.fly.dev',
];

/// Any verification failure. Carries a human message naming the failing rule (mirrors anchor.py Invalid).
class AnchorError implements Exception {
  final String message;
  AnchorError(this.message);
  @override
  String toString() => 'AnchorError: $message';
}

/// A fully-verified resolution: the name, its stable anchor, the CURRENT operational key, and the
/// hash-verified content the tip points at. Never constructed unless every link checked out.
class AnchorResult {
  final String name;
  final String anchor;
  final String currentKey; // the tip operational public key (hex)
  final String contentCid; // 'sha256-<hex>'
  final Uint8List contentBytes; // bytes whose sha256 == contentCid
  final int seq; // tip sequence number
  final Map<String, dynamic> endpoints; // tip endpoints map
  const AnchorResult({
    required this.name,
    required this.anchor,
    required this.currentKey,
    required this.contentCid,
    required this.contentBytes,
    required this.seq,
    required this.endpoints,
  });
  String get contentText => utf8.decode(contentBytes);
}

// ───────────────────────────── canonical encodings (byte-for-byte with Python) ─────────────────────────

/// sig_canon preimage — identical to NanoWallet.sigCanon and xc_common.sig_canon: `xchat/sig/v2/<type>`
/// then each field length-prefixed by its UTF-8 byte count. Non-strings are str()'d (Dart .toString()).
String _sigCanon(String type, List<Object> fields) {
  var out = 'xchat/sig/v2/$type';
  for (final f in fields) {
    final s = f is String ? f : f.toString();
    out += '|${utf8.encode(s).length}:$s';
  }
  return out;
}

/// lease canon — gateway.py _lease_canon: sig_canon('anchor-lease', label, anchor, ts).
String leaseCanon(String label, String anchor, Object ts) =>
    _sigCanon('anchor-lease', [label, anchor, ts]);

/// anchor event canon — anchor.py _canon: sig_canon('anchor-evt', anchor, seq, prev, authority, op_key,
/// next, `<endpoints as compact sorted json>`, ts).
String eventCanon(Map<String, dynamic> e) => _sigCanon('anchor-evt', [
      e['anchor'] as Object,
      e['seq'] as Object,
      (e['prev'] ?? '') as Object,
      e['authority'] as Object,
      e['op_key'] as Object,
      e['next'] as Object,
      _canonicalJson(e['endpoints'] ?? <String, dynamic>{}),
      e['ts'] as Object,
    ]);

/// BLAKE2b-256 hex of a UTF-8 string — the event chaining hash (anchor.py event_hash).
String _blake2bHexOfString(String s) =>
    NanoHelpers.byteToHex(Blake2b.digest256([Uint8List.fromList(utf8.encode(s))])).toLowerCase();

/// BLAKE2b-256 hex of a hex-encoded pubkey — the pre-rotation commitment (anchor.py commit).
String commit(String pubHex) =>
    NanoHelpers.byteToHex(Blake2b.digest256([NanoHelpers.hexToBytes(pubHex)])).toLowerCase();

/// The BLAKE2b-256 hash of an event's canonical form (anchor.py event_hash).
String eventHash(Map<String, dynamic> e) => _blake2bHexOfString(eventCanon(e));

/// pubkey hex -> nano_ address (== xc_common.pub_to_addr; binds a signer's key to the anchor id).
String pubToAddr(String pubHex) => NanoAccounts.createAccount(NanoAccountType.NANO, pubHex);

/// Compact, key-sorted JSON matching Python json.dumps(x, sort_keys=True, separators=(',',':')) with
/// the default ensure_ascii=True (non-ASCII -> \uXXXX). The anchor event canon signs endpoints through
/// exactly this, so a byte for a byte here is a valid-signature-or-not there.
String _canonicalJson(Object? v) {
  final b = StringBuffer();
  _writeCanonicalJson(b, v);
  return b.toString();
}

void _writeCanonicalJson(StringBuffer b, Object? v) {
  if (v == null) {
    b.write('null');
  } else if (v is bool) {
    b.write(v ? 'true' : 'false');
  } else if (v is int) {
    b.write(v.toString());
  } else if (v is double) {
    // Python would render integral doubles as '1.0'; anchor endpoints never carry floats, but be honest.
    b.write(v == v.roundToDouble() && v.isFinite ? '${v.toInt()}.0' : v.toString());
  } else if (v is String) {
    _writeJsonString(b, v);
  } else if (v is List) {
    b.write('[');
    for (var i = 0; i < v.length; i++) {
      if (i > 0) b.write(',');
      _writeCanonicalJson(b, v[i]);
    }
    b.write(']');
  } else if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    b.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) b.write(',');
      _writeJsonString(b, keys[i]);
      b.write(':');
      _writeCanonicalJson(b, v[keys[i]]);
    }
    b.write('}');
  } else {
    throw AnchorError('non-JSON value in endpoints: ${v.runtimeType}');
  }
}

void _writeJsonString(StringBuffer b, String s) {
  b.write('"');
  for (final rune in s.runes) {
    switch (rune) {
      case 0x22:
        b.write('\\"');
        break;
      case 0x5c:
        b.write('\\\\');
        break;
      case 0x08:
        b.write('\\b');
        break;
      case 0x09:
        b.write('\\t');
        break;
      case 0x0a:
        b.write('\\n');
        break;
      case 0x0c:
        b.write('\\f');
        break;
      case 0x0d:
        b.write('\\r');
        break;
      default:
        if (rune < 0x20 || rune > 0x7e) {
          // ensure_ascii: escape control + all non-ASCII, as UTF-16 code units (matches Python).
          for (final u in String.fromCharCode(rune).codeUnits) {
            b.write('\\u');
            b.write(u.toRadixString(16).padLeft(4, '0'));
          }
        } else {
          b.writeCharCode(rune);
        }
    }
  }
  b.write('"');
}

// ───────────────────────────── PART A publisher: build + sign events/leases ─────────────────────────
// Enough to construct a log the relay would accept (inception + pre-rotation rotation + lease). No POST
// here — this is the signing half only, reusing NanoWallet.signMsg for the actual Ed25519-Blake2b.

/// Sign an event map (adds 'sig'/'pub') with the given wallet, over its canonical form.
Map<String, dynamic> _signEvent(Map<String, dynamic> e, NanoWallet signer) {
  final s = signer.signMsg(eventCanon(e));
  return {...e, 'sig': s['sig'], 'pub': s['pub']};
}

/// Event 0. The cold root [root] delegates to [opPub] and pre-commits [nextCommit] = commit(next op pub).
Map<String, dynamic> inception(
  NanoWallet root,
  String opPub,
  String nextCommit,
  int ts, {
  Map<String, dynamic>? endpoints,
}) =>
    _signEvent({
      'anchor': root.account,
      'seq': 0,
      'prev': '',
      'authority': 'root',
      'op_key': opPub,
      'next': nextCommit,
      'endpoints': endpoints ?? <String, dynamic>{},
      'ts': ts,
    }, root);

/// A pre-rotation rotation. Reveals [newOp] (whose pub must match the prior commitment) and SELF-signs it.
Map<String, dynamic> rotationEvent(
  Map<String, dynamic> prevEvent,
  NanoWallet newOp,
  String nextCommit,
  int ts, {
  Map<String, dynamic>? endpoints,
}) =>
    _signEvent({
      'anchor': prevEvent['anchor'],
      'seq': (prevEvent['seq'] as int) + 1,
      'prev': eventHash(prevEvent),
      'authority': 'pre-rotation',
      'op_key': newOp.pub,
      'next': nextCommit,
      'endpoints': endpoints ?? <String, dynamic>{},
      'ts': ts,
    }, newOp);

/// The cold-root escape hatch: re-establish a fresh operational key regardless of the pre-rotation chain.
Map<String, dynamic> rootRecover(
  Map<String, dynamic> prevEvent,
  NanoWallet root,
  String newOpPub,
  String nextCommit,
  int ts, {
  Map<String, dynamic>? endpoints,
}) =>
    _signEvent({
      'anchor': prevEvent['anchor'],
      'seq': (prevEvent['seq'] as int) + 1,
      'prev': eventHash(prevEvent),
      'authority': 'root',
      'op_key': newOpPub,
      'next': nextCommit,
      'endpoints': endpoints ?? <String, dynamic>{},
      'ts': ts,
    }, root);

/// A signed label -> anchor lease, authorised by the anchor's ROOT key (survives op-key rotation).
Map<String, dynamic> makeLease(String label, NanoWallet root, int ts) {
  final l = {'label': label, 'anchor': root.account, 'ts': ts};
  final s = root.signMsg(leaseCanon(label, root.account, ts));
  return {...l, 'sig': s['sig'], 'pub': s['pub']};
}

// ───────────────────────────── PART B resolver: verify a name end to end ─────────────────────────

/// Validate a whole anchor event log (anchor.py resolve) and return the tip event. Throws AnchorError on
/// the first rule violation, naming the failing event.
Map<String, dynamic> verifyLog(List<Map<String, dynamic>> log) {
  if (log.isEmpty) throw AnchorError('empty log');
  final ev = [...log]..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
  // contiguous, unique sequence from 0 — a fork (two events at one seq) is rejected, not merged.
  for (var i = 0; i < ev.length; i++) {
    if (ev[i]['seq'] != i) {
      throw AnchorError('non-contiguous/duplicate seq at index $i: got seq=${ev[i]['seq']}');
    }
  }

  final anchor = ev[0]['anchor'] as String;
  String? pending; // H(next expected operational key)
  var prevHash = '';

  for (final e in ev) {
    final seq = e['seq'];
    final pub = (e['pub'] ?? '') as String;
    final sig = (e['sig'] ?? '') as String;
    // signature must verify over the canonical event
    if (!NanoWallet.verifySig(pub, eventCanon(e), sig)) {
      throw AnchorError('seq $seq: bad signature');
    }
    // chain integrity: prev must be the hash of the previous event's canonical form
    if ((e['prev'] ?? '') != prevHash) {
      throw AnchorError('seq $seq: prev hash mismatch (log tampered or reordered)');
    }

    final authority = e['authority'];
    if (authority == 'root') {
      // inception or root override: signer must be the anchor's root key itself
      if (pubToAddr(pub) != anchor) {
        throw AnchorError('seq $seq: root event not signed by the anchor root key');
      }
    } else if (authority == 'pre-rotation') {
      if (pending == null) {
        throw AnchorError('seq $seq: pre-rotation before any commitment');
      }
      // THE PRE-ROTATION CHECK: the revealed key must match the digest committed last time.
      if (commit(e['op_key'] as String) != pending) {
        throw AnchorError(
            'seq $seq: revealed key does not match the pre-rotation commitment '
            '(a stolen current key cannot satisfy this)');
      }
      // and the event must be SELF-signed by that revealed key
      if (pub != e['op_key']) {
        throw AnchorError('seq $seq: pre-rotation not self-signed by the revealed key');
      }
    } else {
      throw AnchorError('seq $seq: unknown authority ${authority.toString()}');
    }

    pending = e['next'] as String;
    prevHash = eventHash(e);
  }
  return ev.last;
}

/// Verify a signed lease: it must be signed by the anchor's ROOT key (pub -> addr == anchor) over the
/// lease canon. Returns the anchor id, or throws.
String verifyLease(String name, Map<String, dynamic> lease) {
  final label = lease['label'] as String?;
  final anchor = lease['anchor'] as String?;
  final ts = lease['ts'];
  final pub = (lease['pub'] ?? '') as String;
  final sig = (lease['sig'] ?? '') as String;
  if (label == null || anchor == null || ts == null) {
    throw AnchorError('lease missing fields');
  }
  if (label != name) {
    throw AnchorError('lease label "$label" != requested name "$name"');
  }
  if (pubToAddr(pub) != anchor) {
    throw AnchorError('lease not signed by the anchor root key');
  }
  if (!NanoWallet.verifySig(pub, leaseCanon(label, anchor, ts as Object), sig)) {
    throw AnchorError('lease signature invalid');
  }
  return anchor;
}

/// Resolve a human [name] to hash-verified content, trusting nothing the relay says without checking it.
/// Throws AnchorError on any verification failure — it NEVER returns unverified content.
Future<AnchorResult> resolveAnchor(
  String name, {
  http.Client? client,
  List<String> relays = kAnchorRelays,
}) async {
  final c = client ?? http.Client();
  final ownClient = client == null;
  try {
    // 1. lease -> verify -> anchor id
    final leaseResp = await _getJson(c, relays, '/lease?label=${Uri.encodeQueryComponent(name)}');
    final lease = leaseResp['lease'];
    if (lease == null) {
      throw AnchorError('no lease for "$name" (unclaimed or unknown)');
    }
    final anchor = verifyLease(name, (lease as Map).cast<String, dynamic>());

    // 2. anchor log -> verify KERI chain -> tip
    final anchorResp =
        await _getJson(c, relays, '/anchor?id=${Uri.encodeQueryComponent(anchor)}');
    final rawLog = anchorResp['log'];
    if (rawLog is! List || rawLog.isEmpty) {
      throw AnchorError('empty or missing anchor log for $anchor');
    }
    final log = rawLog.map((e) => (e as Map).cast<String, dynamic>()).toList();
    final tip = verifyLog(log);
    if (tip['anchor'] != anchor) {
      throw AnchorError('anchor log id mismatch');
    }
    final currentKey = tip['op_key'] as String;
    final endpoints = ((tip['endpoints'] ?? <String, dynamic>{}) as Map).cast<String, dynamic>();

    // 3. tip endpoints -> content cid
    final web = (endpoints['web'] ?? '') as String;
    if (!web.startsWith('content:')) {
      throw AnchorError('tip endpoint is not content (web="$web")');
    }
    final cid = web.substring('content:'.length);
    if (!cid.startsWith('sha256-')) {
      throw AnchorError('unsupported content cid "$cid"');
    }

    // 4. blob -> base64-decode -> assert sha256(bytes) == cid
    final blobResp = await _getJson(c, relays, '/blob?cid=${Uri.encodeQueryComponent(cid)}');
    final b64 = blobResp['b64'];
    if (b64 is! String) throw AnchorError('blob missing for $cid');
    final bytes = base64.decode(b64);
    final got = 'sha256-${sha256.convert(bytes).toString()}';
    if (got != cid) {
      throw AnchorError('content hash mismatch: named $cid, got $got');
    }

    return AnchorResult(
      name: name,
      anchor: anchor,
      currentKey: currentKey,
      contentCid: cid,
      contentBytes: Uint8List.fromList(bytes),
      seq: tip['seq'] as int,
      endpoints: endpoints,
    );
  } finally {
    if (ownClient) c.close();
  }
}

/// GET a JSON object from the first relay that answers 2xx; throws AnchorError if none do.
Future<Map<String, dynamic>> _getJson(
    http.Client c, List<String> relays, String path) async {
  Object? lastErr;
  for (final base in relays) {
    try {
      final r = await c
          .get(Uri.parse('$base$path'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode ~/ 100 != 2) {
        lastErr = AnchorError('$base$path -> HTTP ${r.statusCode}');
        continue;
      }
      final j = jsonDecode(r.body);
      if (j is! Map<String, dynamic>) {
        lastErr = AnchorError('$base$path -> non-object JSON');
        continue;
      }
      return j;
    } catch (e) {
      lastErr = e;
    }
  }
  throw AnchorError('all relays failed for $path: $lastErr');
}
