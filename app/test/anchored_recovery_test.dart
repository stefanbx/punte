// A2 anchored account recovery — live round-trip against the deployed relays, with THROWAWAY keys ONLY.
//
// It never touches the real wallet/seed: every keypair here is freshly random, so the anchor id is a
// throwaway account that no human owns. It proves the A2 publish/read path end to end:
//   1. build+sign an INCEPTION for a throwaway anchor, publishAnchorLog, GET it back -> resolves to o0
//   2. a pre-rotation ROTATION, publish, GET back -> now resolves to o1 (current key advanced), seq=1
//   3. a FORGED rotation (wrong next, and wrong signer) is REJECTED by the verifier
//
// HITS THE NETWORK (xchat-relay-1.fly.dev / xchat-alpha-node.fly.dev). Tagged 'live':
//   flutter test test/anchored_recovery_test.dart      (runs it)
//   flutter test --exclude-tags live                    (skips it)

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/anchor.dart';
import 'package:xchat/wallet.dart';

// 32 random bytes as hex — a throwaway Nano seed (identical shape to main.dart genSeed()).
String _rndSeed() {
  final r = math.Random.secure();
  return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  group('anchored recovery round-trip (live relays)', () {
    test('inception -> o0, rotation -> o1, forged rejected', () async {
      // ── throwaway identity (NOT the user's wallet) ──
      final root = NanoWallet(_rndSeed()); // the account key == anchor root
      final o0 = NanoWallet(_rndSeed()); // first operational key
      final o1 = NanoWallet(_rndSeed()); // pre-committed next (recovery) key

      // 1. inception: root delegates o0, pre-commits o1
      final inc = inception(root, o0.pub, commit(o1.pub), _now);
      await publishAnchorLog([inc]);

      var log = await fetchAnchorLog(root.account);
      expect(log.length, 1);
      var tip = verifyLog(log);
      expect(tip['op_key'], o0.pub, reason: 'inception must resolve to o0');
      expect(tip['seq'], 0);
      // ignore: avoid_print
      print('anchor=${root.account}\n  seq0 current op_key=${o0.pub}  (o0)');

      // 2. rotation: reveal o0? NO — reveal the pre-committed o1, commit fresh o2, self-signed by o1
      final o2 = NanoWallet(_rndSeed());
      final rot = rotationEvent(tip, o1, commit(o2.pub), _now);
      await publishAnchorLog([...log, rot]);

      log = await fetchAnchorLog(root.account);
      expect(log.length, 2);
      tip = verifyLog(log);
      expect(tip['op_key'], o1.pub, reason: 'after rotation the current key is o1');
      expect(tip['seq'], 1);
      // ignore: avoid_print
      print('  seq1 current op_key=${o1.pub}  (o1) — rotated, o0 retired');

      // 3a. FORGED rotation — WRONG NEXT: attacker reveals a key that was never pre-committed.
      final evil = NanoWallet(_rndSeed());
      final evilNext = NanoWallet(_rndSeed());
      final forgedWrongNext = rotationEvent(tip, evil, commit(evilNext.pub), _now);
      expect(() => verifyLog([...log, forgedWrongNext]), throwsA(isA<AnchorError>()),
          reason: 'a key that fails the pre-rotation commitment must be rejected');

      // 3b. FORGED rotation — WRONG SIGNER: reveals the correct o2 pub but is signed by someone else.
      final o3 = NanoWallet(_rndSeed());
      final good = rotationEvent(tip, o2, commit(o3.pub), _now); // properly reveals o2
      final wrongSigner = {
        ...good,
        'pub': evil.pub,
        'sig': evil.signMsg(eventCanon(good))['sig'], // valid sig, but by the wrong key
      };
      expect(() => verifyLog([...log, wrongSigner]), throwsA(isA<AnchorError>()),
          reason: 'a pre-rotation not self-signed by the revealed key must be rejected');

      // ignore: avoid_print
      print('  forged (wrong-next & wrong-signer) rejected by verifyLog');
    }, tags: 'live', timeout: const Timeout(Duration(seconds: 60)));
  });
}
