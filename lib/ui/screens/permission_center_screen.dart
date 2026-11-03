import 'package:flutter/material.dart';

import '../../core/models/agent_models.dart';
import '../../services/permission_center.dart';
import '../widgets/timeline_widgets.dart';

class PermissionCenterDialog extends StatefulWidget {
  const PermissionCenterDialog({
    super.key,
    required this.permissionCenter,
  });

  final PermissionCenter permissionCenter;

  @override
  State<PermissionCenterDialog> createState() => _PermissionCenterDialogState();
}

class _PermissionCenterDialogState extends State<PermissionCenterDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  BackendType? _backendFilter;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    widget.permissionCenter.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.permissionCenter.removeListener(_onChanged);
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _confirmEnableAutoBypass(BackendType backend) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.dangerous, color: Colors.redAccent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '위험 경고: ${backend.displayName} 자동 승인 모드 활성화',
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Text(
            '${backend.displayName} 자체의 권한 우회 옵션'
            '(${backend == BackendType.claudeCode ? "--dangerously-skip-permissions" : (backend == BackendType.codex ? "--dangerously-bypass-approvals-and-sandbox" : "PreToolUse 자동 승인")})을 켜면 '
            '일반 도구 호출이 사용자 확인 없이 실행될 수 있습니다.\n\n'
            '※ 단, 컨트롤 센터의 안전 정책에 따라 파괴적 작업(파일 삭제, git push --force, 메일 발송 등)은 '
            '이 옵션이 켜져 있어도 여전히 매번 확인을 요청합니다.\n\n'
            '위험을 이해했으며 활성화하시겠습니까?',
            style: const TextStyle(height: 1.45),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소 (비활성 유지)'),
          ),
          FilledButton(
            key: const ValueKey('confirm_auto_bypass_danger'),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('위험을 감수하고 켜기'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      widget.permissionCenter.setAutoBypass(backend: backend, enabled: true);
    }
  }

  Future<void> _openAccountSecretDialog(AccountScopePermission item) async {
    final secretCtrl = TextEditingController();
    var selectedScope = item.grantedScope == ApprovalScope.denied
        ? ApprovalScope.always
        : item.grantedScope;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('${item.providerName} 권한 및 비밀값 설정'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '요청 스코프: ${item.scopeName}',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.amberAccent,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '목적: ${item.purpose}',
                  style: const TextStyle(fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ApprovalScope>(
                  initialValue: selectedScope,
                  decoration: const InputDecoration(
                    labelText: '승인 범위 선택',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final s in ApprovalScope.values)
                      DropdownMenuItem(value: s, child: Text(s.label)),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setDialogState(() {
                        selectedScope = v;
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('account_secret_textfield'),
                  controller: secretCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'OAuth 토큰 / API 키 (OS 키체인에 분리 저장)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              key: const ValueKey('save_account_scope_button'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );

    if (saved == true) {
      await widget.permissionCenter.setAccountScopePermission(
        scopeId: item.id,
        scope: selectedScope,
        secretTokenValue: secretCtrl.text.trim(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = widget.permissionCenter.rulesForBackend(_backendFilter);
    final logs = widget.permissionCenter.auditLogsForBackend(_backendFilter);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.admin_panel_settings_outlined, color: Colors.amber),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('권한 센터 (Permission Center · 감사 로그 · 키체인 금고)'),
          ),
          // 백엔드별 필터
          Wrap(
            spacing: 6,
            children: [
              ChoiceChip(
                key: const ValueKey('perm_filter_all'),
                label: const Text('전체', style: TextStyle(fontSize: 11.5)),
                selected: _backendFilter == null,
                onSelected: (_) => setState(() => _backendFilter = null),
              ),
              for (final b in BackendType.values)
                ChoiceChip(
                  key: ValueKey('perm_filter_${b.id}'),
                  label: Text(
                    b.displayName,
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  selected: _backendFilter == b,
                  onSelected: (_) => setState(() => _backendFilter = b),
                ),
            ],
          ),
        ],
      ),
      content: SizedBox(
        width: 860,
        height: 540,
        child: Column(
          children: [
            TabBar(
              controller: _tabController,
              tabs: [
                Tab(
                  key: const ValueKey('tab_granted_rules'),
                  text: '부여된 권한 (${rules.length})',
                ),
                const Tab(
                  key: ValueKey('tab_os_and_accounts'),
                  text: 'OS & 계정 스코프',
                ),
                const Tab(
                  key: ValueKey('tab_auto_bypass'),
                  text: '자동 승인 모드 제어',
                ),
                Tab(
                  key: const ValueKey('tab_audit_logs'),
                  text: '감사 로그 (${logs.length})',
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildGrantedRulesTab(rules),
                  _buildOsAndAccountsTab(),
                  _buildAutoBypassTab(),
                  _buildAuditLogsTab(logs),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }

  Widget _buildGrantedRulesTab(List<PermissionRule> rules) {
    if (rules.isEmpty) {
      return const Center(
        child: Text(
          '현재 부여된 세션/항상 권한 규칙이 없습니다. 모든 도구 호출은 실행 전 사용자에게 묻습니다.',
          style: TextStyle(color: Colors.white60),
        ),
      );
    }
    return ListView.builder(
      itemCount: rules.length,
      itemBuilder: (context, index) {
        final rule = rules[index];
        return Card(
          key: ValueKey('rule_card_${rule.id}'),
          child: ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    '${rule.category.label} · ${rule.toolName}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                BackendModelBadge(backend: rule.backend),
              ],
            ),
            subtitle: Text(
              '대상: ${rule.targetResource.isEmpty ? "*" : rule.targetResource} · 범위: ${rule.scope.label}',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: OutlinedButton.icon(
              key: ValueKey('revoke_rule_${rule.id}'),
              onPressed: () => widget.permissionCenter.revokeRule(rule.id),
              icon: const Icon(
                Icons.delete_outline,
                size: 16,
                color: Colors.redAccent,
              ),
              label: const Text('철회'),
            ),
          ),
        );
      },
    );
  }

  Widget _buildOsAndAccountsTab() {
    final osMap = widget.permissionCenter.osPermissions;
    final accounts = widget.permissionCenter.accountScopes.where((a) {
      if (_backendFilter == null) return true;
      return a.backend == _backendFilter;
    }).toList();

    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text(
            'macOS / 데스크톱 OS 권한 (목적 확인 후 범위 지정)',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ),
        for (final osType in OsPermissionType.values)
          Card(
            key: ValueKey('os_perm_card_${osType.id}'),
            child: ListTile(
              leading: const Icon(Icons.desktop_mac_outlined),
              title: Text(
                osType.label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                osType.purpose,
                style: const TextStyle(fontSize: 11.5),
              ),
              trailing: DropdownButton<ApprovalScope>(
                key: ValueKey('os_perm_dropdown_${osType.id}'),
                value: osMap[osType] ?? ApprovalScope.denied,
                items: [
                  for (final s in ApprovalScope.values)
                    DropdownMenuItem(
                      value: s,
                      child: Text(
                        s.label,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
                onChanged: (scope) {
                  if (scope != null) {
                    widget.permissionCenter.setOsPermissionScope(osType, scope);
                  }
                },
              ),
            ),
          ),
        const Divider(height: 24),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text(
            '계정 OAuth 스코프 & 백엔드별 API 키 (OS 키체인 분리 보관)',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ),
        for (final acct in accounts)
          Card(
            key: ValueKey('acct_scope_card_${acct.id}'),
            child: ListTile(
              leading: const Icon(Icons.vpn_key_outlined),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      acct.providerName,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  BackendModelBadge(backend: acct.backend),
                ],
              ),
              subtitle: Text(
                '스코프: ${acct.scopeName}\n목적: ${acct.purpose} · 현재 상태: ${acct.grantedScope.label}',
                style: const TextStyle(fontSize: 11.5),
              ),
              isThreeLine: true,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.tonal(
                    key: ValueKey('configure_acct_${acct.id}'),
                    onPressed: () => _openAccountSecretDialog(acct),
                    child: const Text('스코프/키 설정'),
                  ),
                  if (acct.grantedScope != ApprovalScope.denied) ...[
                    const SizedBox(width: 6),
                    IconButton(
                      key: ValueKey('revoke_acct_${acct.id}'),
                      tooltip: '철회 및 키체인 삭제',
                      icon: const Icon(
                        Icons.link_off,
                        color: Colors.redAccent,
                      ),
                      onPressed: () =>
                          widget.permissionCenter.setAccountScopePermission(
                            scopeId: acct.id,
                            scope: ApprovalScope.denied,
                          ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildAutoBypassTab() {
    return ListView(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
          ),
          child: const Text(
            '보안 기본값: 모든 백엔드의 자체 자동 승인 모드(Claude Code의 권한 우회 옵션, Codex의 full-auto·무샌드박스 등)는 '
            '기본 비활성화되어 있습니다. 활성화하려면 위험 고지를 확인해야 하며, 활성화하더라도 파괴적 작업(삭제, 강제 푸시, 메일 발송)은 '
            '항상 매번 확인을 요청합니다.',
            style: TextStyle(fontSize: 12.5, height: 1.4),
          ),
        ),
        for (final b in BackendType.values)
          Card(
            child: SwitchListTile(
              key: ValueKey('auto_bypass_switch_${b.id}'),
              title: Text(
                '${b.displayName} 자체 자동 승인 우회 모드',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                widget.permissionCenter.isAutoBypassEnabled(b)
                    ? '활성화됨 (일반 도구 자동 승인 · 파괴적 작업만 매번 확인)'
                    : '비활성 (권장 기본값 — 모든 권한을 사용자에게 확인)',
              ),
              value: widget.permissionCenter.isAutoBypassEnabled(b),
              onChanged: (val) {
                if (val) {
                  _confirmEnableAutoBypass(b);
                } else {
                  widget.permissionCenter.setAutoBypass(
                    backend: b,
                    enabled: false,
                  );
                }
              },
            ),
          ),
      ],
    );
  }

  Widget _buildAuditLogsTab(List<PermissionAuditEntry> logs) {
    if (logs.isEmpty) {
      return const Center(
        child: Text(
          '기록된 권한 감사 로그가 없습니다.',
          style: TextStyle(color: Colors.white60),
        ),
      );
    }
    return ListView.builder(
      itemCount: logs.length,
      itemBuilder: (context, index) {
        final log = logs[index];
        return Card(
          key: ValueKey('audit_log_${log.id}'),
          child: ListTile(
            leading: Icon(
              log.approved ? Icons.check_circle : Icons.cancel,
              color: log.approved ? Colors.greenAccent : Colors.redAccent,
            ),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    '[${log.approved ? "승인" : "거부/철회"}] ${log.category.label} · ${log.toolName}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                BackendModelBadge(backend: log.backend),
              ],
            ),
            subtitle: Text(
              '대상: ${log.targetResource} · 범위: ${log.scope.label}${log.isDestructive ? " · [파괴적 작업]" : ""}\n사유: ${log.reason}',
              style: const TextStyle(fontSize: 11.5),
            ),
            isThreeLine: true,
          ),
        );
      },
    );
  }
}
