import 'dart:async';
import 'dart:io';

import 'package:agent_control_center/adapters/antigravity/antigravity_event_parser.dart';
import 'package:agent_control_center/adapters/claude/claude_code_event_parser.dart';
import 'package:agent_control_center/adapters/codex/codex_event_parser.dart';
import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/main.dart';
import 'package:agent_control_center/services/inbox_service.dart';
import 'package:agent_control_center/services/notification_service.dart';
import 'package:agent_control_center/services/permission_center.dart';
import 'package:agent_control_center/services/provider_usage_service.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:agent_control_center/services/trusted_folder_store.dart';
import 'package:agent_control_center/services/workspace_group_store.dart';
import 'package:agent_control_center/ui/theme/mac_theme.dart';
import 'package:agent_control_center/ui/widgets/kv_cache_panel.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackend implements AgentBackend {
  final eventCtrl = StreamController<AgentEvent>.broadcast(sync: true);
  final rawLogCtrl = StreamController<String>.broadcast();

  @override
  BackendType get backendType => BackendType.codex;
  @override
  Stream<AgentEvent> get events => eventCtrl.stream;
  @override
  Stream<String> get rawLogs => rawLogCtrl.stream;
  @override
  String? get remoteConversationId => null;
  @override
  Future<void> start(AgentSessionConfig config) async {}
  @override
  Future<void> send(
    String prompt, {
    List<String> attachments = const [],
  }) async {}
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
  Future<void> dispose() async {}
}

WorkspaceGroup _group(String folder) => WorkspaceGroup(
  id: 'g1',
  name: '그룹',
  folder: folder,
  backend: BackendType.codex,
  model: BackendType.codex.defaultModel,
  effort: BackendType.codex.defaultEffort,
);

TokenUsage _doneUsage(String fixture, List<AgentEvent> Function(String) parse) {
  final events = File(
    'test/fixtures/$fixture',
  ).readAsLinesSync().expand(parse);
  return events.whereType<DoneEvent>().last.usage;
}

