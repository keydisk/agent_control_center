import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/backend/agent_backend.dart';
import '../core/models/agent_models.dart';
import 'notification_service.dart';
import 'permission_center.dart';

enum InboxSourceType {
  gmail(
    id: 'gmail',
    label: 'Gmail (공식 REST API)',
    requiredScope: 'https://www.googleapis.com/auth/gmail.readonly (읽기 전용)',
    isSupported: true,
    supportNote: 'Google OAuth 2.0 읽기 전용 토큰으로 새 메일을 가져옵니다.',
  ),
  slack(
    id: 'slack',
    label: 'Slack (공식 Web API)',
    requiredScope: 'channels:history, im:history, users:read (읽기 전용)',
    isSupported: true,
    supportNote: 'Slack Bot/User OAuth 토큰으로 채널 및 DM 메시지를 가져옵니다.',
  ),
  macosMail(
    id: 'macos_mail',
    label: 'macOS Mail.app (로컬 AppleScript)',
    requiredScope: 'OS 자동화(Apple Events) 권한 필요',
    isSupported: true,
    supportNote: 'macOS 기본 메일 앱의 읽지 않은 메일을 로컬에서 조회합니다.',
  ),
  imessage(
    id: 'imessage',
    label: 'macOS iMessage (chat.db 로컬 읽기)',
    requiredScope: 'OS Full Disk Access (전체 디스크 접근) 권한 필요',
    isSupported: true,
    supportNote: '~/Library/Messages/chat.db SQLite에서 최근 메시지를 읽기 전용으로 조회합니다.',
  ),
  kakaoTalk(
    id: 'kakaotalk',
    label: '카카오톡 개인 채팅',
    requiredScope: '공식 읽기 API 없음 (연동 불가)',
    isSupported: false,
    supportNote:
        '카카오톡 개인 채팅은 외부 앱이 대화 원문을 읽을 수 있는 공식 공개 API를 제공하지 않으므로 지원하지 않습니다.',
  );

  const InboxSourceType({
    required this.id,
    required this.label,
    required this.requiredScope,
    required this.isSupported,
    required this.supportNote,
  });

  final String id;
  final String label;
  final String requiredScope;
  final bool isSupported;
  final String supportNote;
}

enum ContentForwardingPolicy {
  subjectOnly(
    label: '제목·발신자만 외부 모델에 전송 (본문 제외)',
    maxBodyChars: 0,
  ),
  first200Chars(
    label: '본문 앞 200자까지만 외부 모델에 전송',
    maxBodyChars: 200,
  ),
  first500Chars(
    label: '본문 앞 500자까지만 외부 모델에 전송',
    maxBodyChars: 500,
  ),
  fullBody(
    label: '원문 전체 외부 모델에 전송',
    maxBodyChars: null,
  );

  const ContentForwardingPolicy({
    required this.label,
    required this.maxBodyChars,
  });

  final String label;
  final int? maxBodyChars;
}

enum UrgencyLevel {
  low('낮음'),
  medium('보통'),
  high('높음'),
  critical('긴급');

  const UrgencyLevel(this.label);
  final String label;

  static UrgencyLevel fromString(String value) {
    final lower = value.toLowerCase();
    if (lower.contains('critical') || lower.contains('긴급')) {
      return UrgencyLevel.critical;
    }
    if (lower.contains('high') || lower.contains('높음')) {
      return UrgencyLevel.high;
    }
    if (lower.contains('low') || lower.contains('낮음')) {
      return UrgencyLevel.low;
    }
    return UrgencyLevel.medium;
  }
}

class InboxMessageRaw {
  const InboxMessageRaw({
    required this.id,
    required this.source,
    required this.sender,
    required this.subject,
    required this.body,
    required this.receivedAt,
  });

  final String id;
  final InboxSourceType source;
  final String sender;
  final String subject;
  final String body;
  final DateTime receivedAt;
}

class InboxSummaryItem {
  const InboxSummaryItem({
    required this.id,
    required this.source,
    required this.sender,
    required this.subject,
    required this.threeLineSummary,
    required this.requiredAction,
    required this.urgency,
    required this.summarizedByBackend,
    required this.summarizedByModel,
    required this.forwardedSnippet,
    required this.createdAt,
  });

