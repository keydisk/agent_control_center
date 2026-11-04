import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../theme/mac_theme.dart';

import '../../core/models/agent_models.dart';
import '../../services/session_manager.dart';
import '../../services/workspace_group_store.dart';
import 'mac_window_drag_area.dart';
import 'timeline_widgets.dart';

/// 드래그 중인 항목. 열린 세션은 세션 id, 저장된 기록은 기록 id를 담습니다.
typedef _SessionDrag = ({String id, bool saved});

/// [targetId]가 있으면 그 항목의 앞이나 뒤, 없으면 [groupId]의 맨 끝으로 옮깁니다.
typedef SessionMoveCallback =
    void Function(
      String id,
      String? groupId, {
      String? targetId,
      bool after,
    });

class MultiSessionSidebar extends StatelessWidget {
  const MultiSessionSidebar({
    super.key,
    required this.sessions,
    required this.activeSessionId,
    required this.usageByBackend,
    required this.onSelectSession,
    required this.onNewSession,
    required this.onStopSession,
    required this.onRetrySession,
    required this.onRerunWithBackend,
    required this.onIsolateWorktree,
    this.savedSessions = const [],
    this.onOpenSavedSession,
    this.selectedDevice = TargetDeviceType.macosDesktop,
    this.onDeviceChanged,
    this.autoOrchestrateByAntigravity = true,
    this.onAutoOrchestrateChanged,
    this.trustedFolderCount,
    this.onManageTrustedFolders,
    this.onMergeWorktree,
    this.onSessionSettings,
    this.onDeleteSession,
    this.groups,
    this.onNewGroup,
    this.onNewSessionInGroup,
    this.onEditGroup,
    this.onDeleteGroup,
    this.onNewChildSession,
    this.isGroupCollapsed,
    this.onGroupCollapsedChanged,
    this.canMoveSession,
    this.onMoveSession,
    this.onMoveSavedSession,
  });

  final List<ManagedSession> sessions;
  final String? activeSessionId;
  final Map<BackendType, TokenUsage> usageByBackend;
  final ValueChanged<String> onSelectSession;

  /// 메뉴를 연 세션의 설정을 기본값으로 쓰며, 상단 버튼은 null을 전달합니다.
  final ValueChanged<String?> onNewSession;
  final ValueChanged<String> onStopSession;
  final ValueChanged<String> onRetrySession;
  final void Function(String sessionId, BackendType backend) onRerunWithBackend;
  final ValueChanged<String> onIsolateWorktree;
  final List<SessionSnapshot> savedSessions;
  final void Function(SessionSnapshot snapshot, String? groupId)?
  onOpenSavedSession;
  final TargetDeviceType selectedDevice;
  final ValueChanged<TargetDeviceType>? onDeviceChanged;
  final bool autoOrchestrateByAntigravity;
  final ValueChanged<bool>? onAutoOrchestrateChanged;
  final int? trustedFolderCount;
  final VoidCallback? onManageTrustedFolders;
  final ValueChanged<String>? onMergeWorktree;
  final ValueChanged<String>? onSessionSettings;
  final ValueChanged<String>? onDeleteSession;

  /// null이면 작업 그룹 영역을 표시하지 않습니다.
  final List<WorkspaceGroup>? groups;
  final VoidCallback? onNewGroup;
  final ValueChanged<String>? onNewSessionInGroup;
  final ValueChanged<String>? onEditGroup;
  final ValueChanged<String>? onDeleteGroup;
  final ValueChanged<String>? onNewChildSession;
  final bool Function(String groupId)? isGroupCollapsed;
  final void Function(String groupId, bool collapsed)? onGroupCollapsedChanged;
  final bool Function(String sessionId, String? groupId, {String? targetId})?
  canMoveSession;
  final SessionMoveCallback? onMoveSession;
  final SessionMoveCallback? onMoveSavedSession;

  bool _canDrop(_SessionDrag drag, String? groupId, [String? targetId]) =>
      drag.saved
      ? onMoveSavedSession != null && drag.id != targetId
      : canMoveSession?.call(drag.id, groupId, targetId: targetId) ?? false;

  void _drop(
    _SessionDrag drag,
    String? groupId, {
    String? targetId,
    bool after = false,
  }) => (drag.saved ? onMoveSavedSession : onMoveSession)?.call(
    drag.id,
    groupId,
    targetId: targetId,
    after: after,
  );

