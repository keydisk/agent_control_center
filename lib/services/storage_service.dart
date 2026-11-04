import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/models/agent_models.dart';
import '../core/models/permission_models.dart';
import '../core/permission_store.dart';

/// drift(SQLite) 기반 로컬 영구 저장소 (권한 규칙, 감사 로그, 세션 기록)
class AppDriftDatabase extends GeneratedDatabase implements PermissionStore {
  AppDriftDatabase([QueryExecutor? executor])
    : super(executor ?? NativeDatabase.memory());

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  Future<void> ensureTablesInitialized() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS permission_rules (
        id TEXT PRIMARY KEY,
        backend TEXT NOT NULL,
        category TEXT NOT NULL,
        tool_name TEXT NOT NULL,
        target_resource TEXT NOT NULL,
        scope TEXT NOT NULL,
        granted_at TEXT NOT NULL,
        session_id TEXT
      );
    ''');
    await customStatement('''
      CREATE TABLE IF NOT EXISTS permission_audit_logs (
        id TEXT PRIMARY KEY,
        timestamp TEXT NOT NULL,
        session_id TEXT NOT NULL,
        backend TEXT NOT NULL,
        category TEXT NOT NULL,
        tool_name TEXT NOT NULL,
        target_resource TEXT NOT NULL,
        approved INTEGER NOT NULL,
        scope TEXT NOT NULL,
        is_destructive INTEGER NOT NULL,
        reason TEXT NOT NULL
      );
    ''');
  }

  @override
  Future<void> upsertPermissionRule(PermissionRule rule) async {
    await ensureTablesInitialized();
    await customInsert(
      '''
      INSERT OR REPLACE INTO permission_rules
      (id, backend, category, tool_name, target_resource, scope, granted_at, session_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      variables: [
        Variable.withString(rule.id),
        Variable.withString(rule.backend.id),
        Variable.withString(rule.category.name),
        Variable.withString(rule.toolName),
        Variable.withString(rule.targetResource),
        Variable.withString(rule.scope.name),
        Variable.withString(rule.grantedAt.toIso8601String()),
        Variable<String>(rule.sessionId),
      ],
    );
  }

  @override
  Future<void> deletePermissionRule(String ruleId) async {
    await ensureTablesInitialized();
    await customUpdate(
      'DELETE FROM permission_rules WHERE id = ?',
      variables: [Variable.withString(ruleId)],
    );
  }

  @override
  Future<List<PermissionRule>> loadPermissionRules() async {
    await ensureTablesInitialized();
    final rows = await customSelect(
      "SELECT * FROM permission_rules WHERE scope = 'always' ORDER BY granted_at DESC",
    ).get();
    return rows.map((row) {
      final categoryName = row.read<String>('category');
      final scopeName = row.read<String>('scope');
      return PermissionRule(
        id: row.read<String>('id'),
        backend: BackendType.fromId(row.read<String>('backend')),
        category: ApprovalCategory.values.firstWhere(
          (c) => c.name == categoryName,
          orElse: () => ApprovalCategory.shellCommand,
        ),
        toolName: row.read<String>('tool_name'),
        targetResource: row.read<String>('target_resource'),
        scope: ApprovalScope.values.firstWhere(
          (s) => s.name == scopeName,
          orElse: () => ApprovalScope.denied,
        ),
        grantedAt:
            DateTime.tryParse(row.read<String>('granted_at')) ?? DateTime.now(),
        sessionId: row.readNullable<String>('session_id'),
      );
    }).toList();
  }

  @override
  Future<void> insertAuditLog(PermissionAuditEntry entry) async {
    await ensureTablesInitialized();
    await customInsert(
      '''
      INSERT OR REPLACE INTO permission_audit_logs
      (id, timestamp, session_id, backend, category, tool_name, target_resource, approved, scope, is_destructive, reason)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      variables: [
        Variable.withString(entry.id),
        Variable.withString(entry.timestamp.toIso8601String()),
        Variable.withString(entry.sessionId),
        Variable.withString(entry.backend.id),
        Variable.withString(entry.category.name),
        Variable.withString(entry.toolName),
        Variable.withString(entry.targetResource),
        Variable.withInt(entry.approved ? 1 : 0),
        Variable.withString(entry.scope.name),
        Variable.withInt(entry.isDestructive ? 1 : 0),
        Variable.withString(entry.reason),
      ],
    );
  }

  @override
  Future<List<PermissionAuditEntry>> loadAuditLogs() async {
    await ensureTablesInitialized();
    final rows = await customSelect(
      'SELECT * FROM permission_audit_logs ORDER BY timestamp DESC',
    ).get();
    return rows.map((row) {
      final categoryName = row.read<String>('category');
      final scopeName = row.read<String>('scope');
      return PermissionAuditEntry(
        id: row.read<String>('id'),
        timestamp:
            DateTime.tryParse(row.read<String>('timestamp')) ?? DateTime.now(),
        sessionId: row.read<String>('session_id'),
        backend: BackendType.fromId(row.read<String>('backend')),
        category: ApprovalCategory.values.firstWhere(
          (c) => c.name == categoryName,
          orElse: () => ApprovalCategory.shellCommand,
        ),
        toolName: row.read<String>('tool_name'),
        targetResource: row.read<String>('target_resource'),
        approved: row.read<int>('approved') == 1,
        scope: ApprovalScope.values.firstWhere(
          (s) => s.name == scopeName,
          orElse: () => ApprovalScope.once,
        ),
        isDestructive: row.read<int>('is_destructive') == 1,
        reason: row.read<String>('reason'),
      );
    }).toList();
  }
}

/// 백엔드별·계정별 비밀값(OAuth 토큰, API 키)을 OS 키체인(`flutter_secure_storage`)에 분리 보관하는 금고
class SecureCredentialVault {
  SecureCredentialVault({
    FlutterSecureStorage? secureStorage,
    this.useOsKeychain = false,
  }) : _secureStorage = secureStorage ??
           const FlutterSecureStorage(
             // ad-hoc 서명 앱은 data protection 키체인 접근 그룹을 쓸 수 없습니다.
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           );

  final FlutterSecureStorage _secureStorage;
  final bool useOsKeychain;
  final Map<String, String> _memoryFallback = {};

  static String buildScopedKey({
    required BackendType backend,
    required String credentialName,
  }) {
    return 'acc_vault:${backend.id}:$credentialName';
  }

  Future<void> writeBackendSecret({
    required BackendType backend,
    required String credentialName,
    required String secretValue,
  }) async {
    final key = buildScopedKey(
      backend: backend,
      credentialName: credentialName,
    );
    _memoryFallback[key] = secretValue;
    if (useOsKeychain) {
      try {
        await _secureStorage.write(key: key, value: secretValue);
      } catch (_) {}
    }
  }

  Future<String?> readBackendSecret({
    required BackendType backend,
    required String credentialName,
  }) async {
    final key = buildScopedKey(
      backend: backend,
      credentialName: credentialName,
    );
    if (useOsKeychain) {
      try {
        final v = await _secureStorage.read(key: key);
        if (v != null) return v;
      } catch (_) {}
    }
    return _memoryFallback[key];
  }

  Future<void> deleteBackendSecret({
    required BackendType backend,
    required String credentialName,
  }) async {
    final key = buildScopedKey(
      backend: backend,
      credentialName: credentialName,
    );
    _memoryFallback.remove(key);
    if (useOsKeychain) {
      try {
        await _secureStorage.delete(key: key);
      } catch (_) {}
    }
  }
}
