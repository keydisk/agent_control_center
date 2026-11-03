import 'agent_models.dart';

class PermissionRule {
  const PermissionRule({
    required this.id,
    required this.backend,
    required this.category,
    required this.toolName,
    required this.targetResource,
    required this.scope,
    required this.grantedAt,
    this.sessionId,
  });

  final String id;
  final BackendType backend;
  final ApprovalCategory category;
  final String toolName;
  final String targetResource;
  final ApprovalScope scope; // session | always
  final DateTime grantedAt;
  final String? sessionId;
}

class PermissionAuditEntry {
  const PermissionAuditEntry({
    required this.id,
    required this.timestamp,
    required this.sessionId,
    required this.backend,
    required this.category,
    required this.toolName,
    required this.targetResource,
    required this.approved,
    required this.scope,
    required this.isDestructive,
    this.reason = '',
  });

  final String id;
  final DateTime timestamp;
  final String sessionId;
  final BackendType backend;
  final ApprovalCategory category;
  final String toolName;
  final String targetResource;
  final bool approved;
  final ApprovalScope scope;
  final bool isDestructive;
  final String reason;
}
