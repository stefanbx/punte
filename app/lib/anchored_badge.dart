// ANCHORED NAMING — A3 author badge. A small, flag-gated trust indicator that wires the A3 resolver
// (anchored_identity.dart) into the author row / profile header.
//
// ADDITIVE + FLAG-GATED. Every call site is guarded by `if (kAnchoredEnabled)`, so with the flag false
// this widget is never built and the feed is byte-for-byte unchanged. It changes NOTHING for accounts
// without an anchor, and it never blocks a paint:
//   * FAIL-SAFE   — renders SizedBox.shrink() until (and unless) the resolver confirms a VERIFIED anchor;
//                   any network/verify failure just leaves it invisible (AnchorIdentity.none).
//   * NON-BLOCKING— reads the session cache synchronously; on a miss it kicks off one shared async lookup
//                   (the cache de-dups across every post card for the same author) and repaints only this
//                   badge when it resolves.
// It shows only for anchored accounts, and surfaces the rotation generation (recovery has happened N×).

import 'package:flutter/material.dart';

import 'anchored_identity.dart';
import 'main.dart' show kAccent;

/// A shield shown next to an author's name IFF [account] has a verified recoverable anchor.
class AnchoredIdentityBadge extends StatefulWidget {
  final String account;
  final double size;
  const AnchoredIdentityBadge(this.account, {super.key, this.size = 14});
  @override
  State<AnchoredIdentityBadge> createState() => _AnchoredIdentityBadgeState();
}

class _AnchoredIdentityBadgeState extends State<AnchoredIdentityBadge> {
  AnchorIdentity? _id;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(AnchoredIdentityBadge old) {
    super.didUpdateWidget(old);
    if (old.account != widget.account) {
      _id = null;
      _resolve();
    }
  }

  void _resolve() {
    // Synchronous cache hit → no repaint needed (we're in init/update).
    final cached = AnchorIdentityCache.I.peek(widget.account);
    if (cached != null) {
      _id = cached;
      return;
    }
    // Miss → one shared, fail-safe async lookup; repaint this badge only when it lands.
    final want = widget.account;
    AnchorIdentityCache.I.identify(want).then((r) {
      if (mounted && widget.account == want) setState(() => _id = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    final id = _id;
    if (id == null || !id.hasAnchor) return const SizedBox.shrink();
    final rotated = id.seq > 0;
    return Padding(
      padding: const EdgeInsets.only(left: 5),
      child: Tooltip(
        message: rotated
            ? 'Recoverable identity · key rotated ${id.seq}×'
            : 'Recoverable identity',
        child: Icon(Icons.shield_outlined, size: widget.size, color: kAccent),
      ),
    );
  }
}
