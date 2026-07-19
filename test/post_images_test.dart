import 'package:elec/src/ui/post_images.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('同一レス内の複数画像をビューアで巡回できる', (tester) async {
    final urls = [
      Uri.parse('https://example.com/a.jpg'),
      Uri.parse('https://example.com/b.png'),
      Uri.parse('https://example.com/c.webp'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PostImages(urls: urls)),
      ),
    );

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle();
    expect(find.text('1/3  a.jpg'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('2/3  b.png'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text('1/3  a.jpg'), findsOneWidget);
  });

  testWidgets('動画URLは再生サムネイルとして表示する', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostImages(
            urls: const [],
            videoUrls: [Uri.parse('https://example.com/movie.mp4')],
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(find.text('movie.mp4'), findsOneWidget);
  });
}
