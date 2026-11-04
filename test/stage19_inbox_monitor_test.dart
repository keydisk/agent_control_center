import 'dart:convert';
import 'dart:io';

import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/services/inbox_service.dart';
import 'package:agent_control_center/services/notification_service.dart';
import 'package:agent_control_center/services/permission_center.dart';
import 'package:agent_control_center/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Spawner implements ProcessSpawner {
  String unreadMail = '';
  bool mailRunning = true;
  int maxRowId = 500;
  List<Map<String, Object?>> rows = const [];
  ProcessResult? forcedFailure;
  final calls = <List<String>>[];

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    calls.add(arguments);
    final failure = forcedFailure;
    if (failure != null) return failure;
    if (executable == 'osascript') {
      final script = arguments.last;
      if (script.contains('whose id is')) {
        final id = RegExp(r'whose id is (\d+)').firstMatch(script)!.group(1);
        return ProcessResult(1, 0, '발신자$id\x1f제목$id\x1f본문$id\n둘째 줄\n', '');
      }
      expect(script, contains('is not running'), reason: 'Mail을 띄우지 않아야 한다');
      return ProcessResult(
        1,
        0,
        mailRunning ? unreadMail : 'ACC_MAIL_NOT_RUNNING',
        '',
      );
    }
    final sql = arguments.last;
    expect(arguments, containsAll(['-readonly', '-json']));
    if (sql.contains('MAX(ROWID)')) {
      return ProcessResult(
        2,
        0,
        jsonEncode([
          {'maxId': maxRowId},
        ]),
        '',
      );
    }
    expect(sql, contains('is_from_me = 0'), reason: '내가 보낸 메시지 제외');
    return ProcessResult(2, 0, rows.isEmpty ? '' : jsonEncode(rows), '');
  }

  @override
  Future<ManagedProcess> spawn(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) => throw UnimplementedError();
}