  final String id;
  final InboxSourceType source;
  final String sender;
  final String subject;
  final List<String> threeLineSummary; // 핵심 3줄 요약
  final String requiredAction; // 필요한 액션
  final UrgencyLevel urgency; // 긴급도
  final BackendType summarizedByBackend;
  final String summarizedByModel;
  final String forwardedSnippet;
  final DateTime createdAt;
}

typedef ModelSummarizer = Future<InboxSummaryItem> Function(
  InboxMessageRaw raw,
  String sanitizedContent,
  BackendType backend,
  String model,
);

/// 메일·메시지 실시간 자동 감지(폴링 + 로컬 DB 파일 감시), 중복 제거 및 경량 모델 요약 서비스
class InboxService extends ChangeNotifier {
  InboxService({
    NotificationService? notificationService,
    this.permissionCenter,
    ProcessSpawner? spawner,
    http.Client? httpClient,
    this.customSummarizer,
    this.defaultSlackChannelId = 'C01GENERAL',
    this.customIMessageDbPath,
  }) : _notificationService =
           notificationService ?? NotificationService(enableOsPlugin: false),
       _spawner = spawner ?? const IoProcessSpawner(),
       _httpClient = httpClient ?? http.Client();

  final NotificationService _notificationService;
  final PermissionCenter? permissionCenter;
  final ProcessSpawner _spawner;
  final http.Client _httpClient;
  final ModelSummarizer? customSummarizer;
  final String defaultSlackChannelId;
  final String? customIMessageDbPath;

  // 백그라운드 지시 및 요약은 항상 Google Antigravity(agy)가 전담
  final BackendType _summaryBackend = BackendType.antigravity;
  String _summaryModel = 'gemini-3-flash';
  ContentForwardingPolicy _forwardingPolicy =
      ContentForwardingPolicy.first200Chars;

  final List<InboxSummaryItem> _summaries = [];
  final Set<String> _seenMessageIds = {};
  String? _selectedSummaryId;

  Timer? _autoPollTimer;
  StreamSubscription<FileSystemEvent>? _imessageFileWatchSub;
  Duration _pollInterval = const Duration(seconds: 30);
  bool _isAutoMonitoring = false;
  DateTime? _lastCheckedAt;

  BackendType get summaryBackend => _summaryBackend;
  String get summaryModel => _summaryModel;
  ContentForwardingPolicy get forwardingPolicy => _forwardingPolicy;
  List<InboxSummaryItem> get summaries => List.unmodifiable(_summaries);
  Set<String> get seenMessageIds => Set.unmodifiable(_seenMessageIds);
  String? get selectedSummaryId => _selectedSummaryId;
  bool get isAutoMonitoring => _isAutoMonitoring;
  Duration get pollInterval => _pollInterval;
  DateTime? get lastCheckedAt => _lastCheckedAt;

  InboxSummaryItem? get selectedSummary {
    if (_selectedSummaryId == null) {
      return _summaries.isNotEmpty ? _summaries.first : null;
    }
    return _summaries
        .where((s) => s.id == _selectedSummaryId)
        .firstOrNull;
  }

  /// 백엔드별 추천 경량·저비용 요약 모델 기본값
  static String recommendedLightweightModel(BackendType backend) {
    switch (backend) {
      case BackendType.antigravity:
        return 'gemini-3-flash';
      case BackendType.claudeCode:
        return 'claude-haiku-4-5';
      case BackendType.codex:
        return 'gpt-5.6-sol';
    }
  }

  void updateSummaryModelConfig({
    BackendType backend = BackendType.antigravity,
    String? model,
  }) {
    // 백그라운드 요약은 항상 Antigravity가 수행하며 경량 모델을 선택 가능
    _summaryModel =
        model ?? recommendedLightweightModel(BackendType.antigravity);
    notifyListeners();
  }

  void updateForwardingPolicy(ContentForwardingPolicy policy) {
    _forwardingPolicy = policy;
    notifyListeners();
  }

  void selectSummary(String summaryId) {
    _selectedSummaryId = summaryId;
    notifyListeners();
  }

