import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/theme/mac_theme.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'core/backend/agent_backend.dart';
import 'core/models/agent_models.dart';
import 'services/app_settings_store.dart';
import 'services/effort_preference_store.dart';
import 'services/model_preference_store.dart';
import 'services/inbox_service.dart';
import 'services/notification_service.dart';
import 'services/permission_center.dart';
import 'services/provider_usage_service.dart';
import 'services/session_manager.dart';
import 'services/skill_registry.dart';
import 'services/trusted_folder_store.dart';
import 'services/workspace_group_store.dart';
import 'ui/screens/inbox_screen.dart';
import 'ui/screens/permission_center_screen.dart';
import 'ui/screens/skills_screen.dart';
import 'ui/screens/trusted_folders_screen.dart';
import 'ui/widgets/approval_and_question_dialogs.dart';
import 'ui/widgets/kv_cache_panel.dart';
import 'ui/widgets/mac_window_drag_area.dart';
import 'ui/widgets/multi_session_sidebar.dart';
import 'ui/widgets/prompt_input_bar.dart';
import 'ui/widgets/session_dialogs.dart';
import 'ui/widgets/timeline_widgets.dart';

void main() {
  runApp(const ProviderScope(child: AgentControlCenterApp()));
}

class AgentControlCenterApp extends StatelessWidget {
  const AgentControlCenterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '에이전트 컨트롤 센터',
      debugShowCheckedModeBanner: false,
      theme: buildMacTheme(Brightness.light),
      darkTheme: buildMacTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const ControlCenterHomeScreen(),
    );
  }
}

class ControlCenterHomeScreen extends StatefulWidget {
  const ControlCenterHomeScreen({
    super.key,
    this.backendOverride,
    this.sessionManagerOverride,
    this.inboxServiceOverride,
    this.notificationServiceOverride,
    this.settingsOverride,
    this.initialEvents = const [],
    this.initialRawLogs = const [],
    this.initialInstallStatuses = const {},
  });

  final AgentBackend? backendOverride;
  final SessionManager? sessionManagerOverride;
  final InboxService? inboxServiceOverride;
  final NotificationService? notificationServiceOverride;
  final AppSettingsStore? settingsOverride;
  final List<AgentEvent> initialEvents;
  final List<String> initialRawLogs;
  final Map<BackendType, BackendInstallationStatus> initialInstallStatuses;

  @override
  State<ControlCenterHomeScreen> createState() =>
      _ControlCenterHomeScreenState();
}

class _ControlCenterHomeScreenState extends State<ControlCenterHomeScreen> {
  late final SessionManager _sessionManager;
  late final NotificationService _notificationService;
  late final InboxService _inboxService;
  late final bool _ownsSessionManager;
  late final bool _ownsInboxService;
  late final AppSettingsStore _settings;
  StreamSubscription<NotificationDeepLink>? _deepLinkSub;
  late bool _showRawLogs;
  late bool _showSessionSidebar;
  late bool _showKvCachePanel;
  late TargetDeviceType _selectedDevice;
  final Map<BackendType, BackendInstallationStatus> _installStatuses = {};
  final ScrollController _timelineScroll = ScrollController();
  final ProviderUsageService _providerUsageService =
      const ProviderUsageService();
  List<ProviderUsage> _providerUsages = const [];
  Timer? _providerUsageTimer;
  bool _followTimeline = true;
  String? _timelineSessionId;

  /// 사용자가 위로 스크롤하면 따라가기를 멈추고, 맨 아래로 돌아오면 다시 따라갑니다.
  void _onTimelineScrolled() {
    final position = _timelineScroll.position;
    _followTimeline = position.pixels >= position.maxScrollExtent - 40;
  }

