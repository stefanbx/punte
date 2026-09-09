// The notifications sheet's rows: what they say, and that they can be followed.
//
// A notification used to be a dead receipt — it told you someone liked your post and gave you no way
// to go and look at it. The row is now a tap target, and the sheet's list scrolls, so the older
// notifications below the fold are reachable at all (a bare Column just overflowed off the sheet).
//
//   cd app && flutter test test/notif_tile_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:punte/main.dart';

Map<String, dynamic> _n(String from, String kind, String text) =>
    {'from': from, 'kind': kind, 'text': text, 'ts': 1700000000, 'post_id': 'p_$from'};

void main() {
  test('the verb names the action, not a generic "mentioned you"', () {
    expect(NotifTile.verbFor('tip'), 'tipped your post');
    expect(NotifTile.verbFor('like'), 'liked your post');
    expect(NotifTile.verbFor('comment'), 'commented on your post');
    expect(NotifTile.verbFor('repost'), 'reposted your post');
    expect(NotifTile.verbFor('follow'), 'followed you');
    expect(NotifTile.verbFor(''), 'mentioned you');
  });

  test('a verb the text baked in is not repeated after the header', () {
    expect(NotifTile.detailOf('liked: hello there'), 'hello there');
    expect(NotifTile.detailOf('commented: nice'), 'nice');
    expect(NotifTile.detailOf('reacted 👍 to your post'), 'reacted 👍 to your post');
  });

  testWidgets('tapping anywhere on the row reports the tap', (t) async {
    var taps = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: NotifTile(notif: _n('alice.xno', 'like', 'liked: hello'), onTap: () => taps++)),
    ));
    await t.pump();
    expect(find.text('hello'), findsOneWidget);
    expect(find.textContaining('@alice.xno liked your post'), findsOneWidget);
    await t.tap(find.byType(NotifTile));
    expect(taps, 1);
    // the detail text is inside the row, not a separate target — tapping it counts too
    await t.tap(find.text('hello'));
    expect(taps, 2);
  });

  testWidgets('a full sheet of notifications scrolls instead of overflowing', (t) async {
    final many = [for (var i = 0; i < 40; i++) _n('user$i.xno', 'like', 'liked: post $i')];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        // the sheet's shape: a bounded box, a min-height Column, the list Flexible inside it
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 400),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Notifications'),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final n in many) NotifTile(notif: n, onTap: () {}),
                ]),
              ),
            ]),
          ),
        ),
      ),
    ));
    await t.pump();
    // An overflow here is not a soft failure: flutter_test turns the RenderFlex overflow into a test
    // error, so simply pumping this layout is the assertion that it fits.
    expect(find.text('post 0'), findsOneWidget);
    await t.drag(find.byType(ListView), const Offset(0, -2000));
    await t.pump();
    expect(find.text('post 0'), findsNothing, reason: 'the list scrolled');
  });
}
