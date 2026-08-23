// ANCHORED CONTENT VIEWER — Phase B3 UI (resolve a NAME → verify on-device → render the verified content).
//
// ADDITIVE + FLAG-GATED. This whole file is dead code unless kAnchoredEnabled is true: nothing imports
// AnchoredViewerScreen except behind an `if (kAnchoredEnabled)` guard in main.dart, so with the flag
// false the app is byte-for-byte unchanged.
//
// THE FLOW (name in, verified interactive content out):
//   1. resolveAnchor(name)  [anchor.dart]  — fetch lease + KERI log + blob from the live relays and VERIFY
//      every link ON-DEVICE (lease sig, KERI chain, content sha256). Throws AnchorError on ANY failure, so
//      we NEVER render bytes we could not prove. The result carries {anchor, currentKey, contentCid,
//      contentBytes, seq}.
//   2. POST the verified contentBytes (raw Keel source) to the hosted content runtime `$host/load` → the
//      runtime returns {"session":"<id>","url":"/s/<id>"}.
//   3. Load `$host$url` in a WebView. The runtime renders zero-JS interactive HTML whose buttons are plain
//      links (/s/<id>?e=N) back into the same host — so taps navigate within the host with no interception.
//
// A provenance chip sits ABOVE the WebView showing the content was resolved BY NAME and verified locally.
// It reuses the app theme + the anchored_recovery.dart card/error look for consistency.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

import 'anchor.dart';
import 'main.dart' show kBg, kCard, kLine, kText, kDim, kAccent;

/// The hosted Keel content runtime (B2): fetches the client-VERIFIED bytes, runs them sandboxed and
/// renders zero-JS. Deployed as an isolated Fly app over HTTPS. For local host development, point this
/// at 'http://10.0.2.2:8799' (the host machine's localhost from the Android emulator).
const String kAnchorContentHost = 'https://xchat-content-host.fly.dev';

/// The names published to the runtime — offered as one-tap buttons so the demo path needs no typing.
const List<String> kAnchorDemoNames = ['counter', 'greeter'];

class AnchoredViewerScreen extends StatefulWidget {
  /// When set (e.g. jumping here straight after publishing), the name is resolved automatically on open.
  final String? initialName;
  const AnchoredViewerScreen({super.key, this.initialName});
  @override
  State<AnchoredViewerScreen> createState() => _AnchoredViewerScreenState();
}

class _AnchoredViewerScreenState extends State<AnchoredViewerScreen> {
  final _nameCtrl = TextEditingController();
  bool _busy = false;
  String? _error; // set → "could not verify" state; we NEVER render content while this is non-null
  AnchorResult? _result; // the verified resolution backing the provenance chip
  WebViewController? _webView;

  @override
  void initState() {
    super.initState();
    final n = widget.initialName?.trim() ?? '';
    if (n.isNotEmpty) {
      _nameCtrl.text = n;
      WidgetsBinding.instance.addPostFrameCallback((_) => _go(n));
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _go(String rawName) async {
    final name = rawName.trim();
    if (name.isEmpty || _busy) return;
    _nameCtrl.text = name;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _webView = null;
    });
    try {
      // 1. resolve + VERIFY on-device. Throws AnchorError on any failure → no content is ever shown.
      final res = await resolveAnchor(name);

      // 2. hand the VERIFIED bytes to the hosted runtime; it returns a session url.
      final url = await _loadIntoRuntime(res.contentBytes);

      // 3. render the runtime's interactive HTML in a WebView.
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(kBg)
        ..loadRequest(Uri.parse('$kAnchorContentHost$url'));

      if (!mounted) return;
      setState(() {
        _result = res;
        _webView = c;
        _busy = false;
      });
    } on AnchorError catch (e) {
      // verification failed — show a clear "could not verify" state, never unverified content.
      if (!mounted) return;
      setState(() {
        _error = 'Could not verify "$name": ${e.message}';
        _busy = false;
      });
    } catch (e) {
      // resolved+verified, but the content host was unreachable / rejected the load.
      if (!mounted) return;
      setState(() {
        _error = 'Verified "$name", but the content host could not render it: $e';
        _busy = false;
      });
    }
  }

