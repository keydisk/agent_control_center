import 'dart:io';

import 'package:agent_control_center/adapters/codex/codex_adapter.dart';
import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/ui/widgets/prompt_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stage1_antigravity_test.dart' show FakeProcessSpawner;

const _image = '/tmp/shot.png';
const _video = '/tmp/clip.mov';

final _macOnly = TargetPlatformVariant.only(TargetPlatform.macOS);

void _mockPasteboard(WidgetTester tester, List<String> paths) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('agent_control_center/pasteboard'),
    (_) async => paths,
  );
}

void _mockClipboardText(WidgetTester tester, String text) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async =>
        call.method == 'Clipboard.getData' ? {'text': text} : null,
  );
}

Future<void> _pumpBar(
  WidgetTester tester, {
  void Function(String, List<String>)? onSubmit,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PromptInputBar(
          selectedBackend: BackendType.claudeCode,
          selectedModel: BackendType.claudeCode.defaultModel,
          workingDirectory: '/tmp',
          onBackendChanged: (_) {},
          onModelChanged: (_) {},
          onWorkingDirectoryChanged: (_) {},
          onSubmit: onSubmit ?? (_, _) {},
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('prompt_textfield')));
  await tester.pump();
}

Future<void> _pressPaste(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
  await tester.pump();
}

String _promptText(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('prompt_textfield')))
    .controller!
    .text;

void main() {
  testWidgets(
    '붙여넣은 사진과 영상을 입력창 위에 표시하고 전송한다',
    (tester) async {
      final sent = <String>[];
      _mockPasteboard(tester, [_image, _video]);
      _mockClipboardText(tester, '파일 이름');
      await _pumpBar(tester, onSubmit: (_, files) => sent.addAll(files));

      await _pressPaste(tester);

      final imageFinder = find.byKey(const ValueKey('attachment_image_$_image'));
      final videoFinder = find.byKey(const ValueKey('attachment_chip_$_video'));
      expect(imageFinder, findsOneWidget);
      expect(videoFinder, findsOneWidget);
      expect(_promptText(tester), isEmpty);

      final fieldTop = tester
          .getTopLeft(find.byKey(const ValueKey('prompt_textfield')))
          .dy;
      expect(tester.getBottomLeft(imageFinder).dy, lessThanOrEqualTo(fieldTop));
      expect(tester.getBottomLeft(videoFinder).dy, lessThanOrEqualTo(fieldTop));

      await tester.enterText(
        find.byKey(const ValueKey('prompt_textfield')),
        '확인해 줘',
      );
      await tester.tap(find.byKey(const ValueKey('send_button')));
      await tester.pump();
      expect(sent, [_image, _video]);
      expect(imageFinder, findsNothing);
    },
    variant: _macOnly,
  );

  testWidgets(
    '미디어가 아니면 기존처럼 텍스트를 붙여넣는다',
    (tester) async {
      _mockPasteboard(tester, ['/tmp/notes.pdf']);
      _mockClipboardText(tester, '복사한 글');
      await _pumpBar(tester);

      await _pressPaste(tester);
      await tester.pumpAndSettle();

      expect(_promptText(tester), '복사한 글');
      expect(find.byType(InputChip), findsNothing);
    },
    variant: _macOnly,
  );

  testWidgets(
    '긴 텍스트는 파일로 첨부하고 파일만 전송할 수 있다',
    (tester) async {
      final content = '긴 내용\n' * 200;
      String? sentPrompt;
      List<String>? sentFiles;
      _mockPasteboard(tester, []);
      _mockClipboardText(tester, content);
      await _pumpBar(tester, onSubmit: (prompt, files) {
        sentPrompt = prompt;
        sentFiles = files;
      });

      await tester.runAsync(() async {
        final result = Actions.invoke(
          tester.element(find.byKey(const ValueKey('prompt_textfield'))),
          const PasteTextIntent(SelectionChangedCause.keyboard),
        );
        if (result is Future) await result;
      });
      await tester.pump();

      expect(_promptText(tester), isEmpty);
      final key = tester.widget<InputChip>(find.byType(InputChip)).key!
          as ValueKey<String>;
      final file = File(key.value.substring('attachment_chip_'.length));
      addTearDown(() => file.parent.deleteSync(recursive: true));
      expect(file.readAsStringSync(), content);

      await tester.tap(find.byKey(const ValueKey('send_button')));
      await tester.pump();
      expect(sentPrompt, '첨부 파일을 확인해 줘.');
      expect(sentFiles, [file.path]);
      expect(find.byType(InputChip), findsNothing);
    },
    variant: _macOnly,
  );

  testWidgets(
    '같은 파일은 한 번만 붙고 제거 버튼으로 뺄 수 있다',
    (tester) async {
      _mockPasteboard(tester, [_image]);
      await _pumpBar(tester);

      await _pressPaste(tester);
      await _pressPaste(tester);
      expect(
        find.byKey(const ValueKey('attachment_image_$_image')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('attachment_remove_$_image')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('attachment_image_$_image')),
        findsNothing,
      );
    },
    variant: _macOnly,
  );

  test('Codex는 이미지를 --image=로, 영상은 프롬프트 경로로 넘긴다', () async {
    final spawner = FakeProcessSpawner();
    final adapter = CodexAdapter(spawner: spawner);
    addTearDown(adapter.dispose);
    await adapter.start(
      const AgentSessionConfig(
        sessionId: 's',
        backendType: BackendType.codex,
        workingDirectory: '/tmp',
      ),
    );

    await adapter.send('요청', attachments: [_image, _video]);

    expect(spawner.lastArgs, isNot(contains('-i')));
    expect(spawner.lastArgs, isNot(contains('--image=$_video')));
    final imageIndex = spawner.lastArgs.indexOf('--image=$_image');
    expect(imageIndex, spawner.lastArgs.length - 2);
    expect(spawner.lastArgs.last, startsWith('요청'));
    expect(spawner.lastArgs.last, contains(_video));
  });
}