  /// 백그라운드 자동 감지(주기적 API/AppleScript 폴링 + iMessage chat.db 파일 변경 감시)를 시작합니다.
  void startAutoMonitoring({Duration? interval}) {
    if (interval != null) {
      _pollInterval = interval;
    }
    _autoPollTimer?.cancel();
    _imessageFileWatchSub?.cancel();
    _isAutoMonitoring = true;

    _autoPollTimer = Timer.periodic(_pollInterval, (_) {
      pollAllAuthorizedSourcesOnce();
    });

    _setupIMessageFileWatcher();
    notifyListeners();
  }

  /// 백그라운드 자동 감지를 중지합니다.
  void stopAutoMonitoring() {
    _autoPollTimer?.cancel();
    _autoPollTimer = null;
    _imessageFileWatchSub?.cancel();
    _imessageFileWatchSub = null;
    _isAutoMonitoring = false;
    notifyListeners();
  }

  void _setupIMessageFileWatcher() {
    try {
      final home = Platform.environment['HOME'] ?? '';
      final rawDbPath =
          customIMessageDbPath ??
          (home.isNotEmpty ? '$home/Library/Messages/chat.db' : '');
      if (rawDbPath.isEmpty) return;
      final dbFile = File(rawDbPath);
      final parentDir = dbFile.parent;
      if (!parentDir.existsSync()) return;

      _imessageFileWatchSub = parentDir.watch().listen((event) {
        if (event.path.endsWith('chat.db') ||
            event.path.endsWith('chat.db-wal')) {
          final fdaScope =
              permissionCenter?.osPermissions[OsPermissionType.fullDiskAccess];
          if (permissionCenter == null ||
              (fdaScope != null && fdaScope != ApprovalScope.denied)) {
            fetchFromMacOsIMessage(customDbPath: rawDbPath);
          }
        }
      });
    } catch (_) {
      // 파일 감시가 지원되지 않는 플랫폼/권한 미부여 시 주기적 타이머 폴링으로 동작
    }
  }

  /// 사용자 권한이 허용된 모든 소스(Gmail, Slack, macOS Mail.app, iMessage)를 1회 스캔하여
  /// 아직 처리하지 않은 새 메일·메시지만 자동 요약 및 알림 발송합니다.
  Future<List<InboxSummaryItem>> pollAllAuthorizedSourcesOnce() async {
    _lastCheckedAt = DateTime.now();
    final newlySummarized = <InboxSummaryItem>[];
    final perms = permissionCenter;

    // 1. Gmail (권한 허용 + 키체인에 OAuth 토큰 존재 시)
    if (perms != null) {
      final gmailScope = perms.accountScopes
          .where((a) => a.id == 'google_gmail_readonly')
          .firstOrNull;
      if (gmailScope != null &&
          gmailScope.grantedScope != ApprovalScope.denied) {
        final token = await perms.credentialVault.readBackendSecret(
          backend: gmailScope.backend,
          credentialName: gmailScope.id,
        );
        if (token != null && token.isNotEmpty) {
          try {
            final items = await fetchFromGmailApi(oauthAccessToken: token);
            newlySummarized.addAll(items);
          } catch (_) {}
        }
      }

      // 2. Slack (권한 허용 + 키체인에 Bot/User 토큰 존재 시)
      final slackScope = perms.accountScopes
          .where((a) => a.id == 'slack_readonly')
          .firstOrNull;
      if (slackScope != null &&
          slackScope.grantedScope != ApprovalScope.denied) {
        final token = await perms.credentialVault.readBackendSecret(
          backend: slackScope.backend,
          credentialName: slackScope.id,
        );
        if (token != null && token.isNotEmpty) {
          try {
            final items = await fetchFromSlackApi(
              slackBotToken: token,
              channelId: defaultSlackChannelId,
            );
            newlySummarized.addAll(items);
          } catch (_) {}
        }
      }

      // 3. macOS Mail.app (자동화 Apple Events 권한 허용 시)
      final mailPerm =
          perms.osPermissions[OsPermissionType.automationAppleEvents];
      if (mailPerm != null && mailPerm != ApprovalScope.denied) {
        try {
          final items = await fetchFromMacOsMailApp();
          newlySummarized.addAll(items);
        } catch (_) {}
      }

      // 4. macOS iMessage (Full Disk Access 권한 허용 시)
      final fdaPerm = perms.osPermissions[OsPermissionType.fullDiskAccess];
      if (fdaPerm != null && fdaPerm != ApprovalScope.denied) {
        try {
          final items = await fetchFromMacOsIMessage(
            customDbPath: customIMessageDbPath,
          );
          newlySummarized.addAll(items);
        } catch (_) {}
      }
    }

    notifyListeners();
    return newlySummarized;
  }

