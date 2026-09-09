// Where a tap on a post's photo goes.
//
// A photo-only post has no body text, so the picture IS the card: when the picture opened the zoom
// viewer there was no way to reach the post's own view — its replies, its thread, its actions. So in
// the FEED the photo opens the post, and inside the post view (inPostView) it opens the zoomable
// gallery, exactly as it always did. These pump the real PostCard and tap the real image.
//
//   cd app && flutter test test/post_photo_tap_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:punte/main.dart';

Post _photoPost() => Post(
      'p1', 'alice.xno', 'nano_1alice', 'photo', '', // no text at all — the picture is the whole post
      null, 'cid_photo_1', null, null, 1700000000, 0, 0);

Finder _thePhoto() => find.byWidgetPredicate(
    (w) => w is MediaImage && w.cid == 'cid_photo_1', description: 'the post photo');

Future<int> _tapPhoto(WidgetTester t, {required bool inPostView}) async {
  var opened = 0;
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ListView(children: [
        PostCard(
          post: _photoPost(),
          inPostView: inPostView,
          onTip: () {},
          onOpenThread: () => opened++,
        ),
      ]),
    ),
  ));
  await t.pump();
  expect(_thePhoto(), findsOneWidget);
  await t.tap(_thePhoto());
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));   // let a pushed route settle
  return opened;
}

void main() {
  testWidgets('feed: the photo opens the POST, not the zoom viewer', (t) async {
    final opened = await _tapPhoto(t, inPostView: false);
    expect(opened, 1, reason: 'a photo tap in the feed must open the post view');
    expect(find.byType(GalleryScreen), findsNothing,
        reason: 'the zoom viewer belongs one step in, not in the feed');
  });

  testWidgets('post view: the photo opens the zoomable gallery', (t) async {
    final opened = await _tapPhoto(t, inPostView: true);
    expect(opened, 0, reason: 'already inside the post — there is nowhere further to open');
    expect(find.byType(GalleryScreen), findsOneWidget);
  });
}