  /// 상위 세션 바로 아래에 하위 세션이 오도록 펼칩니다.
  static List<(ManagedSession, int)> _flattenTree(
    List<ManagedSession> sessions,
  ) {
    final ids = {for (final s in sessions) s.sessionId};
    final result = <(ManagedSession, int)>[];
    void visit(ManagedSession session, int depth) {
      result.add((session, depth));
      for (final child in sessions) {
        if (child.parentSessionId == session.sessionId) visit(child, depth + 1);
      }
    }

    for (final session in sessions) {
      if (!ids.contains(session.parentSessionId)) visit(session, 0);
    }
    return result;
  }

  List<Widget> _sessionRows(
    List<ManagedSession> sessions,
    String? groupId,
  ) => [
    for (final (session, depth) in _flattenTree(sessions))
      _MovableRow(
        key: ValueKey('movable_session_${session.sessionId}'),
        drag: (id: session.sessionId, saved: false),
        title: session.title,
        canAccept: (drag) => _canDrop(drag, groupId, session.sessionId),
        onDrop: (drag, after) => _drop(
          drag,
          groupId,
          targetId: session.sessionId,
          after: after,
        ),
        child: _SessionRow(
          session: session,
          depth: depth,
          isSelected: session.sessionId == activeSessionId,
          onSelect: () => onSelectSession(session.sessionId),
          onStop: () => onStopSession(session.sessionId),
          onRetry: () => onRetrySession(session.sessionId),
          onRerun: (b) => onRerunWithBackend(session.sessionId, b),
          onIsolate: () => onIsolateWorktree(session.sessionId),
          onMerge: () => onMergeWorktree?.call(session.sessionId),
          onNewSession: () => onNewSession(session.sessionId),
          onNewChild: () => onNewChildSession?.call(session.sessionId),
          onSettings: () => onSessionSettings?.call(session.sessionId),
          onDelete: () => onDeleteSession?.call(session.sessionId),
        ),
      ),
  ];

  /// 저장된 그룹을 따르고, 그룹을 기록하기 전의 예전 기록은 같은 폴더의 그룹에 넣습니다.
  String? _groupIdOf(SessionSnapshot snapshot) {
    final all = groups ?? const <WorkspaceGroup>[];
    if (snapshot.groupId == SessionSnapshot.noGroup) return null;
    if (all.any((g) => g.id == snapshot.groupId)) return snapshot.groupId;
    for (final group in all) {
      if (p.equals(group.folder, snapshot.workingDirectory)) return group.id;
    }
    return null;
  }

