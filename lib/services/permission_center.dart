import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';

import '../core/models/agent_models.dart';
import '../core/models/permission_models.dart';
import '../core/permission_store.dart';

import 'json_file.dart';
import 'storage_service.dart';

export '../core/models/permission_models.dart';

enum OsPermissionType {
  notifications(
    id: 'os_notifications',
    label: 'OS 알림 (Notifications)',
    purpose: '메일/메시지 요약, 작업 완료/실패, 에이전트 승인 요청을 데스크톱 배너로 알립니다.',
  ),
  filesAndFolders(
    id: 'os_files_folders',
    label: '파일·폴더 접근 (Files & Folders)',
    purpose: '에이전트가 지정된 작업 디렉터리의 소스 코드를 읽고 수정합니다.',
  ),
  fullDiskAccess(
    id: 'os_full_disk_access',
    label: '전체 디스크 접근 (Full Disk Access)',
    purpose: 'macOS iMessage 로컬 DB(~/Library/Messages/chat.db) 읽기 전용 요약에 필요합니다.',
  ),
  accessibility(
    id: 'os_accessibility',
    label: '손쉬운 사용 (Accessibility)',
    purpose: '데스크톱 UI 보조 제어 및 창 포커스 전환에 사용됩니다.',
  ),
  automationAppleEvents(
    id: 'os_automation_apple_events',
    label: '자동화 (Apple Events)',
    purpose: 'macOS Mail.app 읽지 않은 메일 조회 및 Finder 파일 선택 다이얼로그 연동에 사용됩니다.',
  );

  const OsPermissionType({
    required this.id,
    required this.label,
    required this.purpose,
  });

  final String id;
  final String label;
  final String purpose;
}

class AccountScopePermission {
  AccountScopePermission({
    required this.id,
    required this.backend,
    required this.providerName,
    required this.scopeName,
    required this.purpose,
    this.grantedScope = ApprovalScope.denied,
  });

  final String id;
  final BackendType backend;
  final String providerName;
  final String scopeName;
  final String purpose;
  ApprovalScope grantedScope;
}

/// 모든 백엔드의 도구 실행·스킬·OS·계정 권한을 통합 관리하는 PermissionCenter
class PermissionCenter extends ChangeNotifier {
  PermissionCenter({
    this.database,
    SecureCredentialVault? credentialVault,
    this._osPermissionFile,
  }) : credentialVault = credentialVault ?? SecureCredentialVault() {
    _initDefaultAccountScopes();
    _loadOsPermissions();
  }

  factory PermissionCenter.load() {
    final home = Platform.environment['HOME'];
    if (home == null) return PermissionCenter();
    final dir = Directory('$home/.agent_control_center')
      ..createSync(recursive: true);
    return PermissionCenter(
      database: AppDriftDatabase(
        NativeDatabase(File('${dir.path}/acc_database.sqlite')),
      ),
      osPermissionFile: File('${dir.path}/os_permissions.json'),
    );
  }

  final File? _osPermissionFile;

  final PermissionStore? database;
  final SecureCredentialVault credentialVault;

  final List<PermissionRule> _rules = [];
  final List<PermissionAuditEntry> _auditLogs = [];
  final Map<BackendType, bool> _backendAutoBypass = {
    for (final b in BackendType.values) b: false,
  };
  final Map<OsPermissionType, ApprovalScope> _osPermissions = {
    for (final p in OsPermissionType.values) p: ApprovalScope.denied,
  };
  final List<AccountScopePermission> _accountScopes = [];

  List<PermissionRule> get rules => List.unmodifiable(_rules);
  List<PermissionAuditEntry> get auditLogs => List.unmodifiable(_auditLogs);
  Map<OsPermissionType, ApprovalScope> get osPermissions =>
      Map.unmodifiable(_osPermissions);
  List<AccountScopePermission> get accountScopes =>
      List.unmodifiable(_accountScopes);