/// 실제 typedstream의 앞부분과 같은 구조로 본문을 감쌉니다.
String _attributedHex(String text) {
  final body = utf8.encode(text);
  final length = body.length < 0x80
      ? [body.length]
      : [0x81, body.length & 0xFF, body.length >> 8];
  final bytes = [
    ...ascii.encode('streamtyped'),
    0x84,
    0x01,
    0x40,
    0x84,
    0x84,
    0x84,
    ...ascii.encode('NSString'),
    0x01,
    0x94,
    0x84,
    0x01,
    0x2B,
    ...length,
    ...body,
    0x86,
    0x84,
  ];
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  late Directory temp;
  late _Spawner spawner;
  late File stateFile;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('acc_stage19_');
    spawner = _Spawner();
    stateFile = File('${temp.path}/state/inbox.json');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  InboxService service() {
    final inbox = InboxService(
      notificationService: NotificationService(enableOsPlugin: false),
      spawner: spawner,
      stateFile: stateFile,
      customIMessageDbPath: '/tmp/chat.db',
    );
    addTearDown(inbox.dispose);
    return inbox;
  }

  group('Mail.app', () {
    test('처음 본 메일은 알리지 않고 이후 새 메일만 오래된 순으로 요약한다', () async {
      spawner.unreadMail = '10, 20';
      final inbox = service();
      expect(await inbox.fetchFromMacOsMailApp(), isEmpty);

      spawner.unreadMail = '10,20,40,30';
      final items = await inbox.fetchFromMacOsMailApp();
      expect(items.map((i) => i.subject), ['제목30', '제목40']);
      expect(items.first.sender, '발신자30');
      expect(await inbox.fetchFromMacOsMailApp(), isEmpty);
    });

    test('첫 메일을 읽지 않아도 뒤에 온 메일을 놓치지 않는다', () async {
      spawner.unreadMail = '10';
      final inbox = service();
      await inbox.fetchFromMacOsMailApp();
      spawner.unreadMail = '10,11';
      expect(await inbox.fetchFromMacOsMailApp(), hasLength(1));
    });

    test('다시 시작해도 본 메일을 또 알리지 않는다', () async {
      spawner.unreadMail = '10';
      await service().fetchFromMacOsMailApp();
      spawner.unreadMail = '10,11';
      final restarted = service();
      final items = await restarted.fetchFromMacOsMailApp();
      expect(items.single.subject, '제목11');
      expect(await service().fetchFromMacOsMailApp(), isEmpty);
    });

    test('Mail이 꺼져 있으면 기준을 잡지 않고 켜진 뒤의 첫 조회를 기준으로 삼는다', () async {
      spawner.mailRunning = false;
      final inbox = service();
      expect(await inbox.fetchFromMacOsMailApp(), isEmpty);
      spawner
        ..mailRunning = true
        ..unreadMail = '10';
      expect(await inbox.fetchFromMacOsMailApp(), isEmpty, reason: '기준 조회');
      expect(
        spawner.calls.every((c) => !c.last.contains('whose id is')),
        isTrue,
      );
    });

    test('읽은 메일은 기록에서 빠져 파일이 커지지 않는다', () async {
      spawner.unreadMail = '10,11';
      final inbox = service();
      await inbox.fetchFromMacOsMailApp();
      spawner.unreadMail = '11';
      await inbox.fetchFromMacOsMailApp();
      expect(jsonDecode(stateFile.readAsStringSync())['mailIds'], [11]);
    });

    test('권한 오류는 안내로 남고 성공하면 사라진다', () async {
      final inbox = service();
      spawner.forcedFailure = ProcessResult(
        1,
        1,
        '',
        'Not authorized to send Apple events to Mail. (-1743)',
      );
      expect(await inbox.fetchFromMacOsMailApp(), isEmpty);
      final error = inbox.sourceErrors[InboxSourceType.macosMail]!;
      expect(error, contains('자동화'));
      expect(error, contains('-1743'));

      spawner.forcedFailure = null;
      await inbox.fetchFromMacOsMailApp();
      expect(inbox.sourceErrors, isEmpty);
    });
  });

  group('iMessage', () {
    test('처음에는 위치만 잡고 이후 받은 메시지만 요약한다', () async {
      final inbox = service();
      expect(await inbox.fetchFromMacOsIMessage(), isEmpty);
      expect(spawner.calls.last.last, contains('MAX(ROWID)'));

      spawner.rows = const [
        {'rowId': 501, 'sender': '+8210', 'text': '첫째', 'body': ''},
        {'rowId': 502, 'sender': '', 'text': '둘째', 'body': null},
      ];
      final items = await inbox.fetchFromMacOsIMessage();
      expect(items, hasLength(2));
      expect(items.first.sender, '+8210');
      expect(items.last.sender, 'iMessage 발신자');

      spawner.rows = const [];
      await inbox.fetchFromMacOsIMessage();
      expect(spawner.calls.last.last, contains('ROWID > 502'));
    });

    test('text가 비면 attributedBody를 해독하고 글이 없으면 건너뛴다', () async {
      final inbox = service();
      await inbox.fetchFromMacOsIMessage();
      spawner.rows = [
        {
          'rowId': 501,
          'sender': 'a',
          'text': '',
          'body': _attributedHex('[긴급] 서버 확인'),
        },
        {'rowId': 502, 'sender': 'b', 'text': '', 'body': ''},
      ];
      final items = await inbox.fetchFromMacOsIMessage();
      expect(items.single.urgency, UrgencyLevel.critical);

      spawner.rows = const [];
      await inbox.fetchFromMacOsIMessage();
      expect(spawner.calls.last.last, contains('ROWID > 502'));
    });

    test('다시 시작해도 위치를 이어간다', () async {
      await service().fetchFromMacOsIMessage();
      expect(jsonDecode(stateFile.readAsStringSync())['imessageRowId'], 500);
      await service().fetchFromMacOsIMessage();
      expect(spawner.calls.last.last, contains('ROWID > 500'));
    });

    test('요약이 실패하면 그 메시지부터 다시 시도한다', () async {
      var fail = false;
      final inbox = InboxService(
        notificationService: NotificationService(enableOsPlugin: false),
        spawner: spawner,
        stateFile: stateFile,
        customSummarizer: (raw, sanitized, backend, model) async {
          if (fail) throw StateError('요약 실패');
          return InboxSummaryItem(
            id: raw.id,
            source: raw.source,
            sender: raw.sender,
            subject: raw.subject,
            threeLineSummary: const ['1', '2', '3'],
            requiredAction: '',
            urgency: UrgencyLevel.low,
            summarizedByBackend: backend,
            summarizedByModel: model,
            forwardedSnippet: sanitized,
            createdAt: DateTime.now(),
          );
        },
      );
      addTearDown(inbox.dispose);
      await inbox.fetchFromMacOsIMessage(customDbPath: '/tmp/chat.db');
      spawner.rows = const [
        {'rowId': 501, 'sender': 'a', 'text': '첫째', 'body': ''},
      ];
      fail = true;
      await expectLater(inbox.fetchFromMacOsIMessage(), throwsStateError);
      fail = false;
      spawner.rows = const [];
      await inbox.fetchFromMacOsIMessage();
      expect(spawner.calls.last.last, contains('ROWID > 500'));
    });

    test('디스크 접근이 막히면 안내를 남기고 기준을 잡지 않는다', () async {
      spawner.forcedFailure = ProcessResult(2, 1, '', 'authorization denied');
      final inbox = service();
      expect(await inbox.fetchFromMacOsIMessage(), isEmpty);
      expect(
        inbox.sourceErrors[InboxSourceType.imessage],
        contains('전체 디스크 접근'),
      );
      expect(stateFile.existsSync(), isFalse);
    });

    test('attributedBody 해독은 긴 본문과 손상된 값을 처리한다', () {
      final long = '가' * 100;
      expect(InboxService.decodeAttributedBody(_attributedHex(long)), long);
      expect(InboxService.decodeAttributedBody(''), '');
      expect(InboxService.decodeAttributedBody('00FF'), '');
      expect(
        InboxService.decodeAttributedBody(
          _attributedHex('짧음').substring(0, 60),
        ),
        '',
      );
    });

    test('손상된 상태 파일은 기준을 다시 잡는다', () async {
      stateFile
        ..createSync(recursive: true)
        ..writeAsStringSync('{"imessageRowId":"x"}');
      await service().fetchFromMacOsIMessage();
      expect(spawner.calls.last.last, contains('MAX(ROWID)'));
    });
  });

  group('OS 권한 저장', () {
    test('항상 범위만 다음 실행까지 유지하고 철회도 반영한다', () {
      final file = File('${temp.path}/sub/os.json');
      PermissionCenter(osPermissionFile: file)
        ..setOsPermissionScope(
          OsPermissionType.fullDiskAccess,
          ApprovalScope.always,
        )
        ..setOsPermissionScope(
          OsPermissionType.automationAppleEvents,
          ApprovalScope.session,
        );

      var loaded = PermissionCenter(osPermissionFile: file);
      expect(
        loaded.osPermissions[OsPermissionType.fullDiskAccess],
        ApprovalScope.always,
      );
      expect(
        loaded.osPermissions[OsPermissionType.automationAppleEvents],
        ApprovalScope.denied,
      );

      loaded.setOsPermissionScope(
        OsPermissionType.fullDiskAccess,
        ApprovalScope.denied,
      );
      loaded = PermissionCenter(osPermissionFile: file);
      expect(
        loaded.osPermissions[OsPermissionType.fullDiskAccess],
        ApprovalScope.denied,
      );
    });

    test('손상된 파일은 권한 없음으로 읽는다', () {
      final file = File('${temp.path}/os.json')..writeAsStringSync('{"x":1}');
      final loaded = PermissionCenter(osPermissionFile: file);
      expect(
        loaded.osPermissions.values.every((s) => s == ApprovalScope.denied),
        isTrue,
      );
    });
  });

  group('확인하지 못한 이유 표시', () {
    test('꺼진 소스는 조용히 건너뛰지 않고 이유를 남기며 허용하면 사라진다', () async {
      final perms = PermissionCenter();
      final inbox = InboxService(
        notificationService: NotificationService(enableOsPlugin: false),
        spawner: spawner,
        permissionCenter: perms,
        customIMessageDbPath: '/tmp/chat.db',
      );
      addTearDown(inbox.dispose);

      await inbox.pollAllAuthorizedSourcesOnce();
      expect(
        inbox.sourceErrors.keys,
        containsAll(InboxSourceType.values.where((s) => s.isSupported)),
      );
      expect(spawner.calls, isEmpty);

      perms.setOsPermissionScope(
        OsPermissionType.fullDiskAccess,
        ApprovalScope.session,
      );
      await inbox.pollAllAuthorizedSourcesOnce();
      expect(inbox.sourceErrors, isNot(contains(InboxSourceType.imessage)));
    });

    test('Mail이 꺼져 있으면 이유를 남긴다', () async {
      spawner.mailRunning = false;
      final inbox = service();
      await inbox.fetchFromMacOsMailApp();
      expect(inbox.sourceErrors[InboxSourceType.macosMail], contains('꺼져'));
    });

    test('계정 허용이 재시작 후에도 유지되고 철회하면 사라진다', () async {
      final file = File('${temp.path}/perms.json');
      final vault = SecureCredentialVault();
      final perms = PermissionCenter(
        osPermissionFile: file,
        credentialVault: vault,
      );
      await perms.setAccountScopePermission(
        scopeId: 'telegram_bot',
        scope: ApprovalScope.always,
      );
      ApprovalScope reloaded() => PermissionCenter(
        osPermissionFile: file,
        credentialVault: vault,
      ).accountScopes.firstWhere((a) => a.id == 'telegram_bot').grantedScope;
      expect(reloaded(), ApprovalScope.always);

      await perms.setAccountScopePermission(
        scopeId: 'telegram_bot',
        scope: ApprovalScope.denied,
      );
      expect(reloaded(), ApprovalScope.denied);
    });
  });
}
