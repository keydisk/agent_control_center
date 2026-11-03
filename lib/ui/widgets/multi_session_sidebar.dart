import 'package:flutter/material.dart';

import '../../core/models/agent_models.dart';
import '../../services/session_manager.dart';
import 'timeline_widgets.dart';

class MultiSessionSidebar extends StatelessWidget {
  const MultiSessionSidebar({
    super.key,
    required this.sessions,
    required this.activeSessionId,
    required this.usageByBackend,
    required this.onSelectSession,
    required this.onCreateSession,
    required this.onStopSession,
    required this.onRetrySession,
    required this.onRerunWithBackend,
    required this.onIsolateWorktree,
    this.selectedDevice = TargetDeviceType.macosDesktop,
    this.onDeviceChanged,
    this.autoOrchestrateByAntigravity = true,
    this.onAutoOrchestrateChanged,
  });

  final List<ManagedSession> sessions;
  final String? activeSessionId;
  final Map<BackendType, TokenUsage> usageByBackend;
  final ValueChanged<String> onSelectSession;
  final ValueChanged<BackendType> onCreateSession;
  final ValueChanged<String> onStopSession;
  final ValueChanged<String> onRetrySession;
  final void Function(String sessionId, BackendType backend) onRerunWithBackend;
  final ValueChanged<String> onIsolateWorktree;
  final TargetDeviceType selectedDevice;
  final ValueChanged<TargetDeviceType>? onDeviceChanged;
  final bool autoOrchestrateByAntigravity;
  final ValueChanged<bool>? onAutoOrchestrateChanged;

