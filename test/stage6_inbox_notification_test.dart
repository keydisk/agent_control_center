import 'dart:convert';
import 'dart:io';

import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/main.dart';
import 'package:agent_control_center/services/inbox_service.dart';
import 'package:agent_control_center/services/notification_service.dart';
import 'package:agent_control_center/services/permission_center.dart';
import 'package:agent_control_center/ui/screens/inbox_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeInboxProcessSpawner implements ProcessSpawner {
  String mailOutput = '101|||boss@company.com|||[긴급] 서버 점검 승인|||즉시 확인 바람';
  String imessageOutput = '501|||+821012345678|||배포 완료되었나요?';

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    if (executable == 'osascript') {
      return ProcessResult(1, 0, mailOutput, '');
    }
    if (executable == 'sqlite3') {
      return ProcessResult(2, 0, imessageOutput, '');
    }
    return ProcessResult(3, 1, '', 'not found');
  }

  @override
  Future<ManagedProcess> spawn(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    throw UnimplementedError();
  }
}

void main() {
  group('6단계: Inbox 요약 및 알림 (InboxService, NotificationService, 딥링크)', () {
    test('원문 외부 모델 전송 범위 필터링, 핵심 3줄 요약 생성, OS 알림 기록 및 카카오톡 불가 처리가 동작한다', () async {
      final notificationService = NotificationService(enableOsPlugin: false);
      final inboxService = InboxService(
        notificationService: notificationService,
      );

      // 기본 경량 모델 확인
      expect(inboxService.summaryBackend, BackendType.antigravity);
      expect(inboxService.summaryModel, 'gemini-3-flash');

      // 1) 제목만 전송 정책 설정 후 긴 본문 입력
      inboxService.updateForwardingPolicy(ContentForwardingPolicy.subjectOnly);
      final summary1 = await inboxService.ingestAndSummarize(
        InboxMessageRaw(
          id: 'msg_1',
          source: InboxSourceType.gmail,
          sender: 'cto@company.com',
          subject: '[긴급] 보안 패치 배포 승인',
          body: '절대 외부 모델로 나가면 안 되는 기밀 본문 내용입니다.',
          receivedAt: DateTime.now(),
        ),
      );

      expect(summary1.threeLineSummary.length, 3);
      expect(summary1.urgency, UrgencyLevel.critical);
      expect(summary1.requiredAction, isNotEmpty);
      expect(
        summary1.forwardedSnippet,
        isNot(contains('절대 외부 모델로 나가면 안 되는 기밀 본문')),
      );
      expect(notificationService.history.length, 1);
      expect(
        notificationService.history.first.deepLink.targetId,
        summary1.id,
      );

      // 2) 앞 200자까지만 전송 정책 검증
      inboxService.updateForwardingPolicy(
        ContentForwardingPolicy.first200Chars,
      );
      final longBody = 'A' * 350;
      final summary2 = await inboxService.ingestAndSummarize(
        InboxMessageRaw(
          id: 'msg_2',
          source: InboxSourceType.slack,
          sender: '@pm',
          subject: '주간 스프린트 안내',
          body: longBody,
          receivedAt: DateTime.now(),
        ),
      );
      expect(summary2.forwardedSnippet, contains('...(후략)'));
      expect(summary2.forwardedSnippet, isNot(contains('A' * 250)));

      // 3) 카카오톡 개인 채팅은 공식 공개 읽기 API 미제공으로 UnsupportedError 발생
      expect(
        () => inboxService.ingestAndSummarize(
          InboxMessageRaw(
            id: 'kakao_1',
            source: InboxSourceType.kakaoTalk,
            sender: '친구',
            subject: '개인 톡',
            body: '내용',
            receivedAt: DateTime.now(),
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('권한이 허용된 소스에서 새 메일·메시지를 실시간/주기적으로 자동 감지하고 중복 메시지는 건너뛴다', () async {
      final notificationService = NotificationService(enableOsPlugin: false);
      final permissionCenter = PermissionCenter();
      final spawner = _FakeInboxProcessSpawner();
      final inboxService = InboxService(
        notificationService: notificationService,
        permissionCenter: permissionCenter,
        spawner: spawner,
      );
      addTearDown(inboxService.dispose);

      // 권한 미허용 상태에서는 자동 스캔 시 아무것도 가져오지 않음
      final initialScan = await inboxService.pollAllAuthorizedSourcesOnce();
      expect(initialScan, isEmpty);

      // macOS Mail(자동화 권한) 및 iMessage(Full Disk Access) 권한 허용
      permissionCenter.setOsPermissionScope(
        OsPermissionType.automationAppleEvents,
        ApprovalScope.always,
      );
      permissionCenter.setOsPermissionScope(
        OsPermissionType.fullDiskAccess,
        ApprovalScope.always,
      );

      // 첫 번째 자동 스캔 -> 새 메일 1건 + 새 iMessage 1건 자동 감지 및 요약!
      final firstScan = await inboxService.pollAllAuthorizedSourcesOnce();
      expect(firstScan.length, 2);
      expect(inboxService.summaries.length, 2);

      // 동일한 메시지 ID가 유지될 때 두 번째 자동 스캔 -> 중복 감지 방지(0건)
      final secondScan = await inboxService.pollAllAuthorizedSourcesOnce();
      expect(secondScan, isEmpty);
      expect(inboxService.summaries.length, 2);

      // 새로운 iMessage(ROWID 502) 도착 시 자동 스캔 -> 신규 1건만 정확히 감지!
      spawner.imessageOutput = '502|||+821099998888|||[긴급] 신규 장애 알림';
      final thirdScan = await inboxService.pollAllAuthorizedSourcesOnce();
      expect(thirdScan.length, 1);
      expect(thirdScan.single.source, InboxSourceType.imessage);
      expect(inboxService.summaries.length, 3);
    });

    test('Telegram Bot API 새 메시지를 요약하고 offset을 전진시키며 실패한 메시지는 재시도한다', () async {
      final requests = <Uri>[];
      var responseBody = jsonEncode({
        'ok': true,
        'result': [
          {
            'update_id': 10,
            'message': {
              'from': {'first_name': '주영', 'last_name': '최'},
              'chat': {'id': 1, 'type': 'private'},
              'text': '[긴급] 서버 장애 확인 부탁드립니다',
            },
          },
          {
            'update_id': 11,
            'message': {
              'from': {'first_name': '봇 사용자'},
              'chat': {'id': -5, 'title': '개발팀'},
              'caption': '배포 스크린샷',
            },
          },
          // 텍스트 없는 업데이트는 요약 없이 건너뛰되 offset은 전진
          {
            'update_id': 12,
            'message': {'sticker': {}},
          },
        ],
      });
      var failSummarizer = false;
      final inboxService = InboxService(
        httpClient: MockClient((request) async {
          requests.add(request.url);
          return http.Response.bytes(utf8.encode(responseBody), 200);
        }),
        customSummarizer: (raw, sanitized, backend, model) async {
          if (failSummarizer) throw StateError('요약 실패');
          return InboxSummaryItem(
            id: raw.id,
            source: raw.source,
            sender: raw.sender,
            subject: raw.subject,
            threeLineSummary: const ['1', '2', '3'],
            requiredAction: '확인',
            urgency: UrgencyLevel.medium,
            summarizedByBackend: backend,
            summarizedByModel: model,
            forwardedSnippet: sanitized,
            createdAt: DateTime.now(),
          );
        },
      );
      addTearDown(inboxService.dispose);

      final first = await inboxService.fetchFromTelegramBotApi(
        botToken: '123:abc',
      );
      expect(first.length, 2);
      expect(first[0].sender, '주영 최');
      expect(first[0].subject, 'Telegram 개인 메시지');
      expect(first[1].sender, '봇 사용자');
      expect(first[1].subject, 'Telegram 개발팀 메시지');
      expect(first[1].forwardedSnippet, contains('배포 스크린샷'));
      expect(requests.single.path, '/bot123:abc/getUpdates');
      expect(requests.single.queryParameters.containsKey('offset'), isFalse);

      // 다음 조회는 마지막 업데이트 다음부터, 요약 실패 시 offset 유지 후 재시도
      failSummarizer = true;
      responseBody = jsonEncode({
        'ok': true,
        'result': [
          {
            'update_id': 13,
            'message': {'text': '재시도 대상'},
          },
        ],
      });
      await expectLater(
        inboxService.fetchFromTelegramBotApi(botToken: '123:abc'),
        throwsStateError,
      );
      expect(requests.last.queryParameters['offset'], '13');

      failSummarizer = false;
      final retried = await inboxService.fetchFromTelegramBotApi(
        botToken: '123:abc',
      );
      expect(requests.last.queryParameters['offset'], '13');
      expect(retried.single.sender, 'Telegram 사용자');

      final afterRetry = await inboxService.fetchFromTelegramBotApi(
        botToken: '123:abc',
      );
      expect(requests.last.queryParameters['offset'], '14');
      expect(afterRetry, isEmpty); // 응답 고정 상태에서도 중복 요약 안 함
    });

    test('Telegram API 오류 응답과 HTTP 실패는 토큰을 노출하지 않는 예외로 처리한다', () async {
      Future<void> expectFailure(http.Response response) async {
        final inboxService = InboxService(
          httpClient: MockClient((_) async => response),
        );
        addTearDown(inboxService.dispose);
        await expectLater(
          inboxService.fetchFromTelegramBotApi(botToken: 'secret-token'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              isNot(contains('secret-token')),
            ),
          ),
        );
      }

      await expectFailure(http.Response('{"ok":false}', 401));
      await expectFailure(
        http.Response('{"ok":false,"description":"Conflict"}', 200),
      );
    });

    testWidgets('Telegram 수신 요약 테스트 버튼을 누르면 Telegram 요약 항목이 표시된다', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final notificationService = NotificationService(enableOsPlugin: false);
      final inboxService = InboxService(
        notificationService: notificationService,
      );
      addTearDown(inboxService.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InboxSummaryDialog(
              inboxService: inboxService,
              notificationService: notificationService,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('simulate_telegram_button')));
      await tester.pumpAndSettle();

      expect(inboxService.summaries.single.source, InboxSourceType.telegram);
      expect(find.textContaining('팀장님 (Telegram)'), findsWidgets);
    });

    testWidgets('푸시 알림 탭 시 딥링크로 Inbox 요약 상세 화면이 열리고 핵심 3줄과 모바일 설계안을 표시한다', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final notificationService = NotificationService(enableOsPlugin: false);
      final inboxService = InboxService(
        notificationService: notificationService,
      );

      final summary = await inboxService.ingestAndSummarize(
        InboxMessageRaw(
          id: 'gmail_deep_1',
          source: InboxSourceType.gmail,
          sender: 'lead@company.com',
          subject: '[긴급] DB 마이그레이션 점검 요청',
          body: '오늘 밤 점검 전에 스키마 변경 내역을 확인해 주세요.',
          receivedAt: DateTime.now(),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ControlCenterHomeScreen(
            inboxServiceOverride: inboxService,
            notificationServiceOverride: notificationService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 알림 탭(딥링크) 트리거 -> InboxSummaryDialog가 자동으로 열리고 해당 요약 상세 표시
      notificationService.triggerDeepLinkTap(
        notificationService.history.first.deepLink,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(ValueKey('inbox_detail_${summary.id}')),
        findsOneWidget,
      );
      expect(find.textContaining('핵심 3줄 요약:'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('kakaotalk_unsupported_chip')),
        findsOneWidget,
      );

      // 모바일 원격 알림(FCM/APNs) 설계안 토글 확인
      await tester.tap(
        find.byKey(const ValueKey('toggle_mobile_relay_spec')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile_relay_spec_view')),
        findsOneWidget,
      );
    });
  });
}
