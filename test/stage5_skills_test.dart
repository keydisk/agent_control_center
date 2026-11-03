import 'dart:async';
import 'dart:io';

import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/backend/backend_registry.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/main.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:agent_control_center/services/skill_registry.dart';
import 'package:agent_control_center/ui/widgets/prompt_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _NoopBackend implements AgentBackend {
  _NoopBackend(this.backendType);

  @override
  final BackendType backendType;
  final StreamController<AgentEvent> _events =
      StreamController<AgentEvent>.broadcast();
  final StreamController<String> _logs = StreamController<String>.broadcast();
  AgentSessionConfig? startedConfig;
  final List<String> sentPrompts = [];

  @override
  Stream<AgentEvent> get events => _events.stream;

  @override
  Stream<String> get rawLogs => _logs.stream;

  @override
  String? get remoteConversationId => 'conv_skill';

  @override
  Future<void> start(AgentSessionConfig config) async {
    startedConfig = config;
  }

  @override
  Future<void> send(
    String prompt, {
    List<String> attachments = const [],
  }) async {
    sentPrompts.add(prompt);
  }

  @override
  Future<void> respondToApproval(ApprovalDecision decision) async {}

  @override
  Future<void> respondToQuestion(
    String requestId,
    Map<String, List<String>> answers,
  ) async {}

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> resume(String conversationId, AgentSessionConfig config) async {}

  @override
  Future<void> dispose() async {
    await _events.close();
    await _logs.close();
  }
}

