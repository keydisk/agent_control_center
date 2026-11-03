import 'package:flutter/material.dart';

import '../theme/mac_theme.dart';

import '../../core/models/agent_models.dart';
import '../../services/session_manager.dart';
import 'mac_window_drag_area.dart';
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
    this.trustedFolderCount,
    this.onManageTrustedFolders,
    this.onMergeWorktree,
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
  final int? trustedFolderCount;
  final VoidCallback? onManageTrustedFolders;
  final ValueChanged<String>? onMergeWorktree;

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    return Container(
      width: 260,
      color: mac.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 신호등 버튼 자리를 비워 둔 상단 영역
          MacWindowDragArea(
            child: SizedBox(
              height: 52,
              width: double.infinity,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: PopupMenuButton<BackendType>(
                    key: const ValueKey('new_session_menu_button'),
                    tooltip: '새 작업 세션 추가',
                    onSelected: onCreateSession,
                    itemBuilder: (context) => [
                      for (final b in BackendType.values)
                        PopupMenuItem(
                          key: ValueKey('new_session_${b.id}'),
                          value: b,
                          height: 28,
                          child: Text('${b.displayName} 세션'),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Icon(
                        Icons.edit_square,
                        size: 16,
                        color: mac.secondaryLabel,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const _SidebarSectionLabel('작업 세션'),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: sessions.length,
              itemBuilder: (context, index) {
                final session = sessions[index];
                return _SessionRow(
                  session: session,
                  isSelected: session.sessionId == activeSessionId,
                  onSelect: () => onSelectSession(session.sessionId),
                  onStop: () => onStopSession(session.sessionId),
                  onRetry: () => onRetrySession(session.sessionId),
                  onRerun: (b) => onRerunWithBackend(session.sessionId, b),
                  onIsolate: () => onIsolateWorktree(session.sessionId),
                  onMerge: () => onMergeWorktree?.call(session.sessionId),
                );
              },
            ),
          ),
          const Divider(),
          if (trustedFolderCount != null)
            InkWell(
              key: const ValueKey('open_trusted_folders_button'),
              onTap: onManageTrustedFolders,
              child: _SidebarSettingRow(
                icon: Icons.verified_user_outlined,
                label: '신뢰 폴더 ($trustedFolderCount)',
                trailing: Icon(
                  Icons.chevron_right,
                  size: 14,
                  color: mac.tertiaryLabel,
                ),
              ),
            ),
          _SidebarSettingRow(
            icon: Icons.account_tree_outlined,
            label: '자동 오케스트레이션',
            tooltip: 'Antigravity 자동 오케스트레이션',
            trailing: SizedBox(
              height: 18,
              child: FittedBox(
                child: Switch(
                  key: const ValueKey('auto_orchestrate_switch'),
                  value: autoOrchestrateByAntigravity,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => onAutoOrchestrateChanged?.call(v),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Row(
              children: [
                Icon(
                  Icons.devices_outlined,
                  size: 14,
                  color: mac.secondaryLabel,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<TargetDeviceType>(
                      key: const ValueKey('device_dropdown'),
                      value: selectedDevice,
                      isDense: true,
                      isExpanded: true,
                      iconSize: 14,
                      focusColor: Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      items: [
                        for (final d in TargetDeviceType.values)
                          DropdownMenuItem(
                            value: d,
                            child: Text(
                              d.label,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: mac.label),
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
          const Divider(),
          _BackendUsageFooter(usageByBackend: usageByBackend),
        ],
      ),
    );
  }
}

class _SidebarSectionLabel extends StatelessWidget {
  const _SidebarSectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: context.mac.secondaryLabel,
        ),
      ),
    );
  }
}

class _SidebarSettingRow extends StatelessWidget {
  const _SidebarSettingRow({
    required this.icon,
    required this.label,
    required this.trailing,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final Widget trailing;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    return Tooltip(
      message: tooltip ?? '',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 14, color: mac.secondaryLabel),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: mac.label),
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// 사이드바 소스 목록의 세션 한 줄
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.isSelected,
    required this.onSelect,
    required this.onStop,
    required this.onRetry,
    required this.onRerun,
    required this.onIsolate,
    required this.onMerge,
  });

  final ManagedSession session;
  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback onStop;
  final VoidCallback onRetry;
  final ValueChanged<BackendType> onRerun;
  final VoidCallback onIsolate;
  final VoidCallback onMerge;

  Color _statusColor(MacColors mac) {
    switch (session.status) {
      case SessionStatus.idle:
        return mac.tertiaryLabel;
      case SessionStatus.running:
        return mac.blue;
      case SessionStatus.awaitingApproval:
      case SessionStatus.stopped:
        return mac.orange;
      case SessionStatus.completed:
        return mac.green;
      case SessionStatus.failed:
        return mac.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    final statusColor = _statusColor(mac);
    final isBusy =
        session.status == SessionStatus.running ||
        session.status == SessionStatus.awaitingApproval;

    return Padding(
      key: ValueKey('session_card_${session.sessionId}'),
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: isSelected ? mac.selection : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onSelect,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: mac.label,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      session.status.label,
                      key: ValueKey('session_status_${session.sessionId}'),
                      style: TextStyle(
                        fontSize: 10.5,
                        color: mac.secondaryLabel,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: BackendModelBadge(
                    backend: session.backendType,
                    model: session.model,
                  ),
                ),
                if (isSelected || isBusy)
                  _SessionActions(
                    session: session,
                    isBusy: isBusy,
                    onStop: onStop,
                    onRetry: onRetry,
                    onRerun: onRerun,
                  ),
                if (session.hasDirectoryConflict)
                  _ConflictNotice(session: session, onIsolate: onIsolate),
                for (final link in session.worktreeLinks) ...[
                  const SizedBox(height: 6),
                  _WorktreeLinkView(
                    link: link,
                    onMerge: identical(link, session.activeWorktreeLink)
                        ? onMerge
                        : null,
                  ),
                ],
                if (session.isolatedWorktreePath != null &&
                    session.worktreeLinks.isEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '격리 Worktree: ${session.isolatedWorktreePath}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: mac.secondaryLabel),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionActions extends StatelessWidget {
  const _SessionActions({
    required this.session,
    required this.isBusy,
    required this.onStop,
    required this.onRetry,
    required this.onRerun,
  });

  final ManagedSession session;
  final bool isBusy;
  final VoidCallback onStop;
  final VoidCallback onRetry;
  final ValueChanged<BackendType> onRerun;

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (isBusy)
            IconButton(
              key: ValueKey('stop_session_${session.sessionId}'),
              icon: Icon(Icons.stop_rounded, size: 15, color: mac.red),
              tooltip: '작업 중지',
              onPressed: onStop,
            ),
          IconButton(
            key: ValueKey('retry_session_${session.sessionId}'),
            icon: const Icon(Icons.refresh, size: 15),
            tooltip: '재시도',
            onPressed: onRetry,
          ),
          PopupMenuButton<BackendType>(
            key: ValueKey('rerun_menu_${session.sessionId}'),
            tooltip: '다른 백엔드로 재실행',
            onSelected: onRerun,
            itemBuilder: (context) => [
              for (final b in BackendType.values)
                PopupMenuItem(
                  key: ValueKey('rerun_${session.sessionId}_${b.id}'),
                  value: b,
                  height: 28,
                  child: Text('${b.displayName}(으)로 재실행'),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Icon(
                Icons.swap_horiz,
                size: 15,
                color: mac.secondaryLabel,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConflictNotice extends StatelessWidget {
  const _ConflictNotice({required this.session, required this.onIsolate});

  final ManagedSession session;
  final VoidCallback onIsolate;

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    return Padding(
      key: ValueKey('conflict_warning_${session.sessionId}'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 13, color: mac.orange),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '동일 폴더 동시 작업',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: mac.orange),
            ),
          ),
          InkWell(
            key: ValueKey('isolate_worktree_${session.sessionId}'),
            onTap: onIsolate,
            child: Text(
              'worktree 분리',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: mac.blue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 작업 브랜치에서 대상 브랜치로 이어지는 병합 연결 고리
class _WorktreeLinkView extends StatelessWidget {
  const _WorktreeLinkView({required this.link, this.onMerge});

  final WorktreeLink link;
  final VoidCallback? onMerge;

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    final color = link.isMerged ? mac.green : mac.blue;
    final nameStyle = TextStyle(
      fontSize: 10.5,
      fontFamily: kMonoFont,
      color: mac.label,
    );
    return Container(
      key: ValueKey('worktree_link_${link.branch}'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: BoxDecoration(
        color: mac.fill,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.call_split, size: 13, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Tooltip(
                  message: link.branch,
                  child: Text(
                    link.branch,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: nameStyle,
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Icon(
                link.isMerged ? Icons.call_merge : Icons.arrow_downward,
                size: 13,
                color: color,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  link.baseBranch,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: nameStyle.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (link.isMerged)
                Text(
                  '병합됨 ${link.mergeCommit}',
                  style: TextStyle(fontSize: 10, color: color),
                )
              else if (onMerge != null)
                InkWell(
                  key: ValueKey('merge_worktree_${link.branch}'),
                  onTap: onMerge,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      '병합',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: mac.blue,
                      ),
                    ),
                  ),
                )
              else
                Text(
                  '미병합',
                  style: TextStyle(fontSize: 10, color: context.mac.orange),
                ),
            ],
          ),
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
    final mac = context.mac;
    final style = TextStyle(fontSize: 10.5, color: mac.secondaryLabel);
    return Padding(
      key: const ValueKey('backend_usage_summary'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final b in BackendType.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      b.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                  Text(
                    '${usageByBackend[b]?.totalTokens ?? 0} tok'
                    '${(usageByBackend[b]?.costUsd ?? 0) > 0 ? ' · \$${usageByBackend[b]!.costUsd.toStringAsFixed(4)}' : ''}',
                    style: style.copyWith(
                      fontFamily: kMonoFont,
                      fontFeatures: const [FontFeature.tabularFigures()],
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