  /// 외부 모델로 원문을 보내기 전에 사용자가 설정한 전송 범위 정책을 적용합니다.
  static String applyForwardingPolicy(
    InboxMessageRaw message,
    ContentForwardingPolicy policy,
  ) {
    final maxChars = policy.maxBodyChars;
    final String allowedBody;
    if (maxChars == 0) {
      allowedBody = '[본문 전송 제외됨 — 제목 및 발신자 메타데이터만 전송]';
    } else if (maxChars != null && message.body.length > maxChars) {
      allowedBody = '${message.body.substring(0, maxChars)}...(후략)';
    } else {
      allowedBody = message.body;
    }
    return '발신자: ${message.sender}\n제목: ${message.subject}\n본문: $allowedBody';
  }

  /// 새 메일/메시지를 수신하여 중복 확인 → 원문 범위 필터 적용 → 요약 생성 → OS 알림 발송 + Inbox 화면 추가를 수행합니다.
  Future<InboxSummaryItem> ingestAndSummarize(InboxMessageRaw message) async {
    if (!message.source.isSupported) {
      throw UnsupportedError(message.source.supportNote);
    }

    final dedupeKey = '${message.source.id}:${message.id}';
    _seenMessageIds.add(dedupeKey);

    final sanitized = applyForwardingPolicy(message, _forwardingPolicy);
    final InboxSummaryItem summary;
    try {
      if (customSummarizer != null) {
        summary = await customSummarizer!(
          message,
          sanitized,
          _summaryBackend,
          _summaryModel,
        );
      } else {
        summary = _buildStructuredSummary(message, sanitized);
      }
    } catch (_) {
      _seenMessageIds.remove(dedupeKey);
      rethrow;
    }

    _summaries.insert(0, summary);
    _selectedSummaryId = summary.id;
    notifyListeners();

    await _notificationService.notify(
      kind: NotificationKind.inboxSummary,
      title: '[${summary.urgency.label}] ${summary.source.label} · ${summary.sender}',
      body: summary.threeLineSummary.join(' / '),
      targetId: summary.id,
    );

    return summary;
  }

  bool isDuplicateMessage(InboxSourceType source, String messageId) {
    return _seenMessageIds.contains('${source.id}:$messageId');
  }

  InboxSummaryItem _buildStructuredSummary(
    InboxMessageRaw raw,
    String sanitizedContent,
  ) {
    final combined = '${raw.subject} ${raw.body}'.toLowerCase();
    final UrgencyLevel urgency;
    if (combined.contains('긴급') ||
        combined.contains('장애') ||
        combined.contains('urgent') ||
        combined.contains('p0')) {
      urgency = UrgencyLevel.critical;
    } else if (combined.contains('마감') ||
        combined.contains('승인') ||
        combined.contains('배포') ||
        combined.contains('deadline')) {
      urgency = UrgencyLevel.high;
    } else if (combined.contains('안내') || combined.contains('뉴스레터')) {
      urgency = UrgencyLevel.low;
    } else {
      urgency = UrgencyLevel.medium;
    }

    final previewBody = _forwardingPolicy.maxBodyChars == 0
        ? '본문 비공개 설정(제목만 기반 요약)'
        : (raw.body.split('\n').firstWhere(
            (l) => l.trim().isNotEmpty,
            orElse: () => raw.subject,
          ));

    final threeLines = <String>[
      '1. 발신 및 주제: ${raw.sender}님이 "${raw.subject}" 관련 메시지를 보냈습니다.',
      '2. 핵심 내용: ${previewBody.length > 60 ? '${previewBody.substring(0, 60)}...' : previewBody}',
      '3. 외부 모델 전송 범위: ${_forwardingPolicy.label}',
    ];

    final requiredAction = urgency == UrgencyLevel.critical ||
            urgency == UrgencyLevel.high
        ? '즉시 내용 확인 및 회신/승인 조치가 필요합니다.'
        : '참고 후 필요 시 답장하세요.';

    return InboxSummaryItem(
      id: 'sum_${raw.id}_${DateTime.now().microsecondsSinceEpoch}',
      source: raw.source,
      sender: raw.sender,
      subject: raw.subject,
      threeLineSummary: threeLines,
      requiredAction: requiredAction,
      urgency: urgency,
      summarizedByBackend: _summaryBackend,
      summarizedByModel: _summaryModel,
      forwardedSnippet: sanitizedContent,
      createdAt: DateTime.now(),
    );
  }