  Color _statusColor(SessionStatus status) {
    switch (status) {
      case SessionStatus.idle:
        return Colors.grey;
      case SessionStatus.running:
        return Colors.lightBlueAccent;
      case SessionStatus.awaitingApproval:
        return Colors.orangeAccent;
      case SessionStatus.completed:
        return Colors.greenAccent;
      case SessionStatus.failed:
        return Colors.redAccent;
      case SessionStatus.stopped:
        return Colors.amber;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 270,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              children: [
                const Icon(Icons.layers_outlined, size: 18),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '병렬 작업 세션',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                PopupMenuButton<BackendType>(
                  key: const ValueKey('new_session_menu_button'),
                  tooltip: '새 작업 세션 추가',
                  onSelected: onCreateSession,
                  itemBuilder: (context) => [
                    for (final b in BackendType.values)
                      PopupMenuItem(
                        key: ValueKey('new_session_${b.id}'),
                        value: b,
                        child: Text('+ ${b.displayName} 세션'),
                      ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add, size: 15),
                        SizedBox(width: 4),
                        Text('새 작업', style: TextStyle(fontSize: 11.5)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              children: [
                const Icon(
                  Icons.account_tree_outlined,
                  size: 14,
                  color: Colors.lightBlueAccent,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Antigravity 자동 오케스트레이션',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Switch(
                  key: const ValueKey('auto_orchestrate_switch'),
                  value: autoOrchestrateByAntigravity,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => onAutoOrchestrateChanged?.call(v),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: sessions.length,
              itemBuilder: (context, index) {
                final session = sessions[index];
                final isSelected = session.sessionId == activeSessionId;
                final statusColor = _statusColor(session.status);

                return Card(
                  key: ValueKey('session_card_${session.sessionId}'),
                  margin: const EdgeInsets.only(bottom: 8),
                  color: isSelected
                      ? Theme.of(
                          context,
                        ).colorScheme.primaryContainer.withValues(alpha: 0.35)
                      : Theme.of(context).colorScheme.surfaceContainer,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent,
                    ),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onSelectSession(session.sessionId),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  session.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ),
                              Container(
                                key: ValueKey(
                                  'session_status_${session.sessionId}',
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: statusColor.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: statusColor.withValues(alpha: 0.5),
                                  ),
                                ),
                                child: Text(
                                  session.status.label,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: statusColor,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: BackendModelBadge(
                                  backend: session.backendType,
                                  model: session.model,
                                ),
                              ),
                              if (session.status == SessionStatus.running ||
                                  session.status ==
                                      SessionStatus.awaitingApproval)
                                IconButton(
                                  key: ValueKey(
                                    'stop_session_${session.sessionId}',
                                  ),
                                  icon: const Icon(
                                    Icons.stop_circle_outlined,
                                    size: 16,
                                    color: Colors.redAccent,
                                  ),
                                  tooltip: '작업 중지',
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () =>
                                      onStopSession(session.sessionId),
                                ),
                              const SizedBox(width: 4),
                              IconButton(
                                key: ValueKey(
                                  'retry_session_${session.sessionId}',
                                ),
                                icon: const Icon(Icons.refresh, size: 16),
                                tooltip: '재시도',
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () =>
                                    onRetrySession(session.sessionId),
                              ),
                              PopupMenuButton<BackendType>(
                                key: ValueKey(
                                  'rerun_menu_${session.sessionId}',
                                ),
                                tooltip: '다른 백엔드로 재실행',
                                icon: const Icon(Icons.swap_horiz, size: 16),
                                padding: EdgeInsets.zero,
                                onSelected: (b) =>
                                    onRerunWithBackend(session.sessionId, b),
                                itemBuilder: (context) => [
                                  for (final b in BackendType.values)
                                    PopupMenuItem(
                                      key: ValueKey(
                                        'rerun_${session.sessionId}_${b.id}',
                                      ),
                                      value: b,
                                      child: Text('${b.displayName}(으)로 재실행'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                          if (session.hasDirectoryConflict) ...[
                            const SizedBox(height: 6),
                            Container(
                              key: ValueKey(
                                'conflict_warning_${session.sessionId}',
                              ),
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.amber.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: Colors.amber.withValues(alpha: 0.5),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.warning_amber_rounded,
                                    size: 14,
                                    color: Colors.amber,
                                  ),
                                  const SizedBox(width: 4),
                                  const Expanded(
                                    child: Text(
                                      '동일 폴더 동시 작업 충돌',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: Colors.amber,
                                      ),
                                    ),
                                  ),
                                  InkWell(
                                    key: ValueKey(
                                      'isolate_worktree_${session.sessionId}',
                                    ),
                                    onTap: () =>
                                        onIsolateWorktree(session.sessionId),
                                    child: const Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 2,
                                      ),
                                      child: Text(
                                        'worktree 분리',
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.bold,
                                          decoration: TextDecoration.underline,
                                          color: Colors.lightBlueAccent,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (session.isolatedWorktreePath != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              '격리 Worktree: ${session.isolatedWorktreePath}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.greenAccent,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.devices_outlined, size: 15),
                const SizedBox(width: 6),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<TargetDeviceType>(
                      key: const ValueKey('device_dropdown'),
                      value: selectedDevice,
                      isDense: true,
                      isExpanded: true,
                      items: [
                        for (final d in TargetDeviceType.values)
                          DropdownMenuItem(
                            value: d,
                            child: Text(
                              d.label,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11.5),
                            ),
                          ),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          onDeviceChanged?.call(val);
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _BackendUsageFooter(usageByBackend: usageByBackend),
        ],
      ),
    );
  }
}

class _BackendUsageFooter extends StatelessWidget {
  const _BackendUsageFooter({required this.usageByBackend});

  final Map<BackendType, TokenUsage> usageByBackend;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('backend_usage_summary'),
      padding: const EdgeInsets.all(10),
      color: Colors.black26,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '백엔드별 누적 사용량 / 비용',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          for (final b in BackendType.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      b.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                  Text(
                    '${usageByBackend[b]?.totalTokens ?? 0} tok'
                    '${(usageByBackend[b]?.costUsd ?? 0) > 0 ? ' · \$${usageByBackend[b]!.costUsd.toStringAsFixed(4)}' : ''}',
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontFamily: 'monospace',
                      color: Colors.greenAccent,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
