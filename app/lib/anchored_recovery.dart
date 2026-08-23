// ANCHORED ACCOUNT RECOVERY — Phase A2 UI (recoverable-identity record + rotate/recover flow).
//
// ADDITIVE + FLAG-GATED. This whole file is dead code unless kAnchoredEnabled is true: nothing imports
// AnchoredRecoveryScreen except behind an `if (kAnchoredEnabled)` guard in main.dart, so with the flag
// false the app is byte-for-byte unchanged. It does NOT change how xchat signs posts or how other
// clients verify — that is A3. A2 only publishes the account's KERI-style anchor log and lets the user
// rotate the operational key away from a compromised device while the account address + handle survive.
//
// The account's Nano key (== gWallet, the identity) is the ANCHOR ROOT. It delegates a rotatable
// OPERATIONAL key with pre-rotation: each event commits blake2b(next op pub), and a rotation reveals
// that pre-committed next key and self-signs. A stolen CURRENT key cannot rotate — only the holder of
// the pre-committed NEXT secret can. That NEXT secret is the "recovery key" we back up to the user.
//
// It reuses the app's own primitives and adds no heavy deps:
//   * event build/sign + chain verify  -> anchor.dart (inception / rotationEvent / commit / verifyLog)
//   * read/publish the log             -> anchor.dart (fetchAnchorLog / publishAnchorLog)
//   * operational keypairs             -> NanoWallet(seed) (wallet.dart), seeds from genSeed() (main.dart)
//   * secret storage                   -> FlutterSecureStorage, the SAME keystore WalletStore uses
//   * theme                            -> kBg/kText/kAccent/… from main.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'anchor.dart';
import 'main.dart'
    show kBg, kCard, kLine, kText, kDim, kAccent, gWallet, genSeed;
import 'wallet.dart';

// ───────────────────────────── operational-key state storage ─────────────────────────────
//
// MIRRORS WalletStore (main.dart): the operational-key state is a SECRET (the pre-committed next key IS
// the recovery secret — anyone with it can rotate the account away from you), so it lives in the SAME
// platform keystore the wallet seed does — Android EncryptedSharedPreferences (master key in the
// Keystore) / iOS Keychain — never in plaintext SharedPreferences. Web has no keystore (see WalletStore),
// so on web it falls back to SharedPreferences exactly as the seed does; the recovery-key backup shown to
// the user is the real durable copy regardless.

/// Persisted per-account: current operational key seed, the pre-committed NEXT (recovery) key seed, the
/// anchor id (== account address) and the tip sequence. Seeds (not derived privs) so a NanoWallet can be
/// rebuilt from them to sign the next rotation.
class AnchorOpState {
  final String anchor; // == account nano_ address (the anchor root / id)
  final int seq; // tip sequence number of the published log
  final String opSeed; // current operational key seed (64 hex)
  final String nextSeed; // PRE-COMMITTED next key seed — the recovery secret (64 hex)
  const AnchorOpState({
    required this.anchor,
    required this.seq,
    required this.opSeed,
    required this.nextSeed,
  });

  Map<String, dynamic> toJson() =>
      {'anchor': anchor, 'seq': seq, 'op_seed': opSeed, 'next_seed': nextSeed};
  factory AnchorOpState.fromJson(Map<String, dynamic> j) => AnchorOpState(
        anchor: j['anchor'] as String,
        seq: j['seq'] as int,
        opSeed: j['op_seed'] as String,
        nextSeed: j['next_seed'] as String,
      );

  NanoWallet get op => NanoWallet(opSeed);
  NanoWallet get next => NanoWallet(nextSeed);
}

class AnchorKeyStore {
  // Keyed by account so switching/restoring a wallet never reads another account's op-key state.
  static String _key(String account) => 'xchat_anchor_op:$account';
  static const _secure = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true));
  static const bool _isWeb = bool.fromEnvironment('dart.library.js_util');

  static Future<AnchorOpState?> get(String account) async {
    String? raw;
    if (_isWeb) {
      raw = (await SharedPreferences.getInstance()).getString(_key(account));
    } else {
      raw = await _secure.read(key: _key(account));
    }
    if (raw == null || raw.isEmpty) return null;
    return AnchorOpState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  static Future<void> save(AnchorOpState s) async {
    final raw = jsonEncode(s.toJson());
    if (_isWeb) {
      await (await SharedPreferences.getInstance()).setString(_key(s.anchor), raw);
      return;
    }
    await _secure.write(key: _key(s.anchor), value: raw);
  }
}

