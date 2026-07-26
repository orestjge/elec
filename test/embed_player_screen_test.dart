import 'package:elec/src/ui/embed_player_screen.dart';
import 'package:elec/src/ui/embed_urls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugEmbedPlayerTargetPlatform = null);

  testWidgets('macOS では WebView を開かずブラウザへ回す', (tester) async {
    debugEmbedPlayerTargetPlatform = TargetPlatform.macOS;
    final video = embedVideosIn('https://youtu.be/dQw4w9WgXcQ').single;
    final opened = <Uri>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                openEmbedPlayer(context, video, onOpenExternally: opened.add),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(opened, [video.url]);
    expect(find.byType(EmbedPlayerScreen), findsNothing);
  });
}