void main() {
  group('KV 캐시 사용량', () {
    test('백엔드마다 다른 입력 집계를 캐시 포함 입력으로 맞춘다', () {
      final claude = _doneUsage(
        'claude_stream_sample.jsonl',
        ClaudeCodeEventParser(sessionId: 's', model: 'm').parseLine,
      );
      expect(claude.cachedTokens, 900);
      expect(claude.promptTokens, 120 + 200 + 900);

      final codex = _doneUsage(
        'codex_stream_sample.jsonl',
        CodexEventParser(sessionId: 's', model: 'm').parseLine,
      );
      expect(codex.cachedTokens, 12672);
      expect(codex.promptTokens, 23577);
      expect(codex.cacheHitRate, closeTo(0.537, 0.001));

      final agy = _doneUsage(
        'agy_stream_sample.jsonl',
        AntigravityEventParser(sessionId: 's', model: 'm').parseLine,
      );
      expect(agy.promptTokens, 22686);
      expect(agy.cacheHitRate, 0);
    });

    test('합산해도 적중률이 유지되고 입력이 없으면 0이다', () {
      const a = TokenUsage(cachedTokens: 50, promptTokens: 100);
      const b = TokenUsage(cachedTokens: 150, promptTokens: 300);
      expect((a + b).cacheHitRate, 0.5);
      expect(const TokenUsage().cacheHitRate, 0);
    });
  });

  group('화면', () {
    late Directory temp;
    late TrustedFolderStore trust;
    late WorkspaceGroupStore store;
    late SessionManager manager;
    late _FakeBackend backend;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('acc_stage16_');
      trust = TrustedFolderStore();
      store = WorkspaceGroupStore()..upsert(_group(temp.path));
      manager = SessionManager(trustedFolders: trust, groups: store);
      backend = _FakeBackend();
      manager.createSession(
        sessionId: 's1',
        backendType: BackendType.codex,
        backendOverride: backend,
        workingDirectory: temp.path,
        groupId: 'g1',
      );
    });
    tearDown(() {
      manager.dispose();
      temp.deleteSync(recursive: true);
    });

    Future<void> pumpHome(
      WidgetTester tester, {
      Size size = const Size(1400, 1100),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final notifications = NotificationService(enableOsPlugin: false);
      final inbox = InboxService(
        notificationService: notifications,
        permissionCenter: PermissionCenter(),
      );
      addTearDown(inbox.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ControlCenterHomeScreen(
            sessionManagerOverride: manager,
            notificationServiceOverride: notifications,
            inboxServiceOverride: inbox,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> tap(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    Future<void> openSessionMenu(WidgetTester tester, String item) async {
      await tester.tap(
        find.byKey(const ValueKey('session_card_s1')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tap(tester, item);
    }

    TextField folderField(WidgetTester tester, String key) =>
        tester.widget<TextField>(find.byKey(ValueKey(key)));

    testWidgets('오른쪽 사이드바에 턴이 끝난 세션의 KV 캐시를 표시하고 숨길 수 있다', (tester) async {
      await pumpHome(tester);
      final panel = find.byKey(const ValueKey('kv_cache_panel'));
      expect(panel, findsOneWidget);
      expect(
        tester.getTopLeft(panel).dx,
        greaterThan(
          tester.getTopRight(find.byKey(const ValueKey('session_card_s1'))).dx,
        ),
      );

      backend.eventCtrl.add(
        DoneEvent(
          id: 'd',
          sessionId: 's1',
          backend: BackendType.codex,
          timestamp: DateTime.now(),
          usage: const TokenUsage(cachedTokens: 25, promptTokens: 100),
        ),
      );
      await tester.pumpAndSettle();
      Text text(String key) => tester.widget<Text>(find.byKey(ValueKey(key)));
      expect(text('kv_cache_hit_rate').data, '25.0%');
      expect(text('kv_cache_tokens').data, '25 tok');

      await tap(tester, 'kv_cache_toggle');
      expect(panel, findsNothing);
      await tap(tester, 'kv_cache_toggle');
      expect(panel, findsOneWidget);
    });

    testWidgets('오른쪽 사이드바 그래프가 가장 많이 쓴 백엔드 기준으로 사용량을 그린다', (tester) async {
      LinearProgressIndicator bar(BackendType b) =>
          tester.widget<LinearProgressIndicator>(
            find.byKey(ValueKey('usage_bar_${b.id}')),
          );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                KvCachePanel(
                  session: TokenUsage(totalTokens: 100),
                  usageByBackend: {
                    BackendType.codex: TokenUsage(totalTokens: 400),
                    BackendType.claudeCode: TokenUsage(totalTokens: 100),
                  },
                ),
              ],
            ),
          ),
        ),
      );
      expect(bar(BackendType.codex).value, 1);
      expect(bar(BackendType.claudeCode).value, 0.25);
      expect(bar(BackendType.antigravity).value, 0);
      expect(find.text('100 tok'), findsNWidgets(2));
      expect(find.text('400 tok'), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                KvCachePanel(session: TokenUsage(), usageByBackend: {}),
              ],
            ),
          ),
        ),
      );
      expect(bar(BackendType.codex).value, 0);
    });

    testWidgets('Claude, Codex, Antigravity 공급자 한도와 캐시 적중률을 그래프와 숫자로 표시한다', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      LinearProgressIndicator barByKey(String key) =>
          tester.widget<LinearProgressIndicator>(find.byKey(ValueKey(key)));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 1200,
              child: Row(
                children: [
                  KvCachePanel(
                    session: const TokenUsage(totalTokens: 100),
                    usageByBackend: const {
                      BackendType.claudeCode: TokenUsage(
                        cachedTokens: 40,
                        promptTokens: 100,
                        totalTokens: 150,
                      ),
                      BackendType.codex: TokenUsage(
                        cachedTokens: 75,
                        promptTokens: 100,
                        totalTokens: 300,
                      ),
                      BackendType.antigravity: TokenUsage(
                        cachedTokens: 50,
                        promptTokens: 200,
                        totalTokens: 200,
                      ),
                    },
                    providerUsages: const [
                      ProviderUsage(
                        backend: BackendType.claudeCode,
                        name: 'Claude Code',
                        fiveHour: UsageWindow(42, null),
                        weekly: UsageWindow(18, null),
                      ),
                      ProviderUsage(
                        backend: BackendType.codex,
                        name: 'OpenAI Codex',
                        fiveHour: UsageWindow(60, null),
                        weekly: UsageWindow(30, null),
                        contextUsed: 32000,
                        contextLimit: 128000,
                      ),
                      ProviderUsage(
                        backend: BackendType.antigravity,
                        name: 'Google Antigravity',
                        fiveHour: UsageWindow(25, null),
                        weekly: UsageWindow(10, null),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(barByKey('kv_cache_bar_claude').value, closeTo(0.4, 0.001));
      expect(barByKey('kv_cache_bar_codex').value, closeTo(0.75, 0.001));
      expect(barByKey('kv_cache_bar_agy').value, closeTo(0.25, 0.001));

      expect(
        barByKey('provider_five_hour_bar_claude_Claude Code').value,
        closeTo(0.42, 0.001),
      );
      expect(
        barByKey('provider_weekly_bar_codex_OpenAI Codex').value,
        closeTo(0.30, 0.001),
      );
      expect(
        barByKey('provider_context_bar_codex_OpenAI Codex').value,
        closeTo(0.25, 0.001),
      );
      expect(
        barByKey('provider_five_hour_bar_agy_Google Antigravity').value,
        closeTo(0.25, 0.001),
      );
      expect(find.text('32000/128000 tok'), findsOneWidget);

      // 백엔드 그래프는 백엔드별 고유색, 한도 그래프는 소진율 상태색입니다.
      const mac = MacColors.light;
      expect(
        barByKey('kv_cache_bar_claude').color,
        mac.backendColor(BackendType.claudeCode),
      );
      expect(
        barByKey('kv_cache_bar_codex').color,
        mac.backendColor(BackendType.codex),
      );
      expect(
        barByKey('provider_five_hour_bar_agy_Google Antigravity').color,
        mac.red,
      );
      expect(mac.backendPalette.length, BackendType.values.length);
      expect(mac.backendPalette.toSet().length, BackendType.values.length);
      expect(mac.usageLevelColor(0.49), mac.red);
      expect(mac.usageLevelColor(0.5), mac.orange);
      expect(mac.usageLevelColor(0.79), mac.orange);
      expect(mac.usageLevelColor(0.8), mac.green);
    });

    testWidgets('낮고 좁은 창에서도 사이드바가 넘치지 않는다', (tester) async {
      await pumpHome(tester, size: const Size(860, 500));
      expect(tester.takeException(), isNull);
    });

    testWidgets('그룹에서 만드는 세션은 작업 폴더를 고칠 수 없다', (tester) async {
      await pumpHome(tester);
      await tap(tester, 'new_session_in_group_g1');
      final field = folderField(tester, 'new_session_folder');
      expect(field.enabled, isFalse);
      expect(field.controller!.text, temp.path);
      expect(find.text('작업 폴더는 그룹 폴더를 따릅니다.'), findsOneWidget);

      await tap(tester, 'create_session_button');
      expect(manager.activeSession!.workingDirectory, temp.path);
      expect(trust.folders, isEmpty, reason: '해제한 신뢰를 되살리지 않는다');
    });

    testWidgets('그룹 세션의 메뉴로 만드는 새 세션과 하위 세션도 폴더가 잠긴다', (tester) async {
      await pumpHome(tester);
      await openSessionMenu(tester, 'session_menu_new');
      expect(find.text('새 세션 · 그룹'), findsOneWidget);
      expect(folderField(tester, 'new_session_folder').enabled, isFalse);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();

      await openSessionMenu(tester, 'session_menu_child');
      expect(folderField(tester, 'new_session_folder').enabled, isFalse);
    });

    testWidgets('그룹 세션은 환경 설정과 입력창에서 폴더를 바꿀 수 없다', (tester) async {
      await pumpHome(tester);
      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('workdir_button')),
      );
      expect(button.onPressed, isNull);

      await openSessionMenu(tester, 'session_menu_settings');
      expect(folderField(tester, 'session_settings_folder').enabled, isFalse);
      expect(find.textContaining('그룹 설정에서 바꿀 수 있습니다'), findsOneWidget);
    });

    testWidgets('그룹 밖 세션은 지금처럼 폴더를 바꿀 수 있다', (tester) async {
      manager.createSession(
        sessionId: 'free',
        backendOverride: _FakeBackend(),
        workingDirectory: temp.path,
      );
      await pumpHome(tester);
      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('workdir_button')),
      );
      expect(button.onPressed, isNotNull);
      await tap(tester, 'new_session_button');
      expect(folderField(tester, 'new_session_folder').enabled, isTrue);
    });
  });

  group('그룹 폴더 따르기', () {
    late SessionManager manager;
    late ManagedSession idle;

    setUp(() {
      manager = SessionManager(
        groups: WorkspaceGroupStore()..upsert(_group('/old')),
      );
      idle = manager.createSession(
        backendOverride: _FakeBackend(),
        workingDirectory: '/old',
        groupId: 'g1',
      );
    });
    tearDown(() => manager.dispose());

    test('그룹 세션은 직접 옮길 수 없고 그룹 폴더가 바뀌면 함께 옮겨진다', () {
      manager.updateSessionWorkingDirectory(idle.sessionId, '/other');
      expect(idle.workingDirectory, '/old');

      manager.saveGroup(_group('/new'));
      expect(idle.workingDirectory, '/new');
    });

    test('실행 중인 세션은 옮기지 않고 그룹을 지우면 직접 옮길 수 있다', () {
      idle.status = SessionStatus.running;
      manager.saveGroup(_group('/new'));
      expect(idle.workingDirectory, '/old');

      idle.status = SessionStatus.idle;
      manager.deleteGroup('g1');
      manager.updateSessionWorkingDirectory(idle.sessionId, '/other');
      expect(idle.workingDirectory, '/other');
    });
  });
}