  void _followTimelineAfterBuild(String? sessionId) {
    if (_timelineSessionId != sessionId) {
      _timelineSessionId = sessionId;
      _followTimeline = true;
    }
    if (!_followTimeline) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_followTimeline && _timelineScroll.hasClients) {
        _timelineScroll.jumpTo(_timelineScroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _timelineScroll.addListener(_onTimelineScrolled);
    _installStatuses.addAll(widget.initialInstallStatuses);
    final usesRealEnvironment =
        widget.backendOverride == null && widget.sessionManagerOverride == null;
    _settings =
        widget.settingsOverride ??
        (usesRealEnvironment ? AppSettingsStore.load() : AppSettingsStore());
    _showRawLogs = _settings.showRawLogs;
    _showSessionSidebar = _settings.showSessionSidebar;
    _showKvCachePanel = _settings.showKvCachePanel;
    _selectedDevice = _settings.device;
    _notificationService =
        widget.notificationServiceOverride ??
        NotificationService(enableOsPlugin: usesRealEnvironment);

    if (widget.sessionManagerOverride != null) {
      _sessionManager = widget.sessionManagerOverride!;
      _ownsSessionManager = false;
    } else {
      // backendOverride는 주입 실행이므로 실제 폴더 신뢰·worktree 흐름을 적용하지 않습니다.
      final guarded = widget.backendOverride == null;
      _sessionManager = SessionManager(
        permissionCenter: guarded ? PermissionCenter.load() : null,
        trustedFolders: guarded ? TrustedFolderStore.load() : null,
        effortPreferences: guarded ? EffortPreferenceStore.load() : null,
        modelPreferences: guarded ? ModelPreferenceStore.load() : null,
        groups: guarded ? WorkspaceGroupStore.load() : null,
        skillRegistry: SkillRegistry(settings: _settings),
        autoOrchestrateByAntigravity: _settings.autoOrchestrate,
        useHelperAgent: guarded,
        defaultPermissionMode: guarded
            ? _settings.permissionMode ?? PermissionMode.auto
            : PermissionMode.manual,
        autoIsolateWithWorktree: guarded,
        onFolderTrustRequired: _confirmFolderTrust,
        onApprovalRequired: (session, req) {
          _notificationService.notify(
            kind: NotificationKind.approvalRequested,
            title: '승인 요청: ${req.toolName}',
            body: req.reason,
            targetId: req.id,
            sessionId: session.sessionId,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _openApprovalDialog(session.sessionId, req);
          });
        },
        onQuestionRequired: (session, req) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _openQuestionDialog(session.sessionId, req);
          });
        },
        onChildWorktreeFinished: (parent, child, message) {
          _notificationService.notify(
            kind: child.status == SessionStatus.failed
                ? NotificationKind.taskFailed
                : NotificationKind.taskCompleted,
            title: '하위 작업: ${child.title}',
            body: message,
            sessionId: parent.sessionId,
          );
        },
        onSessionFinished: (session, success) {
          // worktree 하위 세션은 상위 세션 알림으로 대신합니다.
          if (session.parentSessionId != null &&
              session.activeWorktreeLink != null) {
            return;
          }
          _notificationService.notify(
            kind: success
                ? NotificationKind.taskCompleted
                : NotificationKind.taskFailed,
            title: success
                ? '작업 완료: ${session.title}'
                : '작업 실패: ${session.title}',
            body: '${session.backendType.displayName} 세션 처리가 종료되었습니다.',
            sessionId: session.sessionId,
          );
        },
      );
      _sessionManager.permissionCenter.loadFromDatabase().ignore();
      _sessionManager.skillRegistry.discoverLocalSkills().ignore();
      final home = Platform.environment['HOME'];
      if (guarded && home != null) {
        _sessionManager.skillRegistry
            .installHandoffSkill(p.join(home, '.agent_control_center', 'skills'))
            .ignore();
      }
      _ownsSessionManager = true;
    }

    if (widget.inboxServiceOverride != null) {
      _inboxService = widget.inboxServiceOverride!;
      _ownsInboxService = false;
    } else {
      _inboxService = InboxService(
        notificationService: _notificationService,
        permissionCenter: _sessionManager.permissionCenter,
        stateFile: usesRealEnvironment ? InboxService.defaultStateFile() : null,
      )..startAutoMonitoring();
      _ownsInboxService = true;
    }

    _deepLinkSub = _notificationService.deepLinks.listen(_handleDeepLink);

    if (_sessionManager.sessions.isEmpty) {
      _sessionManager.createSession(
        sessionId: 'session_1',
        backendType: _settings.backend ?? BackendType.antigravity,
        workingDirectory: _settings.workingDirectory ?? Directory.current.path,
        backendOverride: widget.backendOverride,
        initialEvents: widget.initialEvents,
        initialRawLogs: widget.initialRawLogs,
      );
    }

    _sessionManager.addListener(_onManagerChanged);
    _sessionManager.skillRegistry.addListener(_onManagerChanged);
    _inboxService.addListener(_onManagerChanged);
    if (usesRealEnvironment) {
      _refreshProviderUsage();
      _providerUsageTimer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => _refreshProviderUsage(),
      );
    }
  }

  Future<void> _refreshProviderUsage() async {
    final usages = await _providerUsageService.load();
    if (mounted) setState(() => _providerUsages = usages);
  }

  void _handleDeepLink(NotificationDeepLink link) {
    if (!mounted) return;
    if (link.kind == NotificationKind.inboxSummary) {
      _openInboxDialog(initialSummaryId: link.targetId);
    } else if (link.sessionId.isNotEmpty) {
      _sessionManager.selectSession(link.sessionId);
    }
  }

  void _openInboxDialog({String? initialSummaryId}) {
    if (initialSummaryId != null && initialSummaryId.isNotEmpty) {
      _inboxService.selectSummary(initialSummaryId);
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => InboxSummaryDialog(
        inboxService: _inboxService,
        notificationService: _notificationService,
        initialSummaryId: initialSummaryId,
      ),
    );
  }

  Future<void> _isolateSession(String sessionId) async {
    try {
      await _sessionManager.isolateSessionWithWorktree(sessionId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('작업 디렉터리 격리 실패: $error')));
    }
  }

  Future<void> _mergeWorktree(String sessionId) async {
    try {
      await _sessionManager.mergeSessionWorktree(sessionId);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('병합 실패: $error')));
    }
  }

  Future<bool> _confirmFolderTrust(ManagedSession session) async {
    if (!mounted) return false;
    final trusted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('folder_trust_dialog'),
        title: const Text('이 폴더를 신뢰할까요?'),
        content: Text(
          '에이전트가 다음 폴더의 파일을 읽고 수정하며 명령을 실행할 수 있습니다.\n\n'
          '${session.workingDirectory}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('confirm_folder_trust_button'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('신뢰하고 실행'),
          ),
        ],
      ),
    );
    return trusted ?? false;
  }

  ManagedSession? _sessionById(String? sessionId) => _sessionManager.sessions
      .where((s) => s.sessionId == sessionId)
      .firstOrNull;

  Future<void> _openNewSessionDialog(String? sourceSessionId) async {
    final source = _sessionById(sourceSessionId);
    final groupId = source?.groupId;
    if (groupId != null) return _openNewSessionInGroup(groupId);
    final fallback = source ?? _sessionManager.activeSession;
    final initialBackend = fallback?.backendType ?? BackendType.antigravity;
    final efforts = _sessionManager.effortPreferences;
    final request = await showDialog<NewSessionRequest>(
      context: context,
      builder: (ctx) => NewSessionDialog(
        initialBackend: initialBackend,
        initialModel:
            _sessionManager.modelPreferences?.modelFor(initialBackend) ??
            fallback?.model,
        initialEffort:
            efforts?.effortFor(initialBackend) ??
            fallback?.effort ??
            ReasoningEffort.auto,
        initialFolder: fallback?.workingDirectory ?? Directory.current.path,
        trustedFolders: _sessionManager.trustedFolders,
        effortPreferences: efforts,
        modelPreferences: _sessionManager.modelPreferences,
        showInstructions: true,
        previousSessions: _sessionManager.searchSavedSessions(),
      ),
    );
    if (request == null) return;
    _createSessionFrom(request);
  }

  Future<void> _openNewSessionInGroup(String groupId) async {
    final store = _sessionManager.groups;
    final group = store?.groupById(groupId);
    if (store == null || group == null) return;
    final request = await showDialog<NewSessionRequest>(
      context: context,
      builder: (ctx) => NewSessionDialog(
        title: '새 세션 · ${group.name}',
        initialBackend: group.backend,
        initialModel: group.model,
        initialEffort: group.effort,
        initialFolder: group.folder,
        trustedFolders: _sessionManager.trustedFolders,
        effortPreferences: _sessionManager.effortPreferences,
        modelPreferences: _sessionManager.modelPreferences,
        showInstructions: true,
        lockFolder: true,
        previousSessions: store.snapshotsFor(groupId),
      ),
    );
    if (request == null) return;
    _createSessionFrom(request, groupId: groupId);
  }

  void _createSessionFrom(NewSessionRequest request, {String? groupId}) {
    _sessionManager.effortPreferences?.remember(request.backend, request.effort);
    _sessionManager.modelPreferences?.remember(request.backend, request.model);
    final session = _sessionManager.createSession(
      title: request.title,
      backendType: request.backend,
      model: request.model,
      effort: request.effort,
      workingDirectory: request.folder,
      groupId: groupId,
      instructions: request.instructions,
    );
    final previous = request.continueFrom;
    if (previous != null) {
      _sessionManager.continueFromSnapshot(session.sessionId, previous);
    }
  }

  Future<void> _openSavedSession(
    SessionSnapshot snapshot,
    String? groupId,
  ) async {
    final session = _sessionManager.createSession(
      title: snapshot.title,
      backendType: snapshot.backend,
      model: snapshot.model.isEmpty ? null : snapshot.model,
      effort: snapshot.effort,
      workingDirectory: snapshot.workingDirectory.isEmpty
          ? Directory.current.path
          : snapshot.workingDirectory,
      groupId: groupId,
      instructions: snapshot.instructions,
      permissionMode: snapshot.permissionMode,
    );
    await _sessionManager.reopenSnapshot(session.sessionId, snapshot);
  }

  Future<void> _openChildSessionDialog(String parentSessionId) async {
    final parent = _sessionById(parentSessionId);
    if (parent == null) return;
    final request = await showDialog<NewSessionRequest>(
      context: context,
      builder: (ctx) => NewSessionDialog(
        title: '하위 세션 · ${parent.title}',
        initialBackend: parent.backendType,
        initialModel: parent.model,
        initialEffort: parent.effort,
        initialFolder: parent.workingDirectory,
        initialInstructions: parent.instructions,
        trustedFolders: _sessionManager.trustedFolders,
        effortPreferences: _sessionManager.effortPreferences,
        modelPreferences: _sessionManager.modelPreferences,
        showInstructions: true,
        lockFolder: parent.groupId != null,
        note: '상위 세션의 컨텍스트를 압축해 가져갑니다.',
      ),
    );
    if (request == null || _sessionById(parentSessionId) == null) return;
    _sessionManager.effortPreferences?.remember(request.backend, request.effort);
    _sessionManager.modelPreferences?.remember(request.backend, request.model);
    _sessionManager.createChildSession(
      parentSessionId,
      title: request.title,
      backendType: request.backend,
      model: request.model,
      effort: request.effort,
      workingDirectory: request.folder,
      instructions: request.instructions,
    );
  }

  Future<void> _openGroupDialog({WorkspaceGroup? group}) async {
    final store = _sessionManager.groups;
    if (store == null) return;
    final result = await showDialog<WorkspaceGroupResult>(
      context: context,
      builder: (ctx) => WorkspaceGroupDialog(
        group: group,
        defaultInstructions: store.defaultInstructions,
        initialFolder:
            _sessionManager.activeSession?.workingDirectory ??
            Directory.current.path,
        trustedFolders: _sessionManager.trustedFolders,
        effortPreferences: _sessionManager.effortPreferences,
        modelPreferences: _sessionManager.modelPreferences,
      ),
    );
    if (result == null) return;
    _sessionManager.modelPreferences?.remember(
      result.group.backend,
      result.group.model,
    );
    _sessionManager.saveGroup(
      result.group,
      defaultInstructions: result.defaultInstructions,
    );
  }

  Future<void> _confirmDeleteGroup(String groupId) async {
    final group = _sessionManager.groups?.groupById(groupId);
    if (group == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('delete_group_dialog'),
        title: const Text('작업 그룹을 삭제할까요?'),
        content: Text('"${group.name}"의 지침과 이전 세션 기록이 사라집니다. 열린 세션은 그룹 밖으로 옮겨집니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('confirm_delete_group_button'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true) _sessionManager.deleteGroup(groupId);
  }

  /// 권한 무시는 파괴적 작업까지 묻지 않으므로 켜기 전에 한 번 더 확인합니다.
  Future<void> _changePermissionMode(
    String sessionId,
    PermissionMode mode,
  ) async {
    if (mode == PermissionMode.bypass) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const ValueKey('bypass_mode_dialog'),
          title: const Text('권한 무시를 켤까요?'),
          content: const Text(
            '이 세션의 에이전트가 파일 삭제와 강제 푸시 같은 파괴적인 작업도 묻지 않고 실행합니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              key: const ValueKey('confirm_bypass_mode_button'),
              style: FilledButton.styleFrom(
                backgroundColor: context.mac.red,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('활성화'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    _sessionManager.updateSessionPermissionMode(sessionId, mode);
    if (mode != PermissionMode.bypass) {
      _settings.permissionMode = mode;
      _sessionManager.defaultPermissionMode = mode;
    }
  }

  Future<void> _openSessionSettings(String sessionId) async {
    final session = _sessionById(sessionId);
    if (session == null) return;
    final result = await showDialog<SessionSettingsResult>(
      context: context,
      builder: (ctx) => SessionSettingsDialog(
        session: session,
        trustedFolders: _sessionManager.trustedFolders,
        effortPreferences: _sessionManager.effortPreferences,
        modelPreferences: _sessionManager.modelPreferences,
      ),
    );
    // 다이얼로그가 열린 사이 세션이 삭제되었을 수 있습니다.
    if (result == null || _sessionById(sessionId) == null) {
      if (mounted) setState(() {});
      return;
    }
    _sessionManager.updateSessionTitle(sessionId, result.title);
    if (result.backend != session.backendType) {
      _sessionManager.updateSessionBackend(
        sessionId,
        result.backend,
        model: result.model,
        replaceAdapter: widget.backendOverride == null,
      );
    } else if (result.model != null) {
      _sessionManager.updateSessionModel(sessionId, result.model!);
    }
    // 이름만 바꿔 저장해도 예전 세션의 강도가 기억되지 않도록 변경된 경우에만 반영합니다.
    if (result.effort != session.effort) {
      _sessionManager.updateSessionEffort(sessionId, result.effort);
    }
    if (result.folder != session.workingDirectory) {
      _sessionManager.updateSessionWorkingDirectory(sessionId, result.folder);
    }
    _sessionManager.updateSessionInstructions(sessionId, result.instructions);
    if (mounted) setState(() {});
  }

  Future<void> _confirmDeleteSession(String sessionId) async {
    final session = _sessionById(sessionId);
    if (session == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => DeleteSessionDialog(session: session),
    );
    if (confirmed != true) return;
    final kept = await _sessionManager.deleteSession(sessionId);
    if (kept == null || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('변경 사항이 있어 worktree를 남겼습니다: $kept')));
  }

  void _setSelectedDevice(TargetDeviceType device) {
    _settings.device = device;
    setState(() => _selectedDevice = device);
  }

  void _onManagerChanged() {
    // 다음 실행의 첫 세션이 마지막에 쓰던 백엔드와 폴더로 시작합니다.
    final active = _sessionManager.activeSession;
    if (active != null) {
      _settings.backend = active.backendType;
      _settings.workingDirectory = active.workingDirectory;
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openApprovalDialog(
    String sessionId,
    ApprovalRequestData req,
  ) async {
    final session = _sessionManager.sessions
        .where((s) => s.sessionId == sessionId)
        .firstOrNull;
    if (session != null && session.resolvedRequestIds.contains(req.id)) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => UnifiedApprovalDialog(
        request: req,
        onDecision: (rawDecision) {
          _sessionManager.respondToApproval(sessionId, req, rawDecision);
          Navigator.of(ctx).pop();
        },
      ),
    );
  }

  Future<void> _openQuestionDialog(
    String sessionId,
    QuestionRequestData req,
  ) async {
    final session = _sessionManager.sessions
        .where((s) => s.sessionId == sessionId)
        .firstOrNull;
    if (session != null && session.resolvedRequestIds.contains(req.id)) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AgentQuestionDialog(
        request: req,
        onSubmitAnswers: (answers) {
          _sessionManager.respondToQuestion(sessionId, req.id, answers);
          Navigator.of(ctx).pop();
        },
      ),
    );
  }

  @override
  void dispose() {
    _providerUsageTimer?.cancel();
    _timelineScroll.dispose();
    _deepLinkSub?.cancel();
    _inboxService.removeListener(_onManagerChanged);
    _sessionManager.skillRegistry.removeListener(_onManagerChanged);
    _sessionManager.removeListener(_onManagerChanged);
    if (_ownsInboxService) {
      _inboxService.dispose();
    }
    if (_ownsSessionManager) {
      _sessionManager.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _sessionManager.activeSession;
    final selectedBackend = active?.backendType ?? BackendType.antigravity;
    final selectedModel = active?.model ?? selectedBackend.defaultModel;
    final workingDir = active?.effectiveDirectory ?? Directory.current.path;
    final events = active?.events ?? const <AgentEvent>[];
    final rawLogs = active?.rawLogs ?? const <String>[];
    final isBusy =
        active?.status == SessionStatus.running ||
        active?.status == SessionStatus.awaitingApproval;
    _followTimelineAfterBuild(active?.sessionId);

    return Scaffold(
      backgroundColor: context.mac.sidebar,
      // 포커스가 입력창 밖에 있어도 ⌘C/Ctrl+C가 현재 세션의 실행을 중지합니다.
      // CallbackShortcuts는 항상 키를 소비하므로 복사를 넘겨주려면 직접 처리합니다.
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (!isBusy ||
              !_stopShortcut.accepts(event, HardwareKeyboard.instance) ||
              _hasFocusedTextSelection()) {
            return KeyEventResult.ignored;
          }
          _sessionManager.stopSession(active!.sessionId);
          return KeyEventResult.handled;
        },
        child: _buildBody(
          active: active,
          selectedBackend: selectedBackend,
          selectedModel: selectedModel,
          workingDir: workingDir,
          events: events,
          rawLogs: rawLogs,
          isBusy: isBusy,
        ),
      ),
    );
  }

  static final _stopShortcut = SingleActivator(
    LogicalKeyboardKey.keyC,
    meta: Platform.isMacOS,
    control: !Platform.isMacOS,
  );

  /// 선택한 글자가 있으면 ⌘C/Ctrl+C는 중지가 아니라 복사입니다.
  bool _hasFocusedTextSelection() {
    final selection = FocusManager.instance.primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>()
        ?.textEditingValue
        .selection;
    return selection != null && selection.isValid && !selection.isCollapsed;
  }

  Widget _buildBody({
    required ManagedSession? active,
    required BackendType selectedBackend,
    required String selectedModel,
    required String workingDir,
    required List<AgentEvent> events,
    required List<String> rawLogs,
    required bool isBusy,
  }) {
    final fileChanges = events.whereType<FileDiffEvent>().toList();
    final timelineEvents = events.where((e) => e is! FileDiffEvent).toList();
    return Row(
      children: [
        if (_showSessionSidebar)
          MultiSessionSidebar(
            sessions: _sessionManager.sessions,
            savedSessions: _sessionManager
                .searchSavedSessions('', 50)
                .where(
                  (snapshot) => !_sessionManager.sessions.any(
                    (session) => session.snapshotId == snapshot.id,
                  ),
                )
                .toList(),
            onOpenSavedSession: _openSavedSession,
            activeSessionId: _sessionManager.activeSessionId,
            usageByBackend: _sessionManager.usageByBackend,
            onSelectSession: _sessionManager.selectSession,
            onNewSession: _openNewSessionDialog,
            groups: _sessionManager.groups?.groups,
            onNewGroup: () => _openGroupDialog(),
            onNewSessionInGroup: _openNewSessionInGroup,
            onEditGroup: (id) =>
                _openGroupDialog(group: _sessionManager.groups?.groupById(id)),
            onDeleteGroup: _confirmDeleteGroup,
            isGroupCollapsed: _settings.isGroupCollapsed,
            onGroupCollapsedChanged: _settings.setGroupCollapsed,
            onNewChildSession: _openChildSessionDialog,
            onSessionSettings: _openSessionSettings,
            onDeleteSession: _confirmDeleteSession,
            onStopSession: _sessionManager.stopSession,
            onRetrySession: _sessionManager.retrySession,
            onRerunWithBackend: (sessionId, backend) {
              _sessionManager.rerunWithBackend(sessionId, backend);
            },
            onIsolateWorktree: _isolateSession,
            onMergeWorktree: _mergeWorktree,
            trustedFolderCount: _sessionManager.trustedFolders?.folders.length,
            onManageTrustedFolders: () async {
              await showDialog<void>(
                context: context,
                builder: (ctx) => TrustedFoldersDialog(
                  store: _sessionManager.trustedFolders!,
                ),
              );
              setState(() {});
            },
            selectedDevice: _selectedDevice,
            onDeviceChanged: _setSelectedDevice,
            autoOrchestrateByAntigravity:
                _sessionManager.autoOrchestrateByAntigravity,
            onAutoOrchestrateChanged: (enabled) {
              _settings.autoOrchestrate = enabled;
              _sessionManager.setAutoOrchestration(enabled);
            },
          ),
        if (_showSessionSidebar) const VerticalDivider(width: 0.5),
        Expanded(
          child: ColoredBox(
            color: context.mac.window,
            child: Column(
              children: [
                _buildToolbar(active),
                const Divider(),
                if (_installStatuses[selectedBackend]?.isInstalled == false)
                  Container(
                    key: const ValueKey('missing_backend_banner'),
                    color: context.mac.orange.withValues(alpha: 0.2),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber, color: context.mac.orange),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${selectedBackend.displayName} CLI가 설치되어 있지 않습니다. '
                            '설치 안내: ${selectedBackend.installGuide}',
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (active != null && active.hasDirectoryConflict)
                  Container(
                    key: const ValueKey('active_session_conflict_banner'),
                    color: context.mac.orange.withValues(alpha: 0.2),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          color: context.mac.orange,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            '경고: 다른 실행 중인 작업 세션과 동일한 작업 디렉터리를 공유하고 있습니다.',
                            style: TextStyle(fontSize: 12.5),
                          ),
                        ),
                        FilledButton.tonalIcon(
                          key: const ValueKey('banner_isolate_worktree_btn'),
                          onPressed: () => _isolateSession(active.sessionId),
                          icon: const Icon(Icons.call_split, size: 15),
                          label: const Text('git worktree로 분리'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: events.isEmpty
                            ? _EmptyTimeline(hasSession: active != null)
                            : ListView.builder(
                                controller: _timelineScroll,
                                padding: const EdgeInsets.all(16),
                                itemCount:
                                    timelineEvents.length +
                                    (fileChanges.isEmpty ? 0 : 1),
                                itemBuilder: (context, index) {
                                  if (index == timelineEvents.length) {
                                    return FileChangesCard(events: fileChanges);
                                  }
                                  return _buildTimelineItem(
                                    active?.sessionId ?? 'session_1',
                                    timelineEvents[index],
                                    active?.resolvedRequestIds ?? const {},
                                  );
                                },
                              ),
                      ),
                      if (_showRawLogs)
                        Expanded(
                          flex: 2,
                          child: Container(
                            decoration: BoxDecoration(
                              color: context.mac.codeBackground,
                              border: Border(
                                left: BorderSide(
                                  color: Theme.of(context).dividerColor,
                                ),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  color: context.mac.codeHeader,
                                  child: const Text(
                                    '원본 JSON 스트림 로그 (Raw Logs)',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      fontFamily: kMonoFont,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: ListView.builder(
                                    padding: const EdgeInsets.all(10),
                                    itemCount: rawLogs.length,
                                    itemBuilder: (context, i) => SelectableText(
                                      rawLogs[i],
                                      style: TextStyle(
                                        fontFamily: kMonoFont,
                                        fontSize: 11,
                                        color: context.mac.green,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (_showKvCachePanel) ...[
                        const VerticalDivider(width: 0.5),
                        KvCachePanel(
                          session: active?.usage ?? const TokenUsage(),
                          usageByBackend: _sessionManager.usageByBackend,
                          providerUsages: _providerUsages,
                        ),
                      ],
                    ],
                  ),
                ),
                if (isBusy && active != null)
                  AgentActivityBar(
                    activity: describeAgentActivity(
                      events,
                      awaitingApproval:
                          active.status == SessionStatus.awaitingApproval,
                    ),
                    startedAt: active.turnStartedAt ?? DateTime.now(),
                  ),
                PromptInputBar(
                  skills: _sessionManager.skillRegistry.skills,
                  savedSessions: _sessionManager.searchSavedSessions('', 50),
                  onLoadSession: active == null
                      ? null
                      : (s) => _sessionManager.loadSnapshot(active.sessionId, s),
                  selectedBackend: selectedBackend,
                  selectedModel: selectedModel,
                  workingDirectory: workingDir,
                  workingDirectoryLocked: active?.groupId != null,
                  selectedDevice: _selectedDevice,
                  onDeviceChanged: _setSelectedDevice,
                  isBusy: isBusy,
                  onBackendChanged: (b) {
                    if (active != null) {
                      _sessionManager.updateSessionBackend(
                        active.sessionId,
                        b,
                        replaceAdapter: widget.backendOverride == null,
                      );
                    }
                  },
                  selectedPermissionMode:
                      active?.permissionMode ?? PermissionMode.manual,
                  onPermissionModeChanged: active == null
                      ? null
                      : (mode) => _changePermissionMode(active.sessionId, mode),
                  selectedEffort: active?.effort ?? ReasoningEffort.auto,
                  onEffortChanged: (effort) {
                    if (active != null) {
                      _sessionManager.updateSessionEffort(
                        active.sessionId,
                        effort,
                      );
                    }
                  },
                  onModelChanged: (m) {
                    if (active != null) {
                      _sessionManager.updateSessionModel(active.sessionId, m);
                    }
                  },
                  onWorkingDirectoryChanged: (dir) {
                    if (active != null) {
                      _sessionManager.updateSessionWorkingDirectory(
                        active.sessionId,
                        dir,
                      );
                    }
                  },
                  onSubmit: (prompt, attachments) {
                    if (active != null) {
                      _sessionManager.dispatchOrchestratedPrompt(
                        active.sessionId,
                        prompt,
                        attachments: attachments,
                      );
                    }
                  },
                  onInterrupt: () {
                    if (active != null) {
                      _sessionManager.stopSession(active.sessionId);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(ManagedSession? active) {
    final mac = context.mac;
    final backend = active?.backendType ?? BackendType.antigravity;
    final inboxCount = _inboxService.summaries.length;
    return MacWindowDragArea(
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            // 사이드바를 접으면 신호등 버튼 자리를 비웁니다.
            SizedBox(width: _showSessionSidebar || !Platform.isMacOS ? 10 : 78),
            IconButton(
              key: const ValueKey('toggle_sidebar_button'),
              tooltip: '사이드바 ${_showSessionSidebar ? '숨기기' : '보기'}',
              icon: const Icon(Icons.view_sidebar_outlined),
              onPressed: () {
                setState(() {
                  _showSessionSidebar = !_showSessionSidebar;
                });
                _settings.showSessionSidebar = _showSessionSidebar;
              },
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '에이전트 컨트롤 센터',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  BackendModelBadge(
                    backend: backend,
                    model: active?.modelLabel ?? backend.defaultModel,
                  ),
                ],
              ),
            ),
            if (active != null && _sessionManager.trustedFolders != null) ...[
              const SizedBox(width: 8),
              Flexible(
                child: _TrustedFolderIndicator(
                  workingDirectory: active.workingDirectory,
                  coveringFolders: _sessionManager.trustedFolders!
                      .coveringFolders(active.workingDirectory),
                  onTap: () => _openSessionSettings(active.sessionId),
                ),
              ),
              const SizedBox(width: 8),
            ],
            IconButton(
              key: const ValueKey('open_inbox_screen_button'),
              tooltip: 'Inbox 요약 ($inboxCount)',
              onPressed: () => _openInboxDialog(),
              icon: Badge.count(
                count: inboxCount,
                isLabelVisible: inboxCount > 0,
                backgroundColor: mac.red,
                child: const Icon(Icons.inbox_outlined),
              ),
            ),
            IconButton(
              key: const ValueKey('open_skills_screen_button'),
              tooltip: '스킬 관리',
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (ctx) => SkillsManagementDialog(
                    skillRegistry: _sessionManager.skillRegistry,
                    onInvokeSkill: (skill, prompt) {
                      if (active != null) {
                        _sessionManager.invokeSkill(
                          active.sessionId,
                          skill,
                          prompt,
                        );
                      }
                    },
                  ),
                );
              },
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
            IconButton(
              key: const ValueKey('open_permission_center_button'),
              tooltip: '권한 센터',
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (ctx) => PermissionCenterDialog(
                    permissionCenter: _sessionManager.permissionCenter,
                  ),
                );
              },
              icon: const Icon(Icons.admin_panel_settings_outlined),
            ),
            IconButton(
              key: const ValueKey('kv_cache_toggle'),
              tooltip: '사용량·KV 캐시 ${_showKvCachePanel ? '숨기기' : '보기'}',
              isSelected: _showKvCachePanel,
              selectedIcon: Icon(Icons.memory, color: mac.blue),
              icon: const Icon(Icons.memory),
              onPressed: () {
                setState(() {
                  _showKvCachePanel = !_showKvCachePanel;
                });
                _settings.showKvCachePanel = _showKvCachePanel;
              },
            ),
            IconButton(
              key: const ValueKey('raw_log_toggle'),
              tooltip: '원본 로그 보기',
              isSelected: _showRawLogs,
              selectedIcon: Icon(Icons.terminal, color: mac.blue),
              icon: const Icon(Icons.terminal),
              onPressed: () {
                setState(() {
                  _showRawLogs = !_showRawLogs;
                });
                _settings.showRawLogs = _showRawLogs;
              },
            ),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineItem(
    String sessionId,
    AgentEvent event,
    Set<String> resolvedIds,
  ) {
    switch (event) {
      case MessageEvent():
        final isUser = event.role == 'user';
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isUser ? context.mac.selection : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isUser ? Icons.person : Icons.auto_awesome_mosaic,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      isUser
                          ? '사용자 (주영님)'
                          : event.role == 'system'
                          ? '시스템'
                          : '에이전트 응답',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: BackendModelBadge(
                      backend: event.backend,
                      model: event.model,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (event.thinking.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '✻ ${event.thinking}',
                    style: TextStyle(
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      color: context.mac.secondaryLabel,
                    ),
                  ),
                ),
              MarkdownMessageView(markdown: event.text),
              if (event.id.startsWith('cmd_sys_') &&
                  (_sessionById(sessionId)?.lastSearchResults.isNotEmpty ??
                      false)) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in _sessionById(sessionId)!.lastSearchResults)
                      ActionChip(
                        key: ValueKey('load_session_${s.id}'),
                        avatar: const Icon(Icons.restore, size: 14),
                        label: Text(
                          '${s.title} 불러오기',
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: () =>
                            _sessionManager.loadSnapshot(sessionId, s),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      case ToolCallEvent():
        return ToolCallCard(event: event);
      case FileDiffEvent():
        return FileDiffViewerCard(event: event);
      case SkillInvokedEvent():
        return SkillInvokedBanner(event: event);
      case ChildWorktreeEvent():
        return ChildWorktreeNotice(
          event: event,
          onOpen: () => _sessionManager.selectSession(event.childSessionId),
          onMerge: () => _mergeWorktree(event.childSessionId),
        );
      case ErrorEvent():
        return Card(
          color: context.mac.red.withValues(alpha: 0.15),
          child: ListTile(
            leading: Icon(Icons.error, color: context.mac.red),
            title: Text(event.message),
            trailing: BackendModelBadge(
              backend: event.backend,
              model: event.model,
            ),
          ),
        );
      case DoneEvent():
        if (event.stopReason == DoneEvent.interrupted) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  Icons.stop_circle_outlined,
                  size: 15,
                  color: context.mac.red,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '사용자가 중지했습니다. 다음 프롬프트로 대화를 이어갈 수 있습니다.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: context.mac.secondaryLabel,
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(
                Icons.check_circle_outline,
                size: 15,
                color: context.mac.green,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '턴 완료 (${event.durationMs}ms · 총 토큰: ${event.usage.totalTokens})',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: context.mac.secondaryLabel,
                  ),
                ),
              ),
            ],
          ),
        );
      case ApprovalRequestEvent():
        final resolved = resolvedIds.contains(event.request.id);
        return Card(
          color: context.mac.orange.withValues(alpha: 0.15),
          child: ListTile(
            leading: Icon(Icons.security, color: context.mac.orange),
            title: Text('승인 요청: ${event.request.toolName}'),
            subtitle: Text(event.request.reason),
            trailing: resolved
                ? const Chip(label: Text('응답 완료'))
                : FilledButton.tonal(
                    key: ValueKey('open_approval_${event.request.id}'),
                    onPressed: () =>
                        _openApprovalDialog(sessionId, event.request),
                    child: const Text('승인 응답하기'),
                  ),
          ),
        );
      case QuestionEvent():
        final resolved = resolvedIds.contains(event.request.id);
        return Card(
          color: context.mac.blue.withValues(alpha: 0.15),
          child: ListTile(
            leading: Icon(Icons.help_outline, color: context.mac.blue),
            title: Text(
              '에이전트 질문: ${event.request.questions.map((q) => q.question).join(", ")}',
            ),
            trailing: resolved
                ? const Chip(label: Text('답변 완료'))
                : FilledButton.tonal(
                    key: ValueKey('open_question_${event.request.id}'),
                    onPressed: () =>
                        _openQuestionDialog(sessionId, event.request),
                    child: const Text('답변하기'),
                  ),
          ),
        );
    }
  }
}

class _EmptyTimeline extends StatelessWidget {
  const _EmptyTimeline({required this.hasSession});

  final bool hasSession;

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hub_outlined, size: 32, color: mac.tertiaryLabel),
          const SizedBox(height: 10),
          Text(
            hasSession ? '아직 실행된 대화가 없습니다.' : '세션이 없습니다.',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: mac.label,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hasSession
                ? '하단 입력창에서 프롬프트를 입력해 주세요.'
                : '사이드바 상단 버튼으로 새 세션을 만들어 주세요.',
            style: TextStyle(fontSize: 12, color: mac.secondaryLabel),
          ),
        ],
      ),
    );
  }
}

/// 현재 세션 폴더에 신뢰를 주는 폴더와 신뢰 상태를 도구 막대에 표시합니다.
class _TrustedFolderIndicator extends StatelessWidget {
  const _TrustedFolderIndicator({
    required this.workingDirectory,
    required this.coveringFolders,
    required this.onTap,
  });

  final String workingDirectory;
  final List<String> coveringFolders;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    final isTrusted = coveringFolders.isNotEmpty;
    // 여러 폴더가 해당하면 작업 폴더에 가장 가까운 등록을 보여 줍니다.
    final trustedFolder = isTrusted
        ? coveringFolders.reduce((a, b) => a.length >= b.length ? a : b)
        : null;
    final color = isTrusted ? mac.green : mac.orange;
    return Tooltip(
      message: isTrusted
          ? '신뢰 폴더: $trustedFolder\n작업 폴더: $workingDirectory\n클릭하면 세션 환경 설정을 엽니다.'
          : '신뢰하지 않은 폴더: $workingDirectory\n클릭하면 세션 환경 설정을 엽니다.',
      child: InkWell(
        key: const ValueKey('trusted_folder_indicator'),
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: mac.fill,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isTrusted
                    ? Icons.verified_user_outlined
                    : Icons.gpp_maybe_outlined,
                size: 14,
                color: color,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  isTrusted
                      ? p.basename(trustedFolder!)
                      : '신뢰 안 됨 · ${p.basename(workingDirectory)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: mac.label),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
