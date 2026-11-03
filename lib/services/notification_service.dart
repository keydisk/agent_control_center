import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

enum NotificationKind {
  inboxSummary('메일/메시지 요약'),
  taskCompleted('작업 완료'),
  taskFailed('작업 실패'),
  approvalRequested('에이전트 승인 요청');

  const NotificationKind(this.label);
  final String label;
}

class NotificationDeepLink {
  const NotificationDeepLink({
    required this.kind,
    this.targetId = '',
    this.sessionId = '',
  });

  final NotificationKind kind;
  final String targetId; // 예: inbox summary ID 또는 approval request ID
  final String sessionId;

  String toPayloadJson() => jsonEncode({
    'kind': kind.name,
    'targetId': targetId,
    'sessionId': sessionId,
  });

  static NotificationDeepLink? fromPayloadJson(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final map = jsonDecode(payload) as Map<String, dynamic>;
      final kindName = map['kind']?.toString() ?? '';
      final kind = NotificationKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => NotificationKind.inboxSummary,
      );
      return NotificationDeepLink(
        kind: kind,
        targetId: map['targetId']?.toString() ?? '',
        sessionId: map['sessionId']?.toString() ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

class DispatchedNotificationRecord {
  const DispatchedNotificationRecord({
    required this.id,
    required this.title,
    required this.body,
    required this.deepLink,
    required this.timestamp,
  });

  final int id;
  final String title;
  final String body;
  final NotificationDeepLink deepLink;
  final DateTime timestamp;
}

/// 데스크톱 OS 알림(`flutter_local_notifications`) 및 알림 클릭 시 딥링크 라우팅 서비스
class NotificationService extends ChangeNotifier {
  NotificationService({
    FlutterLocalNotificationsPlugin? plugin,
    this.enableOsPlugin = true,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final bool enableOsPlugin;
  bool _initialized = false;
  int _nextId = 1000;

  final List<DispatchedNotificationRecord> _history = [];
  final StreamController<NotificationDeepLink> _deepLinkController =
      StreamController<NotificationDeepLink>.broadcast();

  List<DispatchedNotificationRecord> get history =>
      List.unmodifiable(_history);

  Stream<NotificationDeepLink> get deepLinks => _deepLinkController.stream;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (!enableOsPlugin) return;
    try {
      const macOsInit = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const linuxInit = LinuxInitializationSettings(
        defaultActionName: '열기',
      );
      const settings = InitializationSettings(
        macOS: macOsInit,
        linux: linuxInit,
      );
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (response) {
          final link = NotificationDeepLink.fromPayloadJson(response.payload);
          if (link != null) {
            _deepLinkController.add(link);
          }
        },
      );
    } catch (_) {
      // 헤드리스 테스트 환경 등에서는 인메모리 기록으로 동작
    }
  }

  Future<DispatchedNotificationRecord> notify({
    required NotificationKind kind,
    required String title,
    required String body,
    String targetId = '',
    String sessionId = '',
  }) async {
    await initialize();
    final id = ++_nextId;
    final deepLink = NotificationDeepLink(
      kind: kind,
      targetId: targetId,
      sessionId: sessionId,
    );
    final record = DispatchedNotificationRecord(
      id: id,
      title: title,
      body: body,
      deepLink: deepLink,
      timestamp: DateTime.now(),
    );
    _history.insert(0, record);
    notifyListeners();

    if (enableOsPlugin) {
      try {
        const details = NotificationDetails(
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        );
        await _plugin.show(
          id: id,
          title: title,
          body: body,
          notificationDetails: details,
          payload: deepLink.toPayloadJson(),
        );
      } catch (_) {
        // 테스트 또는 권한 미부여 시 인메모리 기록은 유지
      }
    }
    return record;
  }

  /// 사용자가 OS 알림 배너를 탭했을 때(또는 테스트/UI에서 알림 탭 시뮬레이션 시) 딥링크를 트리거합니다.
  void triggerDeepLinkTap(NotificationDeepLink deepLink) {
    _deepLinkController.add(deepLink);
  }

  /// 모바일 원격 알림(FCM/APNs + 중계 서버) 아키텍처 설계안 요약
  static const String mobileRelayArchitectureDoc = '''
# 모바일 원격 알림 (FCM / APNs + E2EE 중계 서버) 설계안

1. **구성 요소**:
   - **Host Desktop Agent Control Center (macOS/Windows/Linux)**: 로컬 에이전트 실행, 승인 인터셉트 및 Inbox 요약 수행.
   - **Stateless Relay Server (Cloud Run / WebSocket + Push Gateway)**: 데스크톱 호스트와 모바일 컴패니언 앱 사이의 암호화 페이로드 중계 및 FCM/APNs 발송.
   - **Mobile Companion App (iOS APNs / Android FCM)**: 원격 승인/거부 응답 및 Inbox 3줄 요약 열람.

2. **종단간 암호화 (E2EE) 및 보안 원칙**:
   - 데스크톱 앱에서 생성한 QR 코드(X25519 공개키 + 페어링 토큰)로 모바일 앱과 대칭 세션키(AES-256-GCM)를 교환합니다.
   - 중계 서버는 평문 프롬프트, 파일 Diff, 메일 원문을 절대 복호화할 수 없으며 오직 암호문 블롭과 푸시 깨우기(wake-up) 신호만 전달합니다.
   - 모바일에서 '이번만 허용 / 거부' 서명(Ed25519)을 전송하면 데스크톱 `PermissionCenter`가 검증 후 `LocalHookBridgeServer` 또는 `Claude/Codex` stdin으로 전달합니다.
''';

  @override
  void dispose() {
    _deepLinkController.close();
    super.dispose();
  }
}
