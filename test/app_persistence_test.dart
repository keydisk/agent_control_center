import 'dart:convert';
import 'dart:io';

import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/main.dart';
import 'package:agent_control_center/services/app_settings_store.dart';
import 'package:agent_control_center/services/inbox_service.dart';
import 'package:agent_control_center/services/notification_service.dart';
import 'package:agent_control_center/services/permission_center.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:agent_control_center/services/skill_registry.dart';
import 'package:agent_control_center/services/storage_service.dart';
import 'package:agent_control_center/services/workspace_group_store.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

WorkspaceGroup _group(String id, {String name = '그룹'}) => WorkspaceGroup(
  id: id,
  name: name,
  folder: '/tmp/$id',
  backend: BackendType.codex,
  model: BackendType.codex.defaultModel,
  effort: ReasoningEffort.high,
  instructions: '$id 지침',
);

SessionSnapshot _snapshot(String id, {String? groupId}) => SessionSnapshot(
  id: id,
  title: '기록 $id',
  backend: BackendType.claudeCode,
  lastTurn: '사용자: 질문',
  updatedAt: DateTime(2026, 11, 4),
  groupId: groupId,
);

void main() {
  late Directory temp;
  late File groupsFile;
  late File historyFile;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('acc_persist_');
    groupsFile = File('${temp.path}/workspace_groups.json');
    historyFile = File('${temp.path}/workspace_groups_history.json');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  group('작업 그룹 저장', () {
    test('생성·수정·삭제와 기본 지침이 재시작 후에도 유지된다', () {
      WorkspaceGroupStore(file: groupsFile)
        ..upsert(_group('a'), defaultInstructions: '공통')
        ..upsert(_group('b'));
      expect(WorkspaceGroupStore(file: groupsFile).groups.map((g) => g.id), [
        'a',
        'b',
      ]);

      WorkspaceGroupStore(file: groupsFile)
        ..upsert(_group('a', name: '새 이름'))
        ..remove('b');
      final loaded = WorkspaceGroupStore(file: groupsFile);
      expect(loaded.groups.single.name, '새 이름');
      expect(loaded.groups.single.effort, ReasoningEffort.high);
      expect(loaded.defaultInstructions, '공통');
      expect(loaded.instructionsFor('a'), '공통\n\na 지침');
    });

    test('그룹을 모르는 다른 실행본이 기록을 남겨도 그룹이 지워지지 않는다', () {
      final stale = WorkspaceGroupStore(file: groupsFile);
      WorkspaceGroupStore(file: groupsFile).upsert(_group('a'));

      stale.recordSession(_snapshot('s1'));

      final loaded = WorkspaceGroupStore(file: groupsFile);
      expect(loaded.groups.single.id, 'a');
      expect(loaded.searchSessions().single.id, 's1');
    });

    test('세션 기록은 그룹 파일에 들어가지 않고 그룹별 기록도 복원된다', () {
      WorkspaceGroupStore(file: groupsFile)
        ..upsert(_group('a'))
        ..recordSession(_snapshot('s1', groupId: 'a'));

      final saved = jsonDecode(groupsFile.readAsStringSync()) as Map;
      expect(saved.keys, unorderedEquals(['defaultInstructions', 'groups']));
      final loaded = WorkspaceGroupStore(file: groupsFile);
      expect(loaded.snapshotsFor('a').single.id, 's1');
      expect(temp.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('기록 파일이 깨져도 그룹은 남고 깨진 파일은 보관한다', () {
      WorkspaceGroupStore(file: groupsFile)
        ..upsert(_group('a'))
        ..recordSession(_snapshot('s1'));
      historyFile.writeAsStringSync('{"sessions": [');

      final loaded = WorkspaceGroupStore(file: groupsFile)
        ..recordSession(_snapshot('s2'));

      expect(loaded.groups.single.id, 'a');
      expect(File('${historyFile.path}.corrupt').existsSync(), isTrue);
      expect(
        WorkspaceGroupStore(file: groupsFile).searchSessions().single.id,
        's2',
      );
    });

    test('읽을 수 없는 기록 항목은 그 항목만 건너뛴다', () {
      historyFile.writeAsStringSync(
        jsonEncode({
          'sessions': [
            {'id': 1},
            _snapshot('ok').toJson(),
          ],
        }),
      );
      expect(
        WorkspaceGroupStore(file: groupsFile).searchSessions().single.id,
        'ok',
      );
    });

    test('깨진 그룹 파일은 빈 상태로 덮어쓰지 않고 보관한다', () {
      groupsFile.writeAsStringSync('{"groups": [');
      WorkspaceGroupStore(file: groupsFile).upsert(_group('new'));
      expect(
        File('${groupsFile.path}.corrupt').readAsStringSync(),
        '{"groups": [',
      );
    });

    test('예전 형식 파일은 그룹과 기록을 잃지 않고 옮긴다', () {
      groupsFile.writeAsStringSync(
        jsonEncode({
          'defaultInstructions': '공통',
          'groups': [
            {
              ..._group('a').toJson(),
              'snapshots': [_snapshot('in_group', groupId: 'a').toJson()],
            },
          ],
          'sessions': [_snapshot('free').toJson()],
        }),
      );

      final migrated = WorkspaceGroupStore(file: groupsFile);
      expect(migrated.groups.single.id, 'a');
      expect(migrated.snapshotsFor('a').single.id, 'in_group');
      expect(migrated.searchSessions(), hasLength(2));
      expect(groupsFile.readAsStringSync(), isNot(contains('free')));

      final reloaded = WorkspaceGroupStore(file: groupsFile);
      expect(reloaded.defaultInstructions, '공통');
      expect(reloaded.snapshotsFor('a').single.id, 'in_group');
      expect(reloaded.searchSessions(), hasLength(2));
    });
  });

  group('세션 기록의 설정', () {
    test('지침과 권한 모드를 복원하되 권한 무시는 복원하지 않는다', () {
      SessionSnapshot roundTrip(PermissionMode mode) =>
          SessionSnapshot.fromJson(
            jsonDecode(
              jsonEncode(
                SessionSnapshot(
                  id: 's',
                  title: 't',
                  backend: BackendType.codex,
                  lastTurn: '',
                  updatedAt: DateTime(2026),
                  instructions: '세션 지침',
                  permissionMode: mode,
                ).toJson(),
              ),
            ) as Map<String, dynamic>,
          );

      final plan = roundTrip(PermissionMode.plan);
      expect(plan.instructions, '세션 지침');
      expect(plan.permissionMode, PermissionMode.plan);
      expect(roundTrip(PermissionMode.bypass).permissionMode, isNull);
    });
  });

  group('앱 설정 저장', () {
    late File file;
    setUp(() => file = File('${temp.path}/sub/settings.json'));

    test('기본값을 돌려주고 변경한 값은 재시작 후에도 유지된다', () {
      final defaults = AppSettingsStore(file: file);
      expect(defaults.showSessionSidebar, isTrue);
      expect(defaults.showKvCachePanel, isTrue);
      expect(defaults.showRawLogs, isFalse);
      expect(defaults.autoOrchestrate, isTrue);
      expect(defaults.device, TargetDeviceType.macosDesktop);
      expect(defaults.permissionMode, isNull);
      expect(defaults.backend, isNull);

      defaults
        ..showSessionSidebar = false
        ..showKvCachePanel = false
        ..showRawLogs = true
        ..autoOrchestrate = false
        ..device = TargetDeviceType.values.last
        ..permissionMode = PermissionMode.plan
        ..backend = BackendType.codex
        ..workingDirectory = temp.path
        ..setGroupCollapsed('a', true)
        ..setSkillDisabled('skill', true);

      final loaded = AppSettingsStore(file: file);
      expect(loaded.showSessionSidebar, isFalse);
      expect(loaded.showKvCachePanel, isFalse);
      expect(loaded.showRawLogs, isTrue);
      expect(loaded.autoOrchestrate, isFalse);
      expect(loaded.device, TargetDeviceType.values.last);
      expect(loaded.permissionMode, PermissionMode.plan);
      expect(loaded.backend, BackendType.codex);
      expect(loaded.workingDirectory, temp.path);
      expect(loaded.isGroupCollapsed('a'), isTrue);
      expect(loaded.isSkillDisabled('skill'), isTrue);

      loaded
        ..setGroupCollapsed('a', false)
        ..setSkillDisabled('skill', false);
      final again = AppSettingsStore(file: file);
      expect(again.isGroupCollapsed('a'), isFalse);
      expect(again.isSkillDisabled('skill'), isFalse);
    });

    test('권한 무시는 저장하지 않고, 파일에 있어도 복원하지 않는다', () {
      AppSettingsStore(file: file)
        ..permissionMode = PermissionMode.acceptEdits
        ..permissionMode = PermissionMode.bypass;
      expect(
        AppSettingsStore(file: file).permissionMode,
        PermissionMode.acceptEdits,
      );

      file.writeAsStringSync('{"permissionMode":"bypass"}');
      expect(AppSettingsStore(file: file).permissionMode, isNull);
    });

    test('사라진 폴더는 돌려주지 않고 손상된 파일은 기본값으로 읽는다', () {
      file
        ..createSync(recursive: true)
        ..writeAsStringSync('{"workingDirectory":"/no/such/folder"}');
      expect(AppSettingsStore(file: file).workingDirectory, isNull);

      file.writeAsStringSync('[1');
      expect(AppSettingsStore(file: file).showSessionSidebar, isTrue);
    });

    test('스킬을 끈 상태가 다시 등록해도 유지된다', () {
      SkillDefinition skill() => SkillDefinition(
        name: 'my_skill',
        description: '',
        skillMdPath: '',
        directoryPath: '',
      );
      SkillRegistry(loadDefaults: false, settings: AppSettingsStore(file: file))
        ..registerSkill(skill())
        ..setSkillEnabled('my_skill', false);

      final reloaded = SkillRegistry(
        loadDefaults: false,
        settings: AppSettingsStore(file: file),
      )..registerSkill(skill());
      expect(reloaded.getSkill('my_skill')!.isEnabled, isFalse);
    });
  });

  test("'항상' 권한 규칙이 파일 DB에서 복원된다", () async {
    final dbFile = File('${temp.path}/acc.sqlite');
    final db = AppDriftDatabase(NativeDatabase(dbFile));
    PermissionCenter(database: db).recordDecision(
      ApprovalRequestData(
        id: 'r1',
        sessionId: 's1',
        backend: BackendType.codex,
        toolName: 'Write',
        arguments: const {},
        category: ApprovalCategory.fileWrite,
        reason: '',
        isDestructive: false,
        createdAt: DateTime(2026),
        targetResource: '/tmp/a',
      ),
      const ApprovalDecision(
        requestId: 'r1',
        approved: true,
        scope: ApprovalScope.always,
      ),
    );
    await db.loadPermissionRules();
    await db.close();

    final reopened = AppDriftDatabase(NativeDatabase(dbFile));
    addTearDown(reopened.close);
    final center = PermissionCenter(database: reopened);
    await center.loadFromDatabase();
    expect(center.rules.single.toolName, 'Write');
    expect(center.rules.single.scope, ApprovalScope.always);
  });

  group('재시작한 앱 화면', () {
    late File settingsFile;

    setUp(() => settingsFile = File('${temp.path}/settings.json'));

    Future<SessionManager> pumpHome(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final manager = SessionManager(
        groups: WorkspaceGroupStore(file: groupsFile),
      );
      addTearDown(manager.dispose);
      final notifications = NotificationService(enableOsPlugin: false);
      final inbox = InboxService(
        notificationService: notifications,
        permissionCenter: PermissionCenter(),
      );
      addTearDown(inbox.dispose);
      await tester.pumpWidget(
        MaterialApp(
          // 재시작마다 새 화면 상태로 시작합니다.
          key: UniqueKey(),
          home: ControlCenterHomeScreen(
            sessionManagerOverride: manager,
            notificationServiceOverride: notifications,
            inboxServiceOverride: inbox,
            settingsOverride: AppSettingsStore(file: settingsFile),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return manager;
    }

    Future<void> tap(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('그룹이 기록이 아닌 실제 항목으로 바로 보인다', (tester) async {
      WorkspaceGroupStore(file: groupsFile).upsert(_group('a', name: '내 그룹'));

      await pumpHome(tester);

      expect(find.byKey(const ValueKey('group_tile_a')), findsOneWidget);
      expect(find.text('내 그룹'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('new_session_in_group_a')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.history), findsNothing);
    });

    testWidgets('패널·자동 오케스트레이션·그룹 접힘이 재시작 후 유지된다', (tester) async {
      WorkspaceGroupStore(file: groupsFile).upsert(_group('a', name: '내 그룹'));
      await pumpHome(tester);
      await tap(tester, 'raw_log_toggle');
      await tap(tester, 'kv_cache_toggle');
      await tap(tester, 'auto_orchestrate_switch');
      await tester.tap(find.text('내 그룹'));
      await tester.pumpAndSettle();

      await pumpHome(tester);

      final settings = AppSettingsStore(file: settingsFile);
      expect(settings.showRawLogs, isTrue);
      expect(settings.showKvCachePanel, isFalse);
      expect(settings.autoOrchestrate, isFalse);
      expect(settings.isGroupCollapsed('a'), isTrue);
      expect(find.text('원본 JSON 스트림 로그 (Raw Logs)'), findsOneWidget);
      final tile = tester.widget<ExpansionTile>(
        find.byKey(const ValueKey('group_tile_a')),
      );
      expect(tile.initiallyExpanded, isFalse);

      await tap(tester, 'toggle_sidebar_button');
      await pumpHome(tester);
      expect(find.byKey(const ValueKey('group_tile_a')), findsNothing);
    });

    testWidgets('권한 모드를 새 세션 기본값으로 기억하되 권한 무시는 기억하지 않는다', (tester) async {
      final manager = await pumpHome(tester);
      await tap(tester, 'permission_mode_button');
      await tap(tester, 'permission_mode_plan');
      expect(manager.defaultPermissionMode, PermissionMode.plan);

      await tap(tester, 'permission_mode_button');
      await tap(tester, 'permission_mode_bypass');
      await tap(tester, 'confirm_bypass_mode_button');

      expect(manager.activeSession!.permissionMode, PermissionMode.bypass);
      expect(manager.defaultPermissionMode, PermissionMode.plan);
      expect(
        AppSettingsStore(file: settingsFile).permissionMode,
        PermissionMode.plan,
      );
    });

    testWidgets('마지막 백엔드와 폴더로 첫 세션을 시작한다', (tester) async {
      AppSettingsStore(file: settingsFile)
        ..backend = BackendType.codex
        ..workingDirectory = temp.path;

      final manager = await pumpHome(tester);

      expect(manager.activeSession!.backendType, BackendType.codex);
      expect(manager.activeSession!.workingDirectory, temp.path);
    });
  });
}
