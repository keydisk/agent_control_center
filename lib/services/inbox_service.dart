import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/backend/agent_backend.dart';
import '../core/models/agent_models.dart';
import 'json_file.dart';
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
  telegram(
    id: 'telegram',
    label: 'Telegram (공식 Bot API)',
    requiredScope: 'BotFather 발급 봇 토큰 (getUpdates 읽기 전용)',
    isSupported: true,
    supportNote: '봇이 받은 메시지만 조회합니다. 개인 계정의 다른 대화는 Bot API로 읽을 수 없습니다.',
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
    this._stateFile,
  }) : _notificationService =
           notificationService ?? NotificationService(enableOsPlugin: false),
       _spawner = spawner ?? const IoProcessSpawner(),
       _httpClient = httpClient ?? http.Client() {
    _loadState();
  }

  /// 앱을 다시 켜도 같은 메일·메시지를 또 알리지 않도록 감지 위치를 보관할 기본 파일
  static File? defaultStateFile() {
    final home = Platform.environment['HOME'];
    return home == null
        ? null
        : File('$home/.agent_control_center/inbox_state.json');
  }

  static const _mailNotRunning = 'ACC_MAIL_NOT_RUNNING';
  static const _maxNewPerScan = 20;

  final File? _stateFile;
  int? _lastIMessageRowId;
  Set<int>? _seenMailIds;
  bool _mailFetching = false;
  bool _imessageFetching = false;
  final Map<InboxSourceType, String> _sourceErrors = {};

  /// macOS 권한 부족처럼 사용자가 해결해야 하는 로컬 소스 오류
  Map<InboxSourceType, String> get sourceErrors =>
      Map.unmodifiable(_sourceErrors);

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
  int? _telegramUpdateOffset;

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
    // 첫 주기를 기다리지 않고 바로 기준을 잡습니다.
    unawaited(pollAllAuthorizedSourcesOnce());
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
      }, onError: (Object _) {});
    } catch (_) {
      // 파일 감시가 지원되지 않는 플랫폼/권한 미부여 시 주기적 타이머 폴링으로 동작
    }
  }

  /// 사용자 권한이 허용된 모든 소스(Gmail, Slack, Telegram, macOS Mail.app, iMessage)를 1회 스캔하여
  /// 아직 처리하지 않은 새 메일·메시지만 자동 요약 및 알림 발송합니다.
  Future<List<InboxSummaryItem>> pollAllAuthorizedSourcesOnce() async {
    _lastCheckedAt = DateTime.now();
    final newlySummarized = <InboxSummaryItem>[];
    final perms = permissionCenter;

    if (perms != null) {
      newlySummarized
        ..addAll(
          await _scanAccount(
            perms,
            InboxSourceType.gmail,
            'google_gmail_readonly',
            (token) => fetchFromGmailApi(oauthAccessToken: token),
          ),
        )
        ..addAll(
          await _scanAccount(
            perms,
            InboxSourceType.slack,
            'slack_readonly',
            (token) => fetchFromSlackApi(
              slackBotToken: token,
              channelId: defaultSlackChannelId,
            ),
          ),
        )
        ..addAll(
          await _scanLocal(
            perms,
            InboxSourceType.macosMail,
            OsPermissionType.automationAppleEvents,
            fetchFromMacOsMailApp,
          ),
        )
        ..addAll(
          await _scanLocal(
            perms,
            InboxSourceType.imessage,
            OsPermissionType.fullDiskAccess,
            () => fetchFromMacOsIMessage(customDbPath: customIMessageDbPath),
          ),
        )
        ..addAll(
          await _scanAccount(
            perms,
            InboxSourceType.telegram,
            'telegram_bot',
            (token) => fetchFromTelegramBotApi(botToken: token),
          ),
        );
    }

    notifyListeners();
    return newlySummarized;
  }

  /// 토큰이 든 URL이 화면에 나오지 않도록 직접 만든 오류 문구만 그대로 보여 줍니다.
  void _recordScanFailure(InboxSourceType source, Object error) {
    _sourceErrors[source] = error is StateError
        ? error.message
        : '조회 실패 (네트워크 또는 응답 오류)';
  }

  Future<List<InboxSummaryItem>> _scanAccount(
    PermissionCenter perms,
    InboxSourceType source,
    String scopeId,
    Future<List<InboxSummaryItem>> Function(String token) fetch,
  ) async {
    final scope = perms.accountScopes.where((a) => a.id == scopeId).firstOrNull;
    if (scope == null || scope.grantedScope == ApprovalScope.denied) {
      _sourceErrors[source] = '꺼져 있음 — 권한 센터의 계정 항목에서 허용하고 토큰을 입력해 주세요.';
      return const [];
    }
    final token = await perms.credentialVault.readBackendSecret(
      backend: scope.backend,
      credentialName: scope.id,
    );
    if (token == null || token.isEmpty) {
      _sourceErrors[source] = '토큰 없음 — 권한 센터의 계정 항목에서 토큰을 입력해 주세요.';
      return const [];
    }
    try {
      final items = await fetch(token);
      _sourceErrors.remove(source);
      return items;
    } catch (e) {
      _recordScanFailure(source, e);
      return const [];
    }
  }

  Future<List<InboxSummaryItem>> _scanLocal(
    PermissionCenter perms,
    InboxSourceType source,
    OsPermissionType permission,
    Future<List<InboxSummaryItem>> Function() fetch,
  ) async {
    final granted = perms.osPermissions[permission];
    if (granted == null || granted == ApprovalScope.denied) {
      _sourceErrors[source] = '꺼져 있음 — 권한 센터에서 "${permission.label}"을 허용해 주세요.';
      return const [];
    }
    try {
      return await fetch();
    } catch (e) {
      _recordScanFailure(source, e);
      return const [];
    }
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

  /// Telegram 공식 Bot API (`getUpdates`)에서 봇이 받은 새 메시지를 감지해 요약합니다.
  /// 요약에 성공한 업데이트까지만 offset을 전진시켜 실패한 메시지는 다음 스캔에서 재시도합니다.
  Future<List<InboxSummaryItem>> fetchFromTelegramBotApi({
    required String botToken,
    int limit = 20,
  }) async {
    final uri = Uri.https('api.telegram.org', '/bot$botToken/getUpdates', {
      'limit': '$limit',
      'allowed_updates': '["message"]',
      if (_telegramUpdateOffset != null) 'offset': '$_telegramUpdateOffset',
    });
    final resp = await _httpClient.get(uri);
    if (resp.statusCode != 200) {
      throw StateError('Telegram API 호출 실패 (HTTP ${resp.statusCode})');
    }
    final decoded =
        jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (decoded['ok'] != true) {
      throw StateError('Telegram API 오류: ${decoded['description']}');
    }
    final updates = decoded['result'] as List<dynamic>? ?? const [];
    final results = <InboxSummaryItem>[];
    for (final update in updates) {
      if (update is! Map || update['update_id'] is! int) continue;
      final updateId = update['update_id'] as int;
      final msgId = 'tg_$updateId';
      final message = update['message'];
      final text = message is Map
          ? (message['text'] ?? message['caption'])?.toString() ?? ''
          : '';
      if (text.isNotEmpty &&
          !isDuplicateMessage(InboxSourceType.telegram, msgId)) {
        final from = message['from'];
        final chat = message['chat'];
        final name = from is Map
            ? [from['first_name'], from['last_name']]
                  .whereType<String>()
                  .join(' ')
            : '';
        final chatTitle = chat is Map ? chat['title']?.toString() : null;
        results.add(
          await ingestAndSummarize(
            InboxMessageRaw(
              id: msgId,
              source: InboxSourceType.telegram,
              sender: name.isNotEmpty ? name : (chatTitle ?? 'Telegram 사용자'),
              subject: chatTitle != null
                  ? 'Telegram $chatTitle 메시지'
                  : 'Telegram 개인 메시지',
              body: text,
              receivedAt: DateTime.now(),
            ),
          ),
        );
      }
      _telegramUpdateOffset = updateId + 1;
    }
    return results;
  }

  /// 로컬 소스 명령을 실행합니다. 실패하면 사유를 남겨 화면에 알리고 null을 돌려줍니다.
  Future<ProcessResult?> _runLocalSource(
    InboxSourceType source,
    String executable,
    List<String> arguments,
    String hint,
  ) async {
    String detail;
    try {
      final res = await _spawner
          .run(executable, arguments)
          .timeout(const Duration(seconds: 30));
      if (res.exitCode == 0) {
        if (_sourceErrors.remove(source) != null) notifyListeners();
        return res;
      }
      detail = res.stderr.toString().trim();
    } on TimeoutException catch (_) {
      detail = '응답 시간 초과';
    } on ProcessException catch (e) {
      detail = e.message;
    }
    _sourceErrors[source] = '$hint ($detail)';
    notifyListeners();
    return null;
  }

  /// macOS Mail.app에 새로 도착한 읽지 않은 메일을 감지해 요약합니다.
  /// 처음 확인할 때의 메일은 기준으로만 기록하고 알리지 않습니다.
  Future<List<InboxSummaryItem>> fetchFromMacOsMailApp() async {
    if (_mailFetching) return const [];
    _mailFetching = true;
    try {
      return await _fetchNewMail();
    } finally {
      _mailFetching = false;
    }
  }

  Future<List<InboxSummaryItem>> _fetchNewMail() async {
    const hint = '시스템 설정 > 개인정보 보호 및 보안 > 자동화에서 Mail 제어를 허용해 주세요.';
    // Mail이 꺼져 있을 때 폴링이 앱을 띄우지 않도록 먼저 확인합니다.
    const idsScript = '''
if application "Mail" is not running then return "$_mailNotRunning"
tell application "Mail"
  set idList to id of (messages of inbox whose read status is false)
  set AppleScript's text item delimiters to ","
  return idList as string
end tell
''';
    final res = await _runLocalSource(
      InboxSourceType.macosMail,
      'osascript',
      ['-e', idsScript],
      hint,
    );
    final output = res?.stdout.toString().trim();
    if (output == _mailNotRunning) {
      _sourceErrors[InboxSourceType.macosMail] =
          'Mail 앱이 꺼져 있어 확인하지 못했습니다. Mail을 켜 두면 다음 스캔부터 확인합니다.';
      return const [];
    }
    if (output == null) return const [];
    final ids =
        output.split(',').map((i) => int.tryParse(i.trim())).nonNulls.toList()
          ..sort();
    final seen = _seenMailIds;
    if (seen == null) {
      _seenMailIds = ids.toSet();
      _saveState();
      return const [];
    }

    final items = <InboxSummaryItem>[];
    final processed = <int>{};
    for (final id in ids.where((i) => !seen.contains(i)).take(_maxNewPerScan)) {
      final detail = await _runLocalSource(
        InboxSourceType.macosMail,
        'osascript',
        [
          '-e',
          '''
tell application "Mail"
  set msg to first message of inbox whose id is $id
  set sep to character id 31
  return (sender of msg) & sep & (subject of msg) & sep & (content of msg)
end tell
''',
        ],
        hint,
      );
      if (detail == null) break;
      final parts = detail.stdout.toString().trim().split('\x1f');
      items.add(
        await ingestAndSummarize(
          InboxMessageRaw(
            id: 'mail_$id',
            source: InboxSourceType.macosMail,
            sender: parts.isNotEmpty ? parts[0] : 'Mail 발신자',
            subject: parts.length > 1 ? parts[1] : '(제목 없음)',
            body: parts.length > 2 ? parts.sublist(2).join(' ') : '',
            receivedAt: DateTime.now(),
          ),
        ),
      );
      processed.add(id);
    }
    // 읽은 메일은 기록에서 빼서 목록이 안 읽은 메일 수 이상으로 늘지 않게 합니다.
    _seenMailIds = {
      for (final id in ids)
        if (seen.contains(id) || processed.contains(id)) id,
    };
    _saveState();
    return items;
  }

  /// macOS iMessage (`~/Library/Messages/chat.db`)에 새로 도착한 메시지를 감지해 요약합니다.
  /// 처음 확인할 때는 마지막 위치만 기록하고, 내가 보낸 메시지는 제외합니다.
  Future<List<InboxSummaryItem>> fetchFromMacOsIMessage({
    String? customDbPath,
  }) async {
    if (_imessageFetching) return const [];
    _imessageFetching = true;
    try {
      final home = Platform.environment['HOME'] ?? '';
      return await _fetchNewIMessages(
        customDbPath ??
            customIMessageDbPath ??
            (home.isNotEmpty
                ? '$home/Library/Messages/chat.db'
                : '~/Library/Messages/chat.db'),
      );
    } finally {
      _imessageFetching = false;
    }
  }

  Future<List<Map<String, dynamic>>?> _queryIMessage(
    String dbPath,
    String sql,
  ) async {
    final res = await _runLocalSource(
      InboxSourceType.imessage,
      'sqlite3',
      ['-readonly', '-json', dbPath, sql],
      '시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한에서 이 앱을 허용해 주세요.',
    );
    if (res == null) return null;
    final output = res.stdout.toString().trim();
    if (output.isEmpty) return const [];
    return (jsonDecode(output) as List).cast<Map<String, dynamic>>();
  }

  Future<List<InboxSummaryItem>> _fetchNewIMessages(String dbPath) async {
    final last = _lastIMessageRowId;
    if (last == null) {
      final rows = await _queryIMessage(
        dbPath,
        'SELECT COALESCE(MAX(ROWID), 0) AS maxId FROM message;',
      );
      if (rows != null && rows.isNotEmpty) {
        _lastIMessageRowId = rows.first['maxId'] as int;
        _saveState();
      }
      return const [];
    }
    final rows = await _queryIMessage(
      dbPath,
      'SELECT message.ROWID AS rowId, COALESCE(handle.id, "") AS sender, '
      'COALESCE(message.text, "") AS text, '
      'hex(message.attributedBody) AS body '
      'FROM message LEFT JOIN handle ON message.handle_id = handle.ROWID '
      'WHERE message.ROWID > $last AND message.is_from_me = 0 '
      'ORDER BY message.ROWID ASC LIMIT $_maxNewPerScan;',
    );
    if (rows == null) return const [];

    final items = <InboxSummaryItem>[];
    try {
      for (final row in rows) {
        final rowId = row['rowId'] as int;
        final text = row['text'] as String;
        final body = text.isNotEmpty
            ? text
            : decodeAttributedBody(row['body'] as String? ?? '');
        // 첨부만 있는 메시지처럼 글이 없으면 요약 없이 지나갑니다.
        if (body.isNotEmpty) {
          final sender = row['sender'] as String;
          items.add(
            await ingestAndSummarize(
              InboxMessageRaw(
                id: 'imsg_$rowId',
                source: InboxSourceType.imessage,
                sender: sender.isNotEmpty ? sender : 'iMessage 발신자',
                subject: 'iMessage 수신 메시지',
                body: body,
                receivedAt: DateTime.now(),
              ),
            ),
          );
        }
        _lastIMessageRowId = rowId;
      }
    } finally {
      _saveState();
    }
    return items;
  }

  /// 최근 macOS가 `text` 대신 `attributedBody`(typedstream)에 저장한 본문을 꺼냅니다.
  static String decodeAttributedBody(String hex) {
    if (hex.isEmpty) return '';
    final bytes = [
      for (var i = 0; i + 1 < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    final marker = ascii.encode('NSString');
    var at = -1;
    for (var i = 0; i + marker.length <= bytes.length && at < 0; i++) {
      var matches = true;
      for (var j = 0; j < marker.length && matches; j++) {
        matches = bytes[i + j] == marker[j];
      }
      if (matches) at = i + marker.length;
    }
    if (at < 0) return '';
    // NSString 뒤의 '+' 표식 다음이 길이이며, 0x81·0x82는 2·4바이트 길이를 뜻합니다.
    at = bytes.indexOf(0x2B, at);
    if (at < 0 || at + 1 >= bytes.length) return '';
    at++;
    final extra = bytes[at] == 0x81 ? 2 : (bytes[at] == 0x82 ? 4 : 0);
    if (at + extra >= bytes.length) return '';
    var length = extra == 0 ? bytes[at] : 0;
    for (var i = 0; i < extra; i++) {
      length |= bytes[at + 1 + i] << (8 * i);
    }
    at += 1 + extra;
    if (at + length > bytes.length) return '';
    return utf8.decode(bytes.sublist(at, at + length), allowMalformed: true);
  }

  void _loadState() {
    final file = _stateFile;
    if (file == null || !file.existsSync()) return;
    try {
      final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      _lastIMessageRowId = saved['imessageRowId'] as int?;
      _seenMailIds = (saved['mailIds'] as List?)?.cast<int>().toSet();
    } on Exception catch (_) {
      // 손상된 파일은 처음 실행처럼 기준을 다시 잡습니다.
    } on TypeError catch (_) {
      _lastIMessageRowId = null;
      _seenMailIds = null;
    }
  }

  void _saveState() {
    final file = _stateFile;
    if (file == null) return;
    try {
      writeJsonAtomically(file, {
        'imessageRowId': _lastIMessageRowId,
        'mailIds': _seenMailIds?.toList(),
      });
    } on FileSystemException catch (_) {
      // 저장에 실패해도 이번 실행의 감지는 막지 않습니다.
    }
  }

  @override
  void dispose() {
    stopAutoMonitoring();
    super.dispose();
  }
}
