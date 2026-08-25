// A3 resolver tests. Mostly OFFLINE (MockClient serving real signed anchor logs) so they're
// deterministic; one 'live' test hits the deployed relays. Run: flutter test test/anchored_identity_test.dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:punte/anchor.dart';
import 'package:punte/anchored_identity.dart';
import 'package:punte/wallet.dart';

// Throwaway keypairs — NOT any real wallet.
final _root = NanoWallet('a1' * 32);
final _op0 = NanoWallet('b2' * 32);
final _op1 = NanoWallet('c3' * 32);
final _op2 = NanoWallet('d4' * 32);
const _ts = 1700000000;

Map<String, dynamic> get _ev0 => inception(_root, _op0.pub, commit(_op1.pub), _ts);
Map<String, dynamic> _ev1(Map<String, dynamic> ev0) => rotationEvent(ev0, _op1, commit(_op2.pub), _ts);

/// A MockClient that serves [log] for GET /anchor and counts how many times it was called.
({http.Client client, int Function() calls}) _logServer(List<Map<String, dynamic>> log) {
  var n = 0;
  final c = MockClient((req) async {
    if (req.url.path == '/anchor') {
      n++;
      return http.Response(jsonEncode({'log': log}), 200);
    }
    return http.Response('not found', 404);
  });
  return (client: c, calls: () => n);
}

void main() {
  setUp(() => AnchorIdentityCache.I.clear());

  test('anchored account (inception only) → current key = op0, seq 0', () async {
    final s = _logServer([_ev0]);
    final id = await AnchorIdentityCache.I.identify(_root.account, client: s.client);
    expect(id.hasAnchor, isTrue);
    expect(id.account, _root.account);
    expect(id.currentKey, _op0.pub);
    expect(id.seq, 0);
    expect(id.rotations, 0);
    // cached now — peek is populated and no further network call happens
    expect(AnchorIdentityCache.I.peek(_root.account)?.currentKey, _op0.pub);
    await AnchorIdentityCache.I.identify(_root.account, client: s.client);
    expect(s.calls(), 1); // second identify served from cache
  });

  test('after one rotation → current key = op1, seq 1, rotations 1', () async {
    final ev0 = _ev0;
    final s = _logServer([ev0, _ev1(ev0)]);
    final id = await AnchorIdentityCache.I.identify(_root.account, client: s.client);
    expect(id.hasAnchor, isTrue);
    expect(id.currentKey, _op1.pub); // the revealed, rotated-to operational key
    expect(id.seq, 1);
    expect(id.rotations, 1);
  });

  test('no anchor (empty log) → none, and it IS cached (definitive)', () async {
    final s = _logServer([]);
    final id = await AnchorIdentityCache.I.identify(_root.account, client: s.client);
    expect(id.hasAnchor, isFalse);
    expect(id.seq, -1);
    expect(AnchorIdentityCache.I.peek(_root.account)?.hasAnchor, isFalse); // cached
  });

  test('transient failure (all relays 500) → none, NOT cached (retryable)', () async {
    final c = MockClient((req) async => http.Response('boom', 500));
    final id = await AnchorIdentityCache.I.identify(_root.account, client: c);
    expect(id.hasAnchor, isFalse);
    expect(AnchorIdentityCache.I.peek(_root.account), isNull); // not cached → a later lookup can succeed
  });

  test('a log whose tip anchor ≠ the queried account → none', () async {
    final s = _logServer([_ev0]); // this log is for _root.account
    final id = await AnchorIdentityCache.I.identify(_op2.account, client: s.client); // query a different acct
    expect(id.hasAnchor, isFalse);
  });

  test('concurrent lookups de-dup to a single network request', () async {
    final s = _logServer([_ev0]);
    final results = await Future.wait([
      AnchorIdentityCache.I.identify(_root.account, client: s.client),
      AnchorIdentityCache.I.identify(_root.account, client: s.client),
      AnchorIdentityCache.I.identify(_root.account, client: s.client),
    ]);
    expect(results.every((r) => r.hasAnchor), isTrue);
    expect(s.calls(), 1); // one shared in-flight request, not three
  });

  test('live: the counter anchor resolves to a verified identity', () async {
    const counterAnchor =
        'nano_1oecy7393u7g79wnun9i99c1fxum8kzg41xus9pr5kuzer7rbkehb5oj4yge';
    final id = await AnchorIdentityCache.I.identify(counterAnchor);
    expect(id.hasAnchor, isTrue);
    expect(id.currentKey?.length, 64);
    expect(id.seq, greaterThanOrEqualTo(0));
  }, tags: 'live', timeout: const Timeout(Duration(seconds: 60)));
}
