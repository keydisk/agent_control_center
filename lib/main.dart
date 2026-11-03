import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'ui/theme/mac_theme.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/backend/agent_backend.dart';
import 'core/models/agent_models.dart';
import 'services/inbox_service.dart';
import 'services/notification_service.dart';
import 'services/session_manager.dart';
import 'services/trusted_folder_store.dart';
import 'ui/screens/inbox_screen.dart';
import 'ui/screens/permission_center_screen.dart';
import 'ui/screens/skills_screen.dart';
import 'ui/screens/trusted_folders_screen.dart';
import 'ui/widgets/approval_and_question_dialogs.dart';
import 'ui/widgets/mac_window_drag_area.dart';
import 'ui/widgets/multi_session_sidebar.dart';
import 'ui/widgets/prompt_input_bar.dart';
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
    this.initialEvents = const [],
    this.initialRawLogs = const [],
    this.initialInstallStatuses = const {},
  });

  final AgentBackend? backendOverride;
  final SessionManager? sessionManagerOverride;
  final InboxService? inboxServiceOverride;
  final NotificationService? notificationServiceOverride;
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
  StreamSubscription<NotificationDeepLink>? _deepLinkSub;
  bool _showRawLogs = false;
  bool _showSessionSidebar = true;
  TargetDeviceType _selectedDevice = TargetDeviceType.macosDesktop;
  final Map<BackendType, BackendInstallationStatus> _installStatuses = {};

  @override
  void initState() {
    super.initState();
    _installStatuses.addAll(widget.initialInstallStatuses);
    _notificationService =
        widget.notificationServiceOverride ??
        NotificationService(enableOsPlugin: false);

    if (widget.sessionManagerOverride != null) {
      _sessionManager = widget.sessionManagerOverride!;
      _ownsSessionManager = false;
    } else {
      // backendOverride는 주입 실행이므로 실제 폴더 신뢰·worktree 흐름을 적용하지 않습니다.
      final guarded = widget.backendOverride == null;
      _sessionManager = SessionManager(
        trustedFolders: guarded ? TrustedFolderStore.load() : null,
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
        onSessionFinished: (session, success) {
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
      _sessionManager.skillRegistry.discoverLocalSkills().ignore();
      _ownsSessionManager = true;
    }

    if (widget.inboxServiceOverride != null) {
      _inboxService = widget.inboxServiceOverride!;
      _ownsInboxService = false;
    } else {
      _inboxService = InboxService(
        notificationService: _notificationService,
        permissionCenter: _sessionManager.permissionCenter,
      )..startAutoMonitoring();
      _ownsInboxService = true;
    }

    _deepLinkSub = _notificationService.deepLinks.listen(_handleDeepLink);

    if (_sessionManager.sessions.isEmpty) {
      _sessionManager.createSession(
        sessionId: 'session_1',
        title: '작업 #1 (${BackendType.antigravity.displayName})',
        backendType: BackendType.antigravity,
        workingDirectory: Directory.current.path,
        backendOverride: widget.backendOverride,
        initialEvents: widget.initialEvents,
        initialRawLogs: widget.initialRawLogs,
      );
    }

    _sessionManager.addListener(_onManagerChanged);
    _sessionManager.skillRegistry.addListener(_onManagerChanged);
    _inboxService.addListener(_onManagerChanged);
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

  void _onManagerChanged() {
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

    return Scaffold(
      backgroundColor: context.mac.sidebar,
      body: Row(
        children: [
          if (_showSessionSidebar)
            MultiSessionSidebar(
              sessions: _sessionManager.sessions,
              activeSessionId: _sessionManager.activeSessionId,
              usageByBackend: _sessionManager.usageByBackend,
              onSelectSession: _sessionManager.selectSession,
              onCreateSession: (backend) {
                _sessionManager.createSession(
                  backendType: backend,
                  workingDirectory: workingDir,
                );
              },
              onStopSession: _sessionManager.stopSession,
              onRetrySession: _sessionManager.retrySession,
              onRerunWithBackend: (sessionId, backend) {
                _sessionManager.rerunWithBackend(sessionId, backend);
              },
              onIsolateWorktree: _isolateSession,
              onMergeWorktree: _mergeWorktree,
              trustedFolderCount:
                  _sessionManager.trustedFolders?.folders.length,
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
              onDeviceChanged: (device) {
                setState(() {
                  _selectedDevice = device;
                });
              },
              autoOrchestrateByAntigravity:
                  _sessionManager.autoOrchestrateByAntigravity,
              onAutoOrchestrateChanged: _sessionManager.setAutoOrchestration,
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
                              ? const _EmptyTimeline()
                              : ListView.builder(
                                  padding: const EdgeInsets.all(16),
                                  itemCount: events.length,
                                  itemBuilder: (context, index) =>
                                      _buildTimelineItem(
                                        active?.sessionId ?? 'session_1',
                                        events[index],
                                        active?.resolvedRequestIds ?? const {},
                                      ),
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
                                      itemBuilder: (context, i) =>
                                          SelectableText(
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
                      ],
                    ),
                  ),
                  PromptInputBar(
                    skills: _sessionManager.skillRegistry.skills,
                    selectedBackend: selectedBackend,
                    selectedModel: selectedModel,
                    workingDirectory: workingDir,
                    selectedDevice: _selectedDevice,
                    onDeviceChanged: (device) {
                      setState(() {
                        _selectedDevice = device;
                      });
                    },
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
      ),
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
                    model: active?.model ?? backend.defaultModel,
                  ),
                ],
              ),
            ),
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
              key: const ValueKey('raw_log_toggle'),
              tooltip: '원본 로그 보기',
              isSelected: _showRawLogs,
              selectedIcon: Icon(Icons.terminal, color: mac.blue),
              icon: const Icon(Icons.terminal),
              onPressed: () {
                setState(() {
                  _showRawLogs = !_showRawLogs;
                });
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
            color: isUser
                ? context.mac.selection
                : Colors.transparent,
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
                      isUser ? '사용자 (주영님)' : '에이전트 응답',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  BackendModelBadge(backend: event.backend, model: event.model),
                ],
              ),
              const SizedBox(height: 8),
              MarkdownMessageView(markdown: event.text),
            ],
          ),
        );
      case ToolCallEvent():
        return ToolCallCard(event: event);
      case FileDiffEvent():
        return FileDiffViewerCard(event: event);
      case SkillInvokedEvent():
        return SkillInvokedBanner(event: event);
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
              Text(
                '턴 완료 (${event.durationMs}ms · 총 토큰: ${event.usage.totalTokens})',
                style: TextStyle(
                  fontSize: 11.5,
                  color: context.mac.secondaryLabel,
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
  const _EmptyTimeline();

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
            '아직 실행된 대화가 없습니다.',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: mac.label,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '하단 입력창에서 프롬프트를 입력해 주세요.',
            style: TextStyle(fontSize: 12, color: mac.secondaryLabel),
          ),
        ],
      ),
    );
  }
}
