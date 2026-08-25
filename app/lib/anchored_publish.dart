// ANCHORED NAMING — Phase B4: publish anchored content from inside xchat.
//
// ADDITIVE + FLAG-GATED. Dead code unless kAnchoredEnabled is true: nothing imports AnchoredPublishScreen
// except behind an `if (kAnchoredEnabled)` guard in main.dart, so with the flag false the app is
// byte-for-byte unchanged. It signs nothing about the user's own identity and changes no existing flow.
//
// A published name is its OWN anchor (a dedicated keypair) whose tip endpoints point at the content blob —
// exactly what AnchoredViewerScreen resolves + verifies. The anchor keypairs are DERIVED from the account
// seed + the name (anchor.dart contentAnchorKeys), so a published name is restorable from the seed alone
// and needs no extra secret storage; only the seed holder can mint the root signature the lease requires.
//
// Flow: pick a name + content → dry-run the content against the hosted runtime (so we never claim a name
// for content that won't run) → publishContent (upload blob, sign+publish inception + lease) → offer to
// open it in the verifying viewer, proving the round-trip on-device.
//
// It reuses the app's primitives and adds no deps:
//   * publish (blob + inception + lease)  -> anchor.dart (publishContent / contentAnchorKeys)
//   * content dry-run + viewer            -> anchored_viewer.dart (kAnchorContentHost / AnchoredViewerScreen)
//   * identity (the publishing seed)      -> gWallet (main.dart)
//   * theme                               -> kBg/kText/kAccent/… from main.dart

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'anchor.dart';
import 'anchored_viewer.dart' show kAnchorContentHost, AnchoredViewerScreen;
import 'main.dart' show kBg, kCard, kLine, kText, kDim, kAccent, gWallet;

/// Starter content programs (valid Keel: import ui.kl + view/update). Offered so publishing needs no
/// authoring from scratch; the user can edit freely before publishing.
const Map<String, String> _kTemplates = {
  'counter': 'import "ui.kl"\n'
      '\n'
      'fn view(state) {\n'
      '  Col([ Text("count is " + str(state)),\n'
      '        Row([ Button("increment", 1), Button("reset", 2) ]),\n'
      '        Text("published from xchat") ])\n'
      '}\n'
      '\n'
      'fn update(state, event) {\n'
      '  if event == 1 { state + 1 }\n'
      '  else { if event == 2 { 0 } else { state } }\n'
      '}\n',
  'greeter': 'import "ui.kl"\n'
      '\n'
      'fn view(state) {\n'
      '  Col([ Text("Hello from an anchored name"),\n'
      '        Row([ Button("again", 1) ]),\n'
      '        Text("published from xchat") ])\n'
      '}\n'
      '\n'
      'fn update(state, event) { state + 1 }\n',
};

/// A valid name: 2–39 chars, lowercase letters/digits/hyphen, not starting or ending with a hyphen.
final RegExp _kNameRe = RegExp(r'^[a-z0-9]([a-z0-9-]{0,37}[a-z0-9])?$');

class AnchoredPublishScreen extends StatefulWidget {
  const AnchoredPublishScreen({super.key});
  @override
  State<AnchoredPublishScreen> createState() => _AnchoredPublishScreenState();
}

class _AnchoredPublishScreenState extends State<AnchoredPublishScreen> {
  final _nameCtrl = TextEditingController();
  final _contentCtrl = TextEditingController(text: _kTemplates['counter']);
  bool _busy = false;
  String? _status; // progress line while publishing
  String? _error; // failure message
  PublishResult? _result; // set on success