  void _initDefaultAccountScopes() {
    _accountScopes.addAll([
      AccountScopePermission(
        id: 'google_gmail_readonly',
        backend: BackendType.antigravity,
        providerName: 'Google OAuth (Gmail)',
        scopeName: 'https://www.googleapis.com/auth/gmail.readonly',
        purpose: 'Inbox 요약을 위해 Gmail 새 메일을 읽기 전용으로 조회합니다.',
      ),
      AccountScopePermission(
        id: 'slack_readonly',
        backend: BackendType.antigravity,
        providerName: 'Slack OAuth',
        scopeName: 'channels:history, im:history, users:read',
        purpose: 'Inbox 요약을 위해 Slack 채널 및 DM 메시지를 읽기 전용으로 조회합니다.',
      ),
      AccountScopePermission(
        id: 'telegram_bot',
        backend: BackendType.antigravity,
        providerName: 'Telegram Bot',
        scopeName: 'BotFather 봇 토큰 (getUpdates)',
        purpose: 'Inbox 요약을 위해 봇이 받은 Telegram 메시지를 조회합니다.',
      ),
      AccountScopePermission(
        id: 'agy_google_account',
        backend: BackendType.antigravity,
        providerName: 'Google Antigravity 계정',
        scopeName: 'agy auth login (Google Account)',
        purpose: 'Antigravity 에이전트 모델 호출 및 플러그인 인증에 사용됩니다.',
      ),
      AccountScopePermission(
        id: 'anthropic_api_key',
        backend: BackendType.claudeCode,
        providerName: 'Anthropic Claude Code',
        scopeName: 'claude auth / ANTHROPIC_API_KEY',
        purpose: 'Claude Code 에이전트 실행 및 모델 호출에 사용됩니다.',
      ),
      AccountScopePermission(
        id: 'openai_api_key',
        backend: BackendType.codex,
        providerName: 'OpenAI Codex',
        scopeName: 'codex login / OPENAI_API_KEY',
        purpose: 'OpenAI Codex 에이전트 실행 및 모델 호출에 사용됩니다.',
      ),
    ]);
  }

  /// drift SQLite DB에서 저장된 권한 규칙과 감사 로그를 복원합니다.
  Future<void> loadFromDatabase() async {
    final db = database;
    if (db == null) return;
    final loadedRules = await db.loadPermissionRules();
    final loadedLogs = await db.loadAuditLogs();
    _rules
      ..clear()
      ..addAll(loadedRules);
    _auditLogs
      ..clear()
      ..addAll(loadedLogs);
    notifyListeners();
  }

  bool isAutoBypassEnabled(BackendType backend) =>
      _backendAutoBypass[backend] ?? false;

  void setAutoBypass({
    required BackendType backend,
    required bool enabled,
  }) {
    _backendAutoBypass[backend] = enabled;
    final entry = PermissionAuditEntry(
      id: 'audit_${DateTime.now().microsecondsSinceEpoch}',
      timestamp: DateTime.now(),
      sessionId: 'global',
      backend: backend,
      category: ApprovalCategory.destructive,
      toolName: 'auto_bypass_mode',
      targetResource: backend.displayName,
      approved: enabled,
      scope: enabled ? ApprovalScope.session : ApprovalScope.denied,
      isDestructive: true,
      reason: enabled ? '사용자가 위험 경고 확인 후 자동 승인 모드를 활성화함' : '자동 승인 모드 비활성화',
    );
    _auditLogs.insert(0, entry);
    database?.insertAuditLog(entry);
    notifyListeners();
  }

  void _loadOsPermissions() {
    final file = _osPermissionFile;
    if (file == null || !file.existsSync()) return;
    try {
      final saved = (jsonDecode(file.readAsStringSync()) as List).cast<String>();
      for (final type in OsPermissionType.values) {
        if (saved.contains(type.id)) {
          _osPermissions[type] = ApprovalScope.always;
        }
      }
    } on Exception catch (_) {
      // 손상된 파일은 권한 없음으로 취급하고 다시 묻습니다.
    } on TypeError catch (_) {
      // 위와 같습니다.
    }
  }

