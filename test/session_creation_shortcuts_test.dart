import 'dart:io';

import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/services/trusted_folder_store.dart';
import 'package:agent_control_center/ui/widgets/session_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pressShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool submit = false,
}) async {
  final modifier = submit
      ? (Platform.isMacOS
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.controlLeft)
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  if (!submit) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  if (!submit) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

void main() {
  testWidgets('새 세션: 포커스 이동과 단축키 생성', (tester) async {
    NewSessionRequest? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDialog<NewSessionRequest>(
              context: context,
              builder: (_) => NewSessionDialog(
                initialBackend: BackendType.codex,
                initialFolder: Directory.current.path,
                showInstructions: true,
              ),
            ),
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    await pressShortcut(tester, LogicalKeyboardKey.keyM);
    expect(
      find
          .descendant(
            of: find.byKey(const ValueKey('session_model_codex')),
            matching: find.byType(Focus),
          )
          .evaluate()
          .any(
            (element) => (element.widget as Focus).focusNode?.hasFocus ?? false,
          ),
      isTrue,
    );
    await pressShortcut(tester, LogicalKeyboardKey.keyF);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('new_session_folder')))
          .focusNode!
          .hasFocus,
      isTrue,
    );
    await pressShortcut(tester, LogicalKeyboardKey.keyI);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('new_session_instructions')),
          )
          .focusNode!
          .hasFocus,
      isTrue,
    );
    await tester.enterText(
      find.byKey(const ValueKey('new_session_instructions')),
      '지침',
    );
    await pressShortcut(tester, LogicalKeyboardKey.enter, submit: true);
    await tester.pumpAndSettle();
    expect(result?.instructions, '지침');
    expect(find.byKey(const ValueKey('new_session_dialog')), findsNothing);
  });

  testWidgets('새 그룹: 포커스 이동, Escape 취소, 단축키 저장', (tester) async {
    WorkspaceGroupResult? result;
    final trustedFolders = TrustedFolderStore();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await showDialog<WorkspaceGroupResult>(
                  context: context,
                  builder: (_) => WorkspaceGroupDialog(
                    defaultInstructions: '',
                    initialFolder: Directory.current.path,
                    trustedFolders: trustedFolders,
                  ),
                ),
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(result, isNull);

    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('group_name')), '그룹');
    await pressShortcut(tester, LogicalKeyboardKey.keyM);
    expect(
      find
          .descendant(
            of: find.byKey(const ValueKey('session_model_agy')),
            matching: find.byType(Focus),
          )
          .evaluate()
          .any(
            (element) => (element.widget as Focus).focusNode?.hasFocus ?? false,
          ),
      isTrue,
    );
    await pressShortcut(tester, LogicalKeyboardKey.keyF);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('group_folder')))
          .focusNode!
          .hasFocus,
      isTrue,
    );
    await pressShortcut(tester, LogicalKeyboardKey.keyI);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('group_extra_instructions')),
          )
          .focusNode!
          .hasFocus,
      isTrue,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('session_model_agy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session_model_agy')));
    await tester.pumpAndSettle();
    await pressShortcut(tester, LogicalKeyboardKey.enter, submit: true);
    expect(result, isNull);
    expect(trustedFolders.folders, isEmpty);
    expect(
      find.byKey(const ValueKey('workspace_group_dialog')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await pressShortcut(tester, LogicalKeyboardKey.enter, submit: true);
    await tester.pumpAndSettle();
    expect(result?.group.name, '그룹');
  });
}
