import 'models/permission_models.dart';

abstract interface class PermissionStore {
  Future<void> upsertPermissionRule(PermissionRule rule);
  Future<void> deletePermissionRule(String ruleId);
  Future<List<PermissionRule>> loadPermissionRules();
  Future<void> insertAuditLog(PermissionAuditEntry entry);
  Future<List<PermissionAuditEntry>> loadAuditLogs();
}