  /// '항상' 범위만 다음 실행까지 유지합니다.
  void _saveOsPermissions() {
    final file = _osPermissionFile;
    if (file == null) return;
    try {
      writeJsonAtomically(file, [
        for (final e in _osPermissions.entries)
          if (e.value == ApprovalScope.always) e.key.id,
      ]);
    } on FileSystemException catch (_) {
      // 저장에 실패해도 이번 실행의 권한 변경은 막지 않습니다.
    }
  }

  void setOsPermissionScope(OsPermissionType type, ApprovalScope scope) {
    _osPermissions[type] = scope;
    _saveOsPermissions();
    final entry = PermissionAuditEntry(
      id: 'audit_os_${DateTime.now().microsecondsSinceEpoch}',
      timestamp: DateTime.now(),
      sessionId: 'os_system',
      backend: BackendType.antigravity,
      category: ApprovalCategory.osPermission,
      toolName: type.id,
      targetResource: type.label,
      approved: scope != ApprovalScope.denied,
      scope: scope,
      isDestructive: false,
      reason: 'OS 권한 범위 설정: ${scope.label}',
    );
    _auditLogs.insert(0, entry);
    database?.insertAuditLog(entry);
    notifyListeners();
  }

  Future<void> setAccountScopePermission({
    required String scopeId,
    required ApprovalScope scope,
    String? secretTokenValue,
  }) async {
    final item = _accountScopes.where((a) => a.id == scopeId).firstOrNull;
    if (item == null) return;
    item.grantedScope = scope;
    if (scope == ApprovalScope.denied) {
      await credentialVault.deleteBackendSecret(
        backend: item.backend,
        credentialName: item.id,
      );
    } else if (secretTokenValue != null && secretTokenValue.isNotEmpty) {
      await credentialVault.writeBackendSecret(
        backend: item.backend,
        credentialName: item.id,
        secretValue: secretTokenValue,
      );
    }
    final entry = PermissionAuditEntry(
      id: 'audit_acct_${DateTime.now().microsecondsSinceEpoch}',
      timestamp: DateTime.now(),
      sessionId: 'account_auth',
      backend: item.backend,
      category: ApprovalCategory.accountAuth,
      toolName: item.providerName,
      targetResource: item.scopeName,
      approved: scope != ApprovalScope.denied,
      scope: scope,
      isDestructive: false,
      reason: '계정 스코프 권한 설정: ${scope.label}',
    );
    _auditLogs.insert(0, entry);
    await database?.insertAuditLog(entry);
    notifyListeners();
  }

  /// 기존 부여된 '이 세션 동안' 또는 '항상' 권한과 일치하는지 확인합니다.
  /// 단, 파괴적 작업(isDestructive == true)은 절대 자동 승인되지 않고 항상 null을 반환합니다.
  ApprovalDecision? checkPreApproved(ApprovalRequestData request) {
    if (request.isDestructive ||
        request.category == ApprovalCategory.destructive) {
      return null;
    }

    for (final rule in _rules) {
      final sameBackend = rule.backend == request.backend;
      final sameTool = rule.toolName == request.toolName || rule.toolName == '*';
      final sameResource =
          rule.targetResource.isEmpty ||
          rule.targetResource == '*' ||
          rule.targetResource == request.targetResource;
      final validScope =
          rule.scope == ApprovalScope.always ||
          (rule.scope == ApprovalScope.session &&
              rule.sessionId == request.sessionId);

      if (sameBackend &&
          rule.category == request.category &&
          sameTool &&
          sameResource &&
          validScope) {
        final decision = ApprovalDecision(
          requestId: request.id,
          approved: true,
          scope: rule.scope,
          reason: '저장된 권한 규칙(${rule.scope.label})에 의해 승인됨',
        );
        _recordAudit(request, decision);
        return decision;
      }
    }
    return null;
  }