  @override
  void dispose() {
    _nameCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  /// Ask the hosted runtime to load the content (sandboxed) WITHOUT claiming anything, so a program that
  /// won't compile/run is caught before it costs a name. Returns null if it runs, else the host's reason.
  Future<String?> _dryRun(List<int> bytes) async {
    try {
      final r = await http
          .post(Uri.parse('$kAnchorContentHost/load'), body: bytes)
          .timeout(const Duration(seconds: 15));
      if (r.statusCode ~/ 100 == 2) return null;
      return 'the content did not run: HTTP ${r.statusCode}: ${r.body}';
    } catch (e) {
      return 'could not reach the content runtime to check it: $e';
    }
  }

  Future<void> _publish() async {
    final name = _nameCtrl.text.trim().toLowerCase();
    final source = _contentCtrl.text;
    final wallet = gWallet;
    if (_busy) return;
    if (!_kNameRe.hasMatch(name)) {
      setState(() => _error =
          'Pick a name of 2–39 chars: lowercase letters, digits and hyphens (not at the ends).');
      return;
    }
    if (source.trim().isEmpty) {
      setState(() => _error = 'The content is empty.');
      return;
    }
    if (wallet == null) {
      setState(() => _error = 'No wallet on this device.');
      return;
    }
    final bytes = utf8.encode(source);

    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _status = 'Checking the content runs…';
    });
    try {
      // 1. dry-run — never claim a name for content that won't render.
      final bad = await _dryRun(bytes);
      if (bad != null) {
        if (!mounted) return;
        setState(() {
          _error = bad;
          _busy = false;
          _status = null;
        });
        return;
      }

      // 2. publish: upload blob → sign+publish inception (tip → content) → sign+publish lease.
      if (!mounted) return;
      setState(() => _status = 'Publishing to the relays…');
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final res = await publishContent(
        publisher: wallet,
        name: name,
        contentBytes: bytes,
        ts: ts,
      );

      // 3. confirm it resolves + verifies end-to-end from the relays (no local trust).
      if (!mounted) return;
      setState(() => _status = 'Verifying it resolves…');
      await resolveAnchor(name);

      if (!mounted) return;
      setState(() {
        _result = res;
        _busy = false;
        _status = null;
      });
    } on AnchorError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message.contains('already claimed')
            ? 'The name "$name" is already taken.'
            : 'Publish failed: ${e.message}';
        _busy = false;
        _status = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Publish failed: $e';
        _busy = false;
        _status = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        iconTheme: const IconThemeData(color: kText),
        title: const Text('Publish anchored content',
            style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 18)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const Text('NAME',
                style: TextStyle(color: kDim, fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _nameCtrl,
              enabled: !_busy,
              autocorrect: false,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9-]')),
                LengthLimitingTextInputFormatter(39),
              ],
              style: const TextStyle(color: kText, fontSize: 16),
              decoration: _dec('a short name, e.g. my-counter'),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Text('CONTENT',
                    style: TextStyle(color: kDim, fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w700)),
                const Spacer(),
                for (final t in _kTemplates.keys)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => setState(() => _contentCtrl.text = _kTemplates[t]!),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: kLine),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(t, style: const TextStyle(color: kText, fontSize: 13)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _contentCtrl,
              enabled: !_busy,
              maxLines: 12,
              minLines: 8,
              autocorrect: false,
              style: const TextStyle(
                  color: kText, fontSize: 13, fontFamily: 'monospace', height: 1.4),
              decoration: _dec('a Tipar program: import "ui.kl" + view(state) / update(state, event)'),
            ),
            const SizedBox(height: 6),
            const Text(
              'A pure Tipar page (view + update, no I/O). It is checked against the sandboxed runtime before '
              'the name is claimed.',
              style: TextStyle(color: kDim, fontSize: 12),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _busy ? null : _publish,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  disabledBackgroundColor: kAccent.withValues(alpha: 0.4),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _busy
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black87)),
                          const SizedBox(width: 12),
                          Text(_status ?? 'Working…',
                              style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w700)),
                        ],
                      )
                    : const Text('Publish',
                        style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: 16)),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              _card(
                border: const Color(0xFF5A1E22),
                bg: const Color(0xFF241012),
                child: Text(_error!, style: const TextStyle(color: Color(0xFFE59AA0), fontSize: 13)),
              ),
            ],
            if (_result != null) ...[
              const SizedBox(height: 16),
              _successCard(_result!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _successCard(PublishResult r) => _card(
        border: const Color(0xFF1E5A33),
        bg: const Color(0xFF0E2417),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.verified, color: Color(0xFF57D98A), size: 18),
              const SizedBox(width: 8),
              Text('“${r.name}” is live',
                  style: const TextStyle(color: Color(0xFF9AE5B4), fontWeight: FontWeight.w800, fontSize: 15)),
            ]),
            const SizedBox(height: 10),
            _kv('anchor', r.anchor),
            _kv('content', r.cid),
            const SizedBox(height: 12),
            Row(children: [
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => AnchoredViewerScreen(initialName: r.name)));
                },
                icon: const Icon(Icons.travel_explore, color: kText, size: 18),
                label: const Text('Open in viewer', style: TextStyle(color: kText)),
                style: OutlinedButton.styleFrom(side: const BorderSide(color: kLine)),
              ),
              const SizedBox(width: 10),
              TextButton.icon(
                onPressed: () => Clipboard.setData(ClipboardData(text: r.name)),
                icon: const Icon(Icons.copy, color: kDim, size: 16),
                label: const Text('Copy name', style: TextStyle(color: kDim)),
              ),
            ]),
          ],
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: '$k  ', style: const TextStyle(color: kDim, fontSize: 12)),
          TextSpan(
              text: v,
              style: const TextStyle(color: kText, fontSize: 12, fontFamily: 'monospace')),
        ])),
      );

  Widget _card({required Color border, required Color bg, required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: kDim, fontSize: 13),
        filled: true,
        fillColor: kCard,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kLine)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: kAccent)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      );
}