  /// Gmail 공식 REST API (OAuth 2.0 readonly 토큰)에서 새 메시지를 감지해 요약합니다.
  Future<List<InboxSummaryItem>> fetchFromGmailApi({
    required String oauthAccessToken,
    int maxResults = 3,
  }) async {
    final listUri = Uri.parse(
      'https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=$maxResults',
    );
    final listResp = await _httpClient.get(
      listUri,
      headers: {'Authorization': 'Bearer $oauthAccessToken'},
    );
    if (listResp.statusCode != 200) {
      throw StateError('Gmail API 호출 실패 (HTTP ${listResp.statusCode})');
    }
    final decoded = jsonDecode(listResp.body) as Map<String, dynamic>;
    final messages = decoded['messages'] as List<dynamic>? ?? const [];
    final results = <InboxSummaryItem>[];

    for (final item in messages) {
      if (item is! Map) continue;
      final msgId = item['id']?.toString() ?? '';
      if (msgId.isEmpty || isDuplicateMessage(InboxSourceType.gmail, msgId)) {
        continue;
      }
      final detailUri = Uri.parse(
        'https://gmail.googleapis.com/gmail/v1/users/me/messages/$msgId?format=metadata',
      );
      final detailResp = await _httpClient.get(
        detailUri,
        headers: {'Authorization': 'Bearer $oauthAccessToken'},
      );
      if (detailResp.statusCode != 200) continue;
      final detail = jsonDecode(detailResp.body) as Map<String, dynamic>;
      final snippet = detail['snippet']?.toString() ?? '';
      var sender = 'Gmail 발신자';
      var subject = '(제목 없음)';
      final payload = detail['payload'];
      if (payload is Map && payload['headers'] is List) {
        for (final h in payload['headers'] as List) {
          if (h is Map) {
            final name = h['name']?.toString().toLowerCase();
            final val = h['value']?.toString() ?? '';
            if (name == 'from') sender = val;
            if (name == 'subject') subject = val;
          }
        }
      }
      final summary = await ingestAndSummarize(
        InboxMessageRaw(
          id: msgId,
          source: InboxSourceType.gmail,
          sender: sender,
          subject: subject,
          body: snippet,
          receivedAt: DateTime.now(),
        ),
      );
      results.add(summary);
    }
    return results;
  }

  /// Slack 공식 Web API (`conversations.history`)에서 새 메시지를 감지해 요약합니다.
  Future<List<InboxSummaryItem>> fetchFromSlackApi({
    required String slackBotToken,
    required String channelId,
    int limit = 3,
  }) async {
    final uri = Uri.parse(
      'https://slack.com/api/conversations.history?channel=$channelId&limit=$limit',
    );
    final resp = await _httpClient.get(
      uri,
      headers: {'Authorization': 'Bearer $slackBotToken'},
    );
    if (resp.statusCode != 200) {
      throw StateError('Slack API 호출 실패 (HTTP ${resp.statusCode})');
    }
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    if (decoded['ok'] != true) {
      throw StateError('Slack API 오류: ${decoded['error']}');
    }
    final messages = decoded['messages'] as List<dynamic>? ?? const [];
    final results = <InboxSummaryItem>[];
    for (final m in messages) {
      if (m is! Map) continue;
      final ts = m['ts']?.toString() ?? '';
      final msgId = 'slack_$ts';
      if (ts.isEmpty || isDuplicateMessage(InboxSourceType.slack, msgId)) {
        continue;
      }
      final user = m['user']?.toString() ?? 'Slack 사용자';
      final text = m['text']?.toString() ?? '';
      final summary = await ingestAndSummarize(
        InboxMessageRaw(
          id: msgId,
          source: InboxSourceType.slack,
          sender: user,
          subject: 'Slack #$channelId 메시지',
          body: text,
          receivedAt: DateTime.now(),
        ),
      );
      results.add(summary);
    }
    return results;
  }