  /// POST the raw verified Keel source to `$host/load`; returns the runtime session url (e.g. `/s/<id>`).
  Future<String> _loadIntoRuntime(List<int> contentBytes) async {
    final r = await http
        .post(Uri.parse('$kAnchorContentHost/load'), body: contentBytes)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode ~/ 100 != 2) {
      throw 'load HTTP ${r.statusCode}: ${r.body}';
    }
    final j = jsonDecode(r.body);
    if (j is! Map || j['url'] is! String) {
      throw 'runtime returned no session url';
    }
    return j['url'] as String;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        iconTheme: const IconThemeData(color: kText),
        title: const Text('Anchored content',
            style: TextStyle(color: kText, fontWeight: FontWeight.w800, fontSize: 17)),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _picker(),
            if (_result != null) _provenanceChip(_result!),
            Expanded(child: _viewport()),
          ],
        ),
      ),
    );
  }

  // ── name input + quick-pick buttons ──
  Widget _picker() => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: const BoxDecoration(
            color: kBg, border: Border(bottom: BorderSide(color: kLine))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('RESOLVE A NAME',
                style: TextStyle(color: kDim, fontSize: 10, letterSpacing: 1)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _nameCtrl,
                  enabled: !_busy,
                  style: const TextStyle(color: kText, fontSize: 14),
                  textInputAction: TextInputAction.go,
                  onSubmitted: _go,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'name (e.g. counter)',
                    hintStyle: const TextStyle(color: kDim),
                    filled: true,
                    fillColor: kCard,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: kLine)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: kAccent)),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: kLine)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy ? null : () => _go(_nameCtrl.text),
                style: FilledButton.styleFrom(
                    backgroundColor: kAccent, foregroundColor: Colors.black),
                child: _busy
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.black))
                    : const Text('Go', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ]),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final n in kAnchorDemoNames)
                  OutlinedButton(
                    onPressed: _busy ? null : () => _go(n),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: kText,
                        side: const BorderSide(color: kLine),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                        visualDensity: VisualDensity.compact),
                    child: Text(n),
                  ),
              ],
            ),
          ],
        ),
      );

  // ── provenance chip: proves the content was resolved BY NAME + verified ON-DEVICE ──
  Widget _provenanceChip(AnchorResult r) => Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
            color: const Color(0xFF0E2A22),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF24614E))),
        child: Row(children: [
          const Icon(Icons.verified, color: kAccent, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '✓ verified · ${r.name} · anchor ${_short(r.anchor)} · cid ${_short(r.contentCid)}',
              style: const TextStyle(
                  color: Color(0xFF8FE0C6), fontSize: 12, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      );

  // ── the content viewport: idle prompt / error / WebView ──
  Widget _viewport() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.gpp_bad_outlined, color: Color(0xFFEF6C9B), size: 40),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: const Color(0xFF2A0E18),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF5A2540))),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFEF6C9B), fontSize: 13, height: 1.5)),
            ),
            const SizedBox(height: 12),
            const Text('Nothing unverified is ever shown here.',
                style: TextStyle(color: kDim, fontSize: 12)),
          ]),
        ),
      );
    }
    if (_webView != null) return WebViewWidget(controller: _webView!);
    if (_busy) return const Center(child: CircularProgressIndicator(color: kAccent));
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: const [
          Icon(Icons.travel_explore, color: kDim, size: 40),
          SizedBox(height: 12),
          Text('Enter a name to resolve, verify, and view its content.',
              textAlign: TextAlign.center,
              style: TextStyle(color: kDim, fontSize: 14, height: 1.5)),
        ]),
      ),
    );
  }

  String _short(String s) =>
      s.length <= 18 ? s : '${s.substring(0, 10)}…${s.substring(s.length - 6)}';
}
