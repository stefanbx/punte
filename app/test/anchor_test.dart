// Live end-to-end verification of the anchored-naming resolver against the deployed relays.
//
// These tests HIT THE NETWORK (xchat-relay-1.fly.dev / xchat-alpha-node.fly.dev). They prove the Dart
// resolver reproduces anchor.py/gateway.py byte-for-byte: two already-published names resolve to their
// expected anchors + cids + Keel content, a TAMPERED blob is rejected on the sha256 check, and an
// unknown name errors instead of returning anything. Tagged 'live' so they can be skipped offline:
//   flutter test test/anchor_test.dart            (runs them)
//   flutter test --exclude-tags live              (skips them)

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:punte/anchor.dart';
import 'package:punte/wallet.dart';

const _counterAnchor = 'nano_1oecy7393u7g79wnun9i99c1fxum8kzg41xus9pr5kuzer7rbkehb5oj4yge';
const _counterCid =
    'sha256-c896992464c83762031e29c88507ecd895307baa89635d51af7b5ea879c26491';
const _greeterAnchor = 'nano_15d9f8hz889ju866qnoo8q78gyudnyxhq85azcfdmp4ik78r3gp5868np3ix';
const _greeterCid =
    'sha256-79a4faef4ec2653082d2bc799f593cb8569294d316b4d00265ebb8f36b408ce1';

void main() {
  group('resolveAnchor (live relays)', () {
    test('counter resolves to its anchor, cid and Keel content', () async {
      final r = await resolveAnchor('counter');
      expect(r.anchor, _counterAnchor);
      expect(r.contentCid, _counterCid);
      expect(r.currentKey.length, 64); // an operational pubkey (hex)
      expect(r.contentText, contains('fn view')); // the Keel program body
    }, tags: 'live', timeout: const Timeout(Duration(seconds: 60)));

    test('greeter resolves to its anchor, cid and Keel content', () async {
      final r = await resolveAnchor('greeter');
      expect(r.anchor, _greeterAnchor);
      expect(r.contentCid, _greeterCid);
      expect(r.contentText, contains('fn view'));
    }, tags: 'live', timeout: const Timeout(Duration(seconds: 60)));

    test('an unknown name errors (never returns content)', () async {
      expect(resolveAnchor('nope'), throwsA(isA<AnchorError>()));
    }, tags: 'live', timeout: const Timeout(Duration(seconds: 60)));

    test('a TAMPERED blob is rejected on the content-hash check', () async {
      // Real lease + real verified chain, but a blob whose bytes have one byte flipped: the sha256 no
      // longer equals the signed cid, so the resolver must throw rather than hand back the bytes.
      final client = _TamperingClient(cidToTamper: _counterCid);
      await expectLater(
        resolveAnchor('counter', client: client),
        throwsA(predicate(
            (e) => e is AnchorError && e.message.contains('content hash mismatch'))),
      );
    }, tags: 'live', timeout: const Timeout(Duration(seconds: 60)));
  });

  group('publisher signer (offline, pure)', () {
    // Build a full inception + pre-rotation chain with the signer half and prove verifyLog accepts it —
    // i.e. we construct exactly what the relay would accept, using only NanoWallet.signMsg.
    test('a self-built inception + rotation chain verifies', () {
      final root = NanoWallet('0' * 63 + '1');
      final op1 = NanoWallet('0' * 63 + '2');
      final op2 = NanoWallet('0' * 63 + '3');
      final ep1 = {'web': 'content:sha256-${'a' * 64}'};

      final e0 = inception(root, op1.pub, commit(op1.pub), 1000, endpoints: ep1);
      final e1 = rotationEvent(e0, op1, commit(op2.pub), 1001, endpoints: ep1);
      final e2 = rotationEvent(e1, op2, commit(NanoWallet('0' * 63 + '4').pub), 1002,
          endpoints: ep1);

      final tip = verifyLog([e2, e0, e1]); // out of order on purpose — verifyLog sorts by seq
      expect(tip['seq'], 2);
      expect(tip['op_key'], op2.pub);
      expect(pubToAddr(e0['pub'] as String), root.account);
    });

    test('a lease verifies under its root key', () {
      final root = NanoWallet('0' * 63 + '1');
      final lease = makeLease('myname', root, 1234);
      expect(verifyLease('myname', lease), root.account);
    });

    test('a tampered rotation (wrong revealed key) is rejected', () {
      final root = NanoWallet('0' * 63 + '1');
      final op1 = NanoWallet('0' * 63 + '2');
      final wrong = NanoWallet('0' * 63 + '9'); // not the committed next key
      final e0 = inception(root, op1.pub, commit(op1.pub), 1000);
      final bad = rotationEvent(e0, wrong, commit(wrong.pub), 1001);
      expect(() => verifyLog([e0, bad]), throwsA(isA<AnchorError>()));
    });
  });
}

/// An http.Client that proxies to the real relay but flips one byte of the named blob's content, so the
/// resolver receives a valid lease + chain but poisoned bytes. Everything else passes through unchanged.
class _TamperingClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final String cidToTamper;
  _TamperingClient({required this.cidToTamper});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final resp = await _inner.send(request);
    final isBlob = request.url.path.endsWith('/blob') &&
        request.url.queryParameters['cid'] == cidToTamper;
    if (!isBlob) return resp;
    final body = await resp.stream.bytesToString();
    final j = jsonDecode(body) as Map<String, dynamic>;
    final bytes = base64.decode(j['b64'] as String);
    bytes[0] ^= 0x01; // flip one byte -> sha256 no longer matches the cid
    j['b64'] = base64.encode(bytes);
    final tampered = utf8.encode(jsonEncode(j));
    return http.StreamedResponse(
      Stream.value(Uint8List.fromList(tampered)),
      resp.statusCode,
      contentLength: tampered.length,
      request: resp.request,
      headers: resp.headers,
      reasonPhrase: resp.reasonPhrase,
    );
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
