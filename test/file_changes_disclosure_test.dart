import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/ui/widgets/timeline_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

FileDiffEvent _change(String id, String path, {String session = 's1'}) =>
    FileDiffEvent(
      id: id,
      sessionId: session,
      backend: BackendType.antigravity,
      timestamp: DateTime(2026),
      diff: FileDiffItem(filePath: path, newContent: id),
    );

Widget _view(
  List<FileDiffEvent> events, {
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness),
  home: Scaffold(
    body: SingleChildScrollView(child: FileChangesCard(events: events)),
  ),
);

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('파일 수를 중복 없이 표시하고 모든 변경을 펼치고 접는다: $brightness', (tester) async {
      await tester.pumpWidget(
        _view([
          _change('d1', 'lib/main.dart'),
          _change('d2', 'lib/app.dart'),
          _change('d3', 'lib/main.dart'),
        ], brightness: brightness),
      );
      expect(find.text('파일 변경 2개'), findsOneWidget);
      expect(find.byType(FileDiffViewerCard), findsNothing);

      await tester.tap(find.text('파일 변경 2개'));
      await tester.pumpAndSettle();
      expect(find.byType(FileDiffViewerCard), findsNWidgets(3));
      expect(find.text('파일 변경 Diff: lib/main.dart'), findsNWidgets(2));
      expect(find.text('파일 변경 Diff: lib/app.dart'), findsOneWidget);

      await tester.tap(find.text('파일 변경 2개'));
      await tester.pumpAndSettle();
      expect(find.byType(FileDiffViewerCard), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('변경이 추가되어도 펼침 상태를 유지하고 다른 세션은 접어서 표시한다', (tester) async {
    final first = _change('d1', 'lib/main.dart');
    await tester.pumpWidget(_view([first]));
    await tester.tap(find.text('파일 변경 1개'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_view([first, _change('d2', 'lib/app.dart')]));
    await tester.pumpAndSettle();
    expect(find.byType(FileDiffViewerCard), findsNWidgets(2));

    await tester.pumpWidget(
      _view([_change('d3', 'other.dart', session: 's2')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('파일 변경 1개'), findsOneWidget);
    expect(find.byType(FileDiffViewerCard), findsNothing);

    await tester.pumpWidget(_view([first]));
    await tester.pumpAndSettle();
    expect(find.byType(FileDiffViewerCard), findsOneWidget);
  });
}