  /// macOS Mail.app에서 AppleScript로 새로 도착한 읽지 않은 메일을 감지해 요약합니다.
  Future<List<InboxSummaryItem>> fetchFromMacOsMailApp() async {
    const script = '''
tell application "Mail"
  set unreadList to (messages of inbox whose read status is false)
  if (count of unreadList) is 0 then return ""
  set msg to item 1 of unreadList
  return (id of msg as string) & "|||" & (sender of msg) & "|||" & (subject of msg) & "|||" & (content of msg)
end tell
''';
    final res = await _spawner.run('osascript', ['-e', script]);
    if (res.exitCode != 0 || res.stdout.toString().trim().isEmpty) {
      return const [];
    }
    final parts = res.stdout.toString().trim().split('|||');
    final rawId = parts.isNotEmpty ? parts[0].trim() : '';
    final msgId = rawId.isNotEmpty
        ? 'mail_$rawId'
        : 'mail_${DateTime.now().millisecondsSinceEpoch}';
    if (isDuplicateMessage(InboxSourceType.macosMail, msgId)) {
      return const [];
    }
    final sender = parts.length > 1 ? parts[1] : 'Mail 발신자';
    final subject = parts.length > 2 ? parts[2] : '(제목 없음)';
    final body = parts.length > 3 ? parts[3] : '';
    final item = await ingestAndSummarize(
      InboxMessageRaw(
        id: msgId,
        source: InboxSourceType.macosMail,
        sender: sender,
        subject: subject,
        body: body,
        receivedAt: DateTime.now(),
      ),
    );
    return [item];
  }

  /// macOS iMessage (`~/Library/Messages/chat.db`)에서 새로 도착한 메시지를 감지해 요약합니다.
  Future<List<InboxSummaryItem>> fetchFromMacOsIMessage({
    String? customDbPath,
  }) async {
    final home = Platform.environment['HOME'] ?? '';
    final dbPath =
        customDbPath ??
        customIMessageDbPath ??
        (home.isNotEmpty
            ? '$home/Library/Messages/chat.db'
            : '~/Library/Messages/chat.db');
    final res = await _spawner.run('sqlite3', [
      dbPath,
      'SELECT CAST(message.ROWID AS TEXT) || "|||" || COALESCE(handle.id, "iMessage 발신자") || "|||" || COALESCE(message.text, "") '
          'FROM message LEFT JOIN handle ON message.handle_id = handle.ROWID '
          'WHERE message.text IS NOT NULL ORDER BY message.date DESC LIMIT 1;',
    ]);
    if (res.exitCode != 0 || res.stdout.toString().trim().isEmpty) {
      return const [];
    }
    final parts = res.stdout.toString().trim().split('|||');
    final rowId = parts.isNotEmpty ? parts[0].trim() : '';
    final msgId = rowId.isNotEmpty
        ? 'imsg_$rowId'
        : 'imsg_${DateTime.now().millisecondsSinceEpoch}';
    if (isDuplicateMessage(InboxSourceType.imessage, msgId)) {
      return const [];
    }
    final sender = parts.length > 1 ? parts[1] : 'iMessage 발신자';
    final text = parts.length > 2 ? parts[2] : '';
    final item = await ingestAndSummarize(
      InboxMessageRaw(
        id: msgId,
        source: InboxSourceType.imessage,
        sender: sender,
        subject: 'iMessage 수신 메시지',
        body: text,
        receivedAt: DateTime.now(),
      ),
    );
    return [item];
  }

  @override
  void dispose() {
    stopAutoMonitoring();
    super.dispose();
  }
}
