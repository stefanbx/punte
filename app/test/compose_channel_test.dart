// Posting to a channel from the composer. The picker used to show only in Article mode, so a plain
// post, thread or poll could never go out under a channel. These pump the real ComposeSheet and read
// the ComposeResult it pops — the same value _compose hands to the send path.
//
//   cd app && flutter test test/compose_channel_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:punte/main.dart';

Future<ComposeResult?> _open(WidgetTester t, Widget sheet, Future<void> Function() act) async {
  ComposeResult? out;
  await t.pumpWidget(MaterialApp(home: Builder(builder: (ctx) => Scaffold(
    body: TextButton(
      onPressed: () async {
        out = await showModalBottomSheet<ComposeResult>(
            context: ctx, isScrollControlled: true, builder: (_) => sheet);
      },
      child: const Text('open')),
  ))));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  await act();
  await t.pumpAndSettle();
  return out;
}

void main() {
  testWidgets('a plain post can be sent to a channel', (t) async {
    final res = await _open(t,
        const ComposeSheet(handle: 'me', account: 'nano_me', channels: ['Daily News']), () async {
      expect(find.text('Posting as you'), findsOneWidget);
      await t.tap(find.text('Posting as you'));
      await t.pumpAndSettle();
      await t.tap(find.text('Daily News').last);
      await t.pumpAndSettle();
      expect(find.text('Posting to Daily News'), findsOneWidget);
      await t.enterText(find.byType(TextField).first, 'hello channel');
      await t.tap(find.text('Post'));
    });
    expect(res, isNotNull);
    expect(res!.segments, ['hello channel']);
    expect(res.channel, 'Daily News');
  });

  testWidgets('opening from a channel row preselects it', (t) async {
    final res = await _open(t,
        const ComposeSheet(handle: 'me', account: 'nano_me', channels: ['A', 'B'], initialChannel: 'B'),
        () async {
      expect(find.text('Posting to B'), findsOneWidget);
      await t.enterText(find.byType(TextField).first, 'x');
      await t.tap(find.text('Post'));
    });
    expect(res!.channel, 'B');
  });

  testWidgets('no picker without channels; default is yourself', (t) async {
    final res = await _open(t, const ComposeSheet(handle: 'me', account: 'nano_me'), () async {
      expect(find.textContaining('Posting'), findsNothing);
      await t.enterText(find.byType(TextField).first, 'x');
      await t.tap(find.text('Post'));
    });
    expect(res!.channel, '');
  });
}