  List<Widget> _savedRows(String? groupId) => [
    for (final snapshot in savedSessions)
      if (_groupIdOf(snapshot) == groupId)
        _MovableRow(
          key: ValueKey('movable_saved_${snapshot.id}'),
          drag: (id: snapshot.id, saved: true),
          title: snapshot.title,
          canAccept: (drag) => _canDrop(drag, groupId, snapshot.id),
          onDrop: (drag, after) =>
              _drop(drag, groupId, targetId: snapshot.id, after: after),
          child: ListTile(
            key: ValueKey('saved_session_${snapshot.id}'),
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: const Icon(Icons.history, size: 16),
            title: Text(
              snapshot.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              snapshot.backend.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => onOpenSavedSession?.call(snapshot, groupId),
          ),
        ),
  ];

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    final groupIds = {for (final g in groups ?? const []) g.id};
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
                  child: IconButton(
                    key: const ValueKey('new_session_button'),
                    tooltip: '새 세션',
                    onPressed: () => onNewSession(null),
                    icon: const Icon(Icons.edit_square),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                if (groups != null) ...[
                  _GroupSectionHeader(onNewGroup: onNewGroup),
                  for (final group in groups!)
                    _GroupTile(
                      group: group,
                      initiallyExpanded: !(isGroupCollapsed?.call(group.id) ?? false),
                      onExpansionChanged: (expanded) =>
                          onGroupCollapsedChanged?.call(group.id, !expanded),
                      onNewSession: () => onNewSessionInGroup?.call(group.id),
                      onEdit: () => onEditGroup?.call(group.id),
                      onDelete: () => onDeleteGroup?.call(group.id),
                      canAcceptDrop: (drag) => _canDrop(drag, group.id),
                      onDrop: (drag) => _drop(drag, group.id),
                      children: [
                        ..._sessionRows(
                          sessions.where((s) => s.groupId == group.id).toList(),
                          group.id,
                        ),
                        ..._savedRows(group.id),
                      ],
                    ),
                  const SizedBox(height: 8),
                ],
                _SectionDropZone(
                  key: const ValueKey('ungrouped_drop_zone'),
                  canAccept: (drag) => _canDrop(drag, null),
                  onDrop: (drag) => _drop(drag, null),
                  child: const _SidebarSectionLabel('작업 세션'),
                ),
                ..._sessionRows(
                  sessions
                      .where((s) => !groupIds.contains(s.groupId))
                      .toList(),
                  null,
                ),
                ..._savedRows(null),
              ],
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

/// 드래그로 옮길 수 있고, 다른 항목을 위쪽 절반에 놓으면 앞에, 아래쪽 절반에 놓으면 뒤에 받는 한 줄
// ponytail: 드래그 중 목록이 자동으로 스크롤되지 않습니다. 긴 목록에서 불편하면 가장자리 자동 스크롤을 더합니다.
class _MovableRow extends StatefulWidget {
  const _MovableRow({
    super.key,
    required this.drag,
    required this.title,
    required this.canAccept,
    required this.onDrop,
    required this.child,
  });

  final _SessionDrag drag;
  final String title;
  final bool Function(_SessionDrag drag) canAccept;
  final void Function(_SessionDrag drag, bool after) onDrop;
  final Widget child;

  @override
  State<_MovableRow> createState() => _MovableRowState();
}

class _MovableRowState extends State<_MovableRow> {
  bool _after = false;

  void _trackPointer(DragTargetDetails<_SessionDrag> details) {
    final box = context.findRenderObject()! as RenderBox;
    final after = box.globalToLocal(details.offset).dy > box.size.height / 2;
    if (after != _after) setState(() => _after = after);
  }

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    final edge = BorderSide(color: mac.blue, width: 2);
    return DragTarget<_SessionDrag>(
      onWillAcceptWithDetails: (details) => widget.canAccept(details.data),
      onMove: _trackPointer,
      onAcceptWithDetails: (details) => widget.onDrop(details.data, _after),
      builder: (context, candidates, _) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: candidates.isEmpty
              ? null
              : Border(
                  top: _after ? BorderSide.none : edge,
                  bottom: _after ? edge : BorderSide.none,
                ),
        ),
        child: Draggable<_SessionDrag>(
          data: widget.drag,
          // 앞뒤 판정이 포인터 위치를 기준으로 하도록 맞춥니다.
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: Material(
            color: mac.sidebar,
            elevation: 4,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 220),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: mac.label),
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.4, child: widget.child),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 항목을 놓으면 그 구역의 맨 끝으로 옮기는 그룹 이름·구역 제목 영역
class _SectionDropZone extends StatelessWidget {
  const _SectionDropZone({
    super.key,
    required this.canAccept,
    required this.onDrop,
    required this.child,
  });

  final bool Function(_SessionDrag drag) canAccept;
  final ValueChanged<_SessionDrag> onDrop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DragTarget<_SessionDrag>(
      onWillAcceptWithDetails: (details) => canAccept(details.data),
      onAcceptWithDetails: (details) => onDrop(details.data),
      builder: (context, candidates, _) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: candidates.isEmpty
              ? null
              : Border.all(color: context.mac.blue, width: 2),
        ),
        child: child,
      ),
    );
  }
}

class _GroupSectionHeader extends StatelessWidget {
  const _GroupSectionHeader({required this.onNewGroup});

  final VoidCallback? onNewGroup;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: _SidebarSectionLabel('작업 그룹')),
        IconButton(
          key: const ValueKey('new_group_button'),
          tooltip: '작업 그룹 만들기',
          onPressed: onNewGroup,
          icon: const Icon(Icons.create_new_folder_outlined, size: 15),
        ),
      ],
    );
  }
}

/// 접고 펼칠 수 있는 작업 그룹 한 줄과 그 안의 세션들
class _GroupTile extends StatelessWidget {
  const _GroupTile({
    required this.group,
    required this.initiallyExpanded,
    required this.onExpansionChanged,
    required this.onNewSession,
    required this.onEdit,
    required this.onDelete,
    required this.canAcceptDrop,
    required this.onDrop,
    required this.children,
  });