void main() {
  group('5단계: 전 백엔드 공통 스킬 연동 (SkillRegistry, 동기화, 라우팅, UI)', () {
    test('SKILL.md 파싱, 3대 백엔드 심볼릭 링크 동기화 및 웹/외부 CLI 공통 라우팅이 동작한다', () async {
      final tempRoot = await Directory.systemTemp.createTemp('acc_skills_test_');
      addTearDown(() async {
        if (tempRoot.existsSync()) {
          await tempRoot.delete(recursive: true);
        }
      });

      final agyDir = p.join(tempRoot.path, 'agy_skills');
      final claudeDir = p.join(tempRoot.path, 'claude_skills');
      final codexDir = p.join(tempRoot.path, 'codex_skills');

      // agy_skills 안에 ego-browser SKILL.md 생성
      final egoSourceDir = Directory(p.join(agyDir, 'ego-browser'));
      await egoSourceDir.create(recursive: true);
      final egoMd = File(p.join(egoSourceDir.path, 'SKILL.md'));
      await egoMd.writeAsString('''---
name: ego-browser
description: Chromium browser skill for web automation
---
# ego-browser
''');

      final registry = SkillRegistry(
        backendSkillDirs: {
          BackendType.antigravity: agyDir,
          BackendType.claudeCode: claudeDir,
          BackendType.codex: codexDir,
        },
        loadDefaults: true,
      );

      // ego-browser 경로를 임시 폴더로 덮어써서 심볼릭 링크 동기화 검증
      registry.registerSkill(
        SkillDefinition(
          name: 'ego-browser',
          description: '웹 브라우저 자동화 스킬',
          skillMdPath: egoMd.path,
          directoryPath: egoSourceDir.path,
        ),
      );

      final syncedCount = await registry.syncSkillsAcrossBackends();
      expect(syncedCount, greaterThanOrEqualTo(2));
      expect(
        FileSystemEntity.typeSync(
          p.join(claudeDir, 'ego-browser'),
          followLinks: false,
        ),
        FileSystemEntityType.link,
      );
      expect(
        FileSystemEntity.typeSync(
          p.join(codexDir, 'ego-browser'),
          followLinks: false,
        ),
        FileSystemEntityType.link,
      );

      // 공통 라우팅 규칙 검증: 웹 작업 -> ego-browser
      final webMatches = registry.matchRoutedSkills(
        'https://flutter.dev 사이트 페이지 열기 후 폼 입력 및 스크래핑 해줘',
      );
      expect(webMatches.map((m) => m.skill.name), contains('ego-browser'));

      // 공통 라우팅 규칙 검증: 외부 소프트웨어/CLI -> cli-hub-meta-skill
      final cliMatches = registry.matchRoutedSkills(
        'Blender 외부 소프트웨어 CLI 하네스로 3D 모델을 렌더링해줘',
      );
      expect(
        cliMatches.map((m) => m.skill.name),
        contains('cli-hub-meta-skill'),
      );

      // 비활성화 시 라우팅 제외 확인
      registry.setSkillEnabled('ego-browser', false);
      expect(
        registry.matchRoutedSkills('https://flutter.dev 웹 검색해줘'),
        isEmpty,
      );
    });

    testWidgets('스킬 관리 화면에서 스킬 조회·즉시 호출 시 타임라인에 호출 스킬 배너가 표시된다', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final backend = _NoopBackend(BackendType.claudeCode);
      final backendRegistry = BackendRegistry();
      for (final b in BackendType.values) {
        backendRegistry.register(b, ({spawner, hookBridge}) => backend);
      }

      final manager = SessionManager(registry: backendRegistry);
      manager.createSession(
        sessionId: 's_skill',
        backendType: BackendType.claudeCode,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ControlCenterHomeScreen(sessionManagerOverride: manager),
        ),
      );
      await tester.pumpAndSettle();

      // 상단 '스킬 관리' 버튼 클릭
      await tester.tap(find.byKey(const ValueKey('open_skills_screen_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('skill_card_ego-browser')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('skill_card_cli-hub-meta-skill')),
        findsOneWidget,
      );

      // ego-browser '즉시 호출' 버튼 클릭 -> 호출 확인 다이얼로그
      await tester.tap(find.byKey(const ValueKey('invoke_skill_ego-browser')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('confirm_invoke_skill_button')),
      );
      await tester.pumpAndSettle();

      // 타임라인에 스킬 호출 배너가 렌더링되었는지 확인
      expect(find.textContaining('스킬 호출됨: ego-browser'), findsOneWidget);
      expect(backend.sentPrompts.single, contains('ego-browser'));

      manager.dispose();
    });

    testWidgets('입력창 맨 앞 "/"에 활성 스킬 목록을 표시하고 선택 시 입력창에 채운다', (tester) async {
      SkillDefinition skill(String name, {bool enabled = true}) =>
          SkillDefinition(
            name: name,
            description: '$name 설명',
            skillMdPath: '/skills/$name/SKILL.md',
            directoryPath: '/skills/$name',
            isEnabled: enabled,
          );

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
              onSubmit: (_, _) {},
              skills: [
                skill('ego-browser'),
                skill('Deploy-Check'),
                skill('disabled-skill', enabled: false),
              ],
            ),
          ),
        ),
      );

      final field = find.byKey(const ValueKey('prompt_textfield'));
      Finder chip(String name) => find.byKey(ValueKey('slash_chip_/$name'));

      await tester.enterText(field, '/');
      await tester.pump();
      expect(chip('ego-browser'), findsOneWidget);
      expect(chip('Deploy-Check'), findsOneWidget);
      expect(chip('disabled-skill'), findsNothing);

      // 대소문자 무관 필터링
      await tester.enterText(field, '/dep');
      await tester.pump();
      expect(chip('Deploy-Check'), findsOneWidget);
      expect(chip('ego-browser'), findsNothing);

      // "/"가 맨 앞이 아니면 표시하지 않음
      await tester.enterText(field, '설명 /ego');
      await tester.pump();
      expect(chip('ego-browser'), findsNothing);

      // 선택 시 입력창에 채우고 목록을 닫음
      await tester.enterText(field, '/ego');
      await tester.pump();
      await tester.tap(chip('ego-browser'));
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '/ego-browser ');
      expect(chip('ego-browser'), findsNothing);
    });

    test('로컬에서 찾은 스킬의 라우팅 지시문에 SKILL.md 경로가 포함된다', () {
      final registry = SkillRegistry(loadDefaults: false)
        ..registerSkill(
          SkillDefinition(
            name: 'deploy-check',
            description: '배포 점검',
            skillMdPath: '/skills/deploy-check/SKILL.md',
            directoryPath: '/skills/deploy-check',
          ),
        );

      expect(
        registry.buildRoutingInstructionForPrompt('/deploy-check 실행해줘'),
        contains('/skills/deploy-check/SKILL.md'),
      );
    });
  });
}