// ───────────────────────────── the recovery screen ─────────────────────────────

class AnchoredRecoveryScreen extends StatefulWidget {
  const AnchoredRecoveryScreen({super.key});
  @override
  State<AnchoredRecoveryScreen> createState() => _AnchoredRecoveryScreenState();
}

class _AnchoredRecoveryScreenState extends State<AnchoredRecoveryScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  AnchorOpState? _state; // null == recovery not yet enabled for this account
  String? _backupSeed; // the recovery (next) key to write down, shown after enable/rotate
  String _backupLabel = '';

  NanoWallet? get _root => gWallet;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final root = _root;
    if (root == null) {
      setState(() {
        _loading = false;
        _error = 'No account loaded.';
      });
      return;
    }
    final s = await AnchorKeyStore.get(root.account);
    if (!mounted) return;
    setState(() {
      _state = s;
      _loading = false;
    });
  }

  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<void> _enable() async {
    final root = _root;
    if (root == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // o0 = the first operational key; o1 = the pre-committed next (recovery) key.
      final o0 = NanoWallet(genSeed());
      final o1 = NanoWallet(genSeed());
      final inc = inception(root, o0.pub, commit(o1.pub), _now);
      await publishAnchorLog([inc]);
      final st = AnchorOpState(
          anchor: root.account, seq: 0, opSeed: o0.seed, nextSeed: o1.seed);
      await AnchorKeyStore.save(st);
      if (!mounted) return;
      setState(() {
        _state = st;
        _backupSeed = o1.seed; // the recovery secret — user must write it down
        _backupLabel = 'Account recovery is on. Back up your recovery key.';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not enable recovery: $e';
        _busy = false;
      });
    }
  }

  Future<void> _rotate() async {
    final root = _root;
    final st = _state;
    if (root == null || st == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Fetch the live log and verify the chain so we rotate on top of the real tip (not a stale one).
      final log = await fetchAnchorLog(st.anchor);
      if (log.isEmpty) {
        throw AnchorError('no published anchor log found for this account');
      }
      final tip = verifyLog(log); // throws if the relay served a tampered chain
      // Reveal the pre-committed next key (o1) and commit a fresh next (o2). rotationEvent self-signs
      // with o1; the verifier requires commit(o1.pub) == the tip's pending commitment.
      final o1 = st.next;
      final o2 = NanoWallet(genSeed());
      final rot = rotationEvent(tip, o1, commit(o2.pub), _now);
      await publishAnchorLog([...log, rot]);
      final next = AnchorOpState(
          anchor: st.anchor,
          seq: (tip['seq'] as int) + 1,
          opSeed: o1.seed, // o1 is now the current operational key
          nextSeed: o2.seed); // o2 is the new pre-committed recovery key
      await AnchorKeyStore.save(next);
      if (!mounted) return;
      setState(() {
        _state = next;
        _backupSeed = o2.seed;
        _backupLabel = 'Key rotated. The old key is retired — back up your NEW recovery key.';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not rotate: $e';
        _busy = false;
      });
    }
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(milliseconds: 1200),
        backgroundColor: kCard,
        content: Text('📋 $what copied')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        iconTheme: const IconThemeData(color: kText),
        title: const Text('Account recovery',
            style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: kAccent))
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _body(),
                ),
              ),
      ),
    );
  }

  List<Widget> _body() {
    final root = _root;
    if (root == null) {
      return [
        const Text('No account is loaded.', style: TextStyle(color: kText, fontSize: 15)),
      ];
    }
    if (_backupSeed != null) return _backupView(_backupSeed!);
    return _state == null ? _enableView(root) : _statusView(root, _state!);
  }

  // ── not enabled: explain + enable ──
  List<Widget> _enableView(NanoWallet root) {
    return [
      _card([
        const Text('Recoverable identity',
            style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 8),
        const Text(
          'Turn your account key into a recovery ANCHOR that delegates a separate, rotatable '
          'operational key. If your device is ever compromised, you rotate the operational key away '
          'while your account address, handle, and history stay the same.',
          style: TextStyle(color: kDim, fontSize: 13.5, height: 1.5),
        ),
        const SizedBox(height: 12),
        _kv('Account (anchor)', root.account, mono: true),
      ]),
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _busy ? null : _enable,
          style: FilledButton.styleFrom(
              backgroundColor: kAccent, foregroundColor: Colors.black),
          child: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
              : const Text('Enable account recovery',
                  style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ),
      if (_error != null) ...[
        const SizedBox(height: 14),
        _errorBox(_error!),
      ],
    ];
  }

  // ── enabled: status + rotate ──
  List<Widget> _statusView(NanoWallet root, AnchorOpState st) {
    final opShort = _short(st.op.pub);
    return [
      _card([
        Row(children: const [
          Icon(Icons.verified_user_outlined, color: kAccent, size: 18),
          SizedBox(width: 8),
          Text('Recovery: on',
              style: TextStyle(color: kAccent, fontWeight: FontWeight.w800, fontSize: 15)),
        ]),
        const SizedBox(height: 12),
        _kv('Anchor id (account)', st.anchor, mono: true),
        const SizedBox(height: 10),
        _kv('Current operational key', opShort, mono: true),
        const SizedBox(height: 10),
        _kv('Chain sequence', '${st.seq}'),
      ]),
      const SizedBox(height: 16),
      _card([
        const Text('My key was compromised',
            style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 8),
        const Text(
          'Rotate to a fresh operational key using your pre-committed recovery key. The old key is '
          'retired and can no longer act. Your account address and handle do NOT change.',
          style: TextStyle(color: kDim, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _rotate,
            style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFEF6C9B),
                side: const BorderSide(color: Color(0xFF5A2540))),
            icon: _busy
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFEF6C9B)))
                : const Icon(Icons.autorenew, size: 18),
            label: const Text('Rotate key — my key was compromised',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
      if (_error != null) ...[
        const SizedBox(height: 14),
        _errorBox(_error!),
      ],
    ];
  }

  // ── after enable/rotate: show the recovery key to write down ──
  List<Widget> _backupView(String seed) {
    return [
      _card([
        Row(children: const [
          Icon(Icons.check_circle_outline, color: kAccent, size: 18),
          SizedBox(width: 8),
          Expanded(
            child: Text('Recovery key',
                style: TextStyle(color: kAccent, fontWeight: FontWeight.w800, fontSize: 16)),
          ),
        ]),
        const SizedBox(height: 8),
        Text(_backupLabel,
            style: const TextStyle(color: kDim, fontSize: 13.5, height: 1.5)),
        const SizedBox(height: 12),
        const Text(
          '⚠ Write this down and keep it offline. It is what lets you recover this account if this '
          'device is lost or compromised. Anyone who has it can rotate your account away from you.',
          style: TextStyle(color: Color(0xFFE0B64D), fontSize: 12.5, height: 1.5),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kLine)),
          child: SelectableText(seed,
              style: const TextStyle(
                  color: kAccent, fontFamily: 'monospace', fontSize: 13, height: 1.5)),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => _copy(seed, 'Recovery key'),
            icon: const Icon(Icons.copy, size: 16, color: kDim),
            label: const Text('Copy', style: TextStyle(color: kDim)),
          ),
        ),
      ]),
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () => setState(() => _backupSeed = null),
          style: FilledButton.styleFrom(
              backgroundColor: kAccent, foregroundColor: Colors.black),
          child: const Text("I've written it down",
              style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      ),
    ];
  }

  // ── small style helpers (app's existing dark card look) ──
  Widget _card(List<Widget> children) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _kv(String k, String v, {bool mono = false}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k.toUpperCase(),
              style: const TextStyle(color: kDim, fontSize: 10, letterSpacing: 1)),
          const SizedBox(height: 3),
          SelectableText(v,
              style: TextStyle(
                  color: kText,
                  fontSize: mono ? 12.5 : 14,
                  fontFamily: mono ? 'monospace' : null)),
        ],
      );

  Widget _errorBox(String msg) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: const Color(0xFF2A0E18),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF5A2540))),
        child: Text(msg, style: const TextStyle(color: Color(0xFFEF6C9B), fontSize: 12.5)),
      );

  String _short(String hex) =>
      hex.length <= 16 ? hex : '${hex.substring(0, 10)}…${hex.substring(hex.length - 6)}';
}