  /// 사용자의 승인/거부 결정을 기록하고, '이 세션 동안' 또는 '항상' 범위인 경우 규칙에 저장합니다.
  /// 파괴적 작업은 '항상' 또는 '이 세션 동안'으로 요청되더라도 강제로 '이번만(once)'으로 격하합니다.
  ApprovalDecision recordDecision(
    ApprovalRequestData request,
    ApprovalDecision rawDecision,
  ) {
    final isDestructive =
        request.isDestructive ||
        request.category == ApprovalCategory.destructive;
    final effectiveScope =
        (isDestructive &&
            rawDecision.approved &&
            (rawDecision.scope == ApprovalScope.always ||
                rawDecision.scope == ApprovalScope.session))
        ? ApprovalScope.once
        : rawDecision.scope;

    final finalDecision = ApprovalDecision(
      requestId: rawDecision.requestId,
      approved: rawDecision.approved,
      scope: effectiveScope,
      updatedInput: rawDecision.updatedInput,
      reason: rawDecision.reason,
    );

    if (finalDecision.approved &&
        !isDestructive &&
        (effectiveScope == ApprovalScope.session ||
            effectiveScope == ApprovalScope.always)) {
      final existing = _rules
          .where(
            (r) =>
                r.backend == request.backend &&
                r.category == request.category &&
                r.toolName == request.toolName &&
                r.targetResource == request.targetResource &&
                r.sessionId ==
                    (effectiveScope == ApprovalScope.session
                        ? request.sessionId
                        : null),
          )
          .firstOrNull;
      _rules.removeWhere((r) => r.id == existing?.id);
      final newRule = PermissionRule(
        id: existing?.id ?? 'rule_${DateTime.now().microsecondsSinceEpoch}',
        backend: request.backend,
        category: request.category,
        toolName: request.toolName,
        targetResource: request.targetResource,
        scope: effectiveScope,
        grantedAt: DateTime.now(),
        sessionId: effectiveScope == ApprovalScope.session
            ? request.sessionId
            : null,
      );
      _rules.add(newRule);
      database?.upsertPermissionRule(newRule);
    }

    _recordAudit(request, finalDecision);
    return finalDecision;
  }

  void _recordAudit(ApprovalRequestData request, ApprovalDecision decision) {
    final audit = PermissionAuditEntry(
      id: 'audit_${DateTime.now().microsecondsSinceEpoch}',
      timestamp: DateTime.now(),
      sessionId: request.sessionId,
      backend: request.backend,
      category: request.category,
      toolName: request.toolName,
      targetResource: request.targetResource,
      approved: decision.approved,
      scope: decision.scope,
      isDestructive:
          request.isDestructive ||
          request.category == ApprovalCategory.destructive,
      reason: decision.reason ?? request.reason,
    );
    _auditLogs.insert(0, audit);
    database?.insertAuditLog(audit);
    notifyListeners();
  }

  void revokeRule(String ruleId) {
    final target = _rules.where((r) => r.id == ruleId).firstOrNull;
    _rules.removeWhere((r) => r.id == ruleId);
    database?.deletePermissionRule(ruleId);
    if (target != null) {
      final entry = PermissionAuditEntry(
        id: 'audit_revoke_${DateTime.now().microsecondsSinceEpoch}',
        timestamp: DateTime.now(),
        sessionId: target.sessionId ?? 'global',
        backend: target.backend,
        category: target.category,
        toolName: target.toolName,
        targetResource: target.targetResource,
        approved: false,
        scope: ApprovalScope.denied,
        isDestructive: false,
        reason: '사용자가 권한 센터에서 권한 규칙을 철회함',
      );
      _auditLogs.insert(0, entry);
      database?.insertAuditLog(entry);
    }
    notifyListeners();
  }

  void revokeSessionRules(String sessionId) {
    final removed = _rules
        .where(
          (r) => r.scope == ApprovalScope.session && r.sessionId == sessionId,
        )
        .toList();
    for (final r in removed) {
      database?.deletePermissionRule(r.id);
    }
    _rules.removeWhere(
      (r) => r.scope == ApprovalScope.session && r.sessionId == sessionId,
    );
    notifyListeners();
  }

  List<PermissionRule> rulesForBackend(BackendType? backend) {
    if (backend == null) return rules;
    return _rules.where((r) => r.backend == backend).toList();
  }

  List<PermissionAuditEntry> auditLogsForBackend(BackendType? backend) {
    if (backend == null) return auditLogs;
    return _auditLogs.where((a) => a.backend == backend).toList();
  }
}