  final WorkspaceGroup group;
  final bool initiallyExpanded;
  final ValueChanged<bool> onExpansionChanged;
  final VoidCallback onNewSession;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool Function(_SessionDrag drag) canAcceptDrop;
  final ValueChanged<_SessionDrag> onDrop;
  final List<Widget> children;

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(height: 28, value: onNewSession, child: const Text('새 세션')),
        PopupMenuItem(
          key: const ValueKey('group_menu_settings'),
          height: 28,
          value: onEdit,
          child: const Text('그룹 설정'),
        ),
        const PopupMenuDivider(height: 8),
        PopupMenuItem(
          key: const ValueKey('group_menu_delete'),
          height: 28,
          value: onDelete,
          child: Text('삭제', style: TextStyle(color: context.mac.red)),
        ),
      ],
    );
    action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showContextMenu(context, details.globalPosition),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: ValueKey('group_tile_${group.id}'),
          initiallyExpanded: initiallyExpanded,
          onExpansionChanged: onExpansionChanged,
          dense: true,
          visualDensity: VisualDensity.compact,
          controlAffinity: ListTileControlAffinity.leading,
          tilePadding: const EdgeInsets.only(left: 4),
          childrenPadding: EdgeInsets.zero,
          minTileHeight: 30,
          title: _SectionDropZone(
            key: ValueKey('group_drop_zone_${group.id}'),
            canAccept: canAcceptDrop,
            onDrop: onDrop,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Tooltip(
                message: '신뢰 폴더: ${group.folder}',
                child: Text(
                  group.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: mac.label,
                  ),
                ),
              ),
            ),
          ),
          trailing: IconButton(
            key: ValueKey('new_session_in_group_${group.id}'),
            tooltip: '이 그룹에 새 세션',
            onPressed: onNewSession,
            icon: const Icon(Icons.add, size: 15),
          ),
          children: children,
        ),
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
    required this.depth,
    required this.isSelected,
    required this.onSelect,
    required this.onStop,
    required this.onRetry,
    required this.onRerun,
    required this.onIsolate,
    required this.onMerge,
    required this.onNewSession,
    required this.onNewChild,
    required this.onSettings,
    required this.onDelete,
  });

  final ManagedSession session;
  final int depth;
  final VoidCallback onNewChild;
  final bool isSelected;
  final VoidCallback onSelect;
  final VoidCallback onStop;
  final VoidCallback onRetry;
  final ValueChanged<BackendType> onRerun;
  final VoidCallback onIsolate;
  final VoidCallback onMerge;
  final VoidCallback onNewSession;
  final VoidCallback onSettings;
  final VoidCallback onDelete;

  Future<void> _showContextMenu(BuildContext context, Offset position) async {
    final mac = context.mac;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          key: const ValueKey('session_menu_new'),
          height: 28,
          value: onNewSession,
          child: const Text('새 세션'),
        ),
        PopupMenuItem(
          key: const ValueKey('session_menu_child'),
          height: 28,
          value: onNewChild,
          child: const Text('하위 세션'),
        ),
        PopupMenuItem(
          key: const ValueKey('session_menu_settings'),
          height: 28,
          value: onSettings,
          child: const Text('환경 설정'),
        ),
        const PopupMenuDivider(height: 8),
        PopupMenuItem(
          key: const ValueKey('session_menu_delete'),
          height: 28,
          value: onDelete,
          child: Text('삭제', style: TextStyle(color: mac.red)),
        ),
      ],
    );
    action?.call();
  }

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
      // 깊이가 깊어도 세션 이름이 보이도록 들여쓰기 폭을 제한합니다.
      padding: EdgeInsets.only(
        bottom: 2,
        left: (depth > 3 ? 3 : depth) * 12.0,
      ),
      child: GestureDetector(
        onSecondaryTapDown: (details) =>
            _showContextMenu(context, details.globalPosition),
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
                      if (depth > 0) ...[
                        Icon(
                          Icons.subdirectory_arrow_right,
                          key: ValueKey('session_child_${session.sessionId}'),
                          size: 13,
                          color: mac.tertiaryLabel,
                        ),
                        const SizedBox(width: 3),
                      ],
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
                      model: session.modelLabel,
                    ),
                  ),
                  if (session.childAttentionCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 14, top: 3),
                      child: Text(
                        '하위 작업 확인 필요 ${session.childAttentionCount}',
                        key: ValueKey('session_attention_${session.sessionId}'),
                        style: TextStyle(fontSize: 11, color: mac.orange),
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
                      style: TextStyle(
                        fontSize: 10.5,
                        color: mac.secondaryLabel,
                      ),
                    ),
                  ],
                ],
              ),
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
    final maxTokens = usageByBackend.values.fold(
      0,
      (largest, usage) => max(largest, usage.totalTokens),
    );
    return Padding(
      key: const ValueKey('backend_usage_summary'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final b in BackendType.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
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
                  const SizedBox(height: 2),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      key: ValueKey('sidebar_usage_bar_${b.id}'),
                      value: maxTokens == 0
                          ? 0
                          : (usageByBackend[b]?.totalTokens ?? 0) / maxTokens,
                      minHeight: 4,
                      color: mac.blue,
                      backgroundColor: mac.fill,
                      semanticsLabel:
                          '${b.displayName} 토큰 사용량 '
                          '${usageByBackend[b]?.totalTokens ?? 0}',
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
