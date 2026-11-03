import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/backend/agent_backend.dart';
import '../core/backend/backend_registry.dart';
import '../core/models/agent_models.dart';
import 'agent_orchestrator.dart';
import 'permission_center.dart';
import 'skill_registry.dart';
import 'trusted_folder_store.dart';

enum SessionStatus {
  idle('대기'),
  running('실행 중'),
  awaitingApproval('승인 대기'),
  completed('완료'),
  failed('실패'),
  stopped('중지됨');

  const SessionStatus(this.label);
  final String label;
}

typedef WorktreeAllocator = Future<String> Function(
  String baseRepoDir,
  String sessionId,
);

typedef WorktreeLinkResolver = Future<WorktreeLink?> Function(
  String baseDir,
  String worktreePath,
);

/// 세션이 작업한 브랜치와 병합 대상 브랜치의 연결 기록
class WorktreeLink {
  const WorktreeLink({
    required this.baseBranch,
    required this.branch,
    required this.worktreeRoot,
    required this.startCommit,
    this.mergeCommit,
  });

  final String baseBranch;
  final String branch;
  final String worktreeRoot;
  final String startCommit;
  final String? mergeCommit;

  bool get isMerged => mergeCommit != null;

  WorktreeLink merged(String commit) => WorktreeLink(
    baseBranch: baseBranch,
    branch: branch,
    worktreeRoot: worktreeRoot,
    startCommit: startCommit,
    mergeCommit: commit,
  );
}

class ManagedSession {
  ManagedSession({
    required this.sessionId,
    required this.title,
    required this.backendType,
    required this.model,
    required this.workingDirectory,
    required this.backend,
    this.status = SessionStatus.idle,
    this.isStarted = false,
    this.hasDirectoryConflict = false,
    this.isolatedWorktreePath,
    this.lastPrompt = '',
    this.lastAttachments = const [],
    this.usage = const TokenUsage(),
    List<AgentEvent>? events,
    List<String>? rawLogs,
  }) : events = events ?? [],
       rawLogs = rawLogs ?? [];

  final String sessionId;
  String title;
  BackendType backendType;
  String model;
  String workingDirectory;
  AgentBackend backend;
  SessionStatus status;
  bool isStarted;
  String? conversationIdToResume;
  bool hasDirectoryConflict;
  String? isolatedWorktreePath;
  String lastPrompt;
  List<String> lastAttachments;
  TokenUsage usage;
  final List<AgentEvent> events;
  final List<String> rawLogs;
  final Set<String> resolvedRequestIds = {};
  final List<WorktreeLink> worktreeLinks = [];

  /// 현재 작업 중이며 아직 병합되지 않은 worktree 연결
  WorktreeLink? get activeWorktreeLink =>
      isolatedWorktreePath != null &&
          worktreeLinks.isNotEmpty &&
          !worktreeLinks.last.isMerged
      ? worktreeLinks.last
      : null;

  StreamSubscription<AgentEvent>? eventSub;
  StreamSubscription<String>? logSub;

  String get effectiveDirectory => isolatedWorktreePath ?? workingDirectory;
}

/// 다중 에이전트 세션을 병렬로 관리하고 충돌 감지, git worktree 격리,
/// 백엔드별 토큰/비용 집계를 수행합니다.
class SessionManager extends ChangeNotifier {
  SessionManager({
    BackendRegistry? registry,
    PermissionCenter? permissionCenter,
    SkillRegistry? skillRegistry,
    AgentOrchestrator? orchestrator,
    WorktreeAllocator? worktreeAllocator,
    this.trustedFolders,
    this.autoIsolateWithWorktree = false,
    this.onFolderTrustRequired,
    this.autoOrchestrateByAntigravity = true,
    this.onApprovalRequired,
    this.onQuestionRequired,
    this.onSessionFinished,
  }) : _registry = registry ?? BackendRegistry(),
       _permissionCenter = permissionCenter ?? PermissionCenter(),
       _skillRegistry = skillRegistry ?? SkillRegistry(),
       _orchestrator = orchestrator ?? const AgentOrchestrator(),
       _worktreeAllocator = worktreeAllocator ?? _defaultWorktreeAllocator,
       // 주입된 할당기의 경로는 실제 checkout이 아닐 수 있어 연결 정보를 읽지 않습니다.
       _resolveWorktreeLink = worktreeAllocator == null
           ? _defaultWorktreeLinkResolver
           : ((_, _) async => null);

  final BackendRegistry _registry;
  final PermissionCenter _permissionCenter;
  final SkillRegistry _skillRegistry;
  final AgentOrchestrator _orchestrator;
  final WorktreeAllocator _worktreeAllocator;
  final WorktreeLinkResolver _resolveWorktreeLink;

  /// null이면 폴더 신뢰 검사를 하지 않습니다.
  final TrustedFolderStore? trustedFolders;
  final bool autoIsolateWithWorktree;
  final Future<bool> Function(ManagedSession session)? onFolderTrustRequired;
  bool autoOrchestrateByAntigravity;

  final void Function(ManagedSession session, ApprovalRequestData request)?
  onApprovalRequired;
  final void Function(ManagedSession session, QuestionRequestData request)?
  onQuestionRequired;
  final void Function(ManagedSession session, bool success)? onSessionFinished;

  final Map<String, ManagedSession> _sessions = {};
  final Set<String> _mergingSessionIds = {};
  String? _activeSessionId;
  int _counter = 0;

  PermissionCenter get permissionCenter => _permissionCenter;
  BackendRegistry get registry => _registry;
  SkillRegistry get skillRegistry => _skillRegistry;
  AgentOrchestrator get orchestrator => _orchestrator;

  void setAutoOrchestration(bool enabled) {
    autoOrchestrateByAntigravity = enabled;
    notifyListeners();
  }

  List<ManagedSession> get sessions => _sessions.values.toList(growable: false);

  ManagedSession? get activeSession =>
      _activeSessionId != null ? _sessions[_activeSessionId] : null;

  String? get activeSessionId => _activeSessionId;

  Map<BackendType, TokenUsage> get usageByBackend {
    final map = <BackendType, TokenUsage>{
      for (final b in BackendType.values) b: const TokenUsage(),
    };
    for (final s in _sessions.values) {
      map[s.backendType] = (map[s.backendType] ?? const TokenUsage()) + s.usage;
    }
    return map;
  }

  void selectSession(String sessionId) {
    if (_sessions.containsKey(sessionId)) {
      _activeSessionId = sessionId;
      notifyListeners();
    }
  }

  /// 동일 디렉터리를 동시에 수정 중인 활성 세션(실행 중 / 승인 대기) 목록을 반환합니다.
  List<ManagedSession> findConflictingSessions(
    String workingDirectory, {
    String? excludeSessionId,
  }) {
    final normalized = p.normalize(p.absolute(workingDirectory));
    return _sessions.values.where((s) {
      if (s.sessionId == excludeSessionId) return false;
      final isActive =
          s.status == SessionStatus.running ||
          s.status == SessionStatus.awaitingApproval;
      if (!isActive) return false;
      final otherDir = p.normalize(p.absolute(s.effectiveDirectory));
      return otherDir == normalized;
    }).toList();
  }

  ManagedSession createSession({
    String? sessionId,
    String? title,
    BackendType backendType = BackendType.antigravity,
    String? model,
    String? workingDirectory,
    AgentBackend? backendOverride,
    List<AgentEvent>? initialEvents,
    List<String>? initialRawLogs,
    bool makeActive = true,
  }) {
    _counter++;
    final id = sessionId ?? 'session_$_counter';
    final selectedModel = model ?? backendType.defaultModel;
    final workDir = workingDirectory ?? Directory.current.path;
    final backend = backendOverride ?? _registry.create(backendType);

    final conflicts = findConflictingSessions(workDir, excludeSessionId: id);
    final session = ManagedSession(
      sessionId: id,
      title: title ?? '작업 #$_counter (${backendType.displayName})',
      backendType: backendType,
      model: selectedModel,
      workingDirectory: workDir,
      backend: backend,
      hasDirectoryConflict: conflicts.isNotEmpty,
      events: initialEvents != null ? List.of(initialEvents) : null,
      rawLogs: initialRawLogs != null ? List.of(initialRawLogs) : null,
    );

    _bindSessionStreams(session);
    _sessions[id] = session;
    if (makeActive || _activeSessionId == null) {
      _activeSessionId = id;
    }
    notifyListeners();
    return session;
  }

  void _bindSessionStreams(ManagedSession session) {
    session.eventSub?.cancel();
    session.logSub?.cancel();

    session.eventSub = session.backend.events.listen((event) {
      if (event is ApprovalRequestEvent) {
        final preApproved = _permissionCenter.checkPreApproved(event.request);
        if (preApproved != null) {
          session.resolvedRequestIds.add(event.request.id);
          session.backend.respondToApproval(preApproved);
        } else {
          session.status = SessionStatus.awaitingApproval;
          onApprovalRequired?.call(session, event.request);
        }
      } else if (event is QuestionEvent) {
        session.status = SessionStatus.awaitingApproval;
        onQuestionRequired?.call(session, event.request);
      } else if (event is DoneEvent) {
        session.usage = session.usage + event.usage;
        session.status = SessionStatus.completed;
        _refreshAllConflictFlags();
        unawaited(_detectMergeByAgent(session));
        onSessionFinished?.call(session, true);
      } else if (event is ErrorEvent) {
        session.status = SessionStatus.failed;
        _refreshAllConflictFlags();
        onSessionFinished?.call(session, false);
      }

      _mergeOrAppendEvent(session, event);
      notifyListeners();
    });

    session.logSub = session.backend.rawLogs.listen((line) {
      session.rawLogs.add(line);
      notifyListeners();
    });
  }

  void _mergeOrAppendEvent(ManagedSession session, AgentEvent incoming) {
    if (incoming is MessageEvent && incoming.isDelta) {
      final idx = session.events.lastIndexWhere(
        (e) => e is MessageEvent && e.id == incoming.id,
      );
      if (idx != -1) {
        final prev = session.events[idx] as MessageEvent;
        session.events[idx] = MessageEvent(
          id: prev.id,
          sessionId: prev.sessionId,
          backend: prev.backend,
          model: incoming.model.isNotEmpty ? incoming.model : prev.model,
          timestamp: incoming.timestamp,
          role: prev.role,
          text: prev.text + incoming.text,
          thinking: prev.thinking + incoming.thinking,
          isDelta: true,
          rawLog: incoming.rawLog,
        );
        return;
      }
    }
    if (incoming is ToolCallEvent) {
      final idx = session.events.lastIndexWhere(
        (e) => e is ToolCallEvent && e.id == incoming.id,
      );
      if (idx != -1) {
        session.events[idx] = incoming;
        return;
      }
    }
    session.events.add(incoming);
  }

  void _refreshAllConflictFlags() {
    for (final s in _sessions.values) {
      final conflicts = findConflictingSessions(
        s.effectiveDirectory,
        excludeSessionId: s.sessionId,
      );
      s.hasDirectoryConflict = conflicts.isNotEmpty;
    }
  }

  /// 동일 디렉터리 충돌 시 git worktree로 작업 디렉터리를 분리합니다.
  Future<String> isolateSessionWithWorktree(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) {
      throw StateError('세션을 찾을 수 없습니다: $sessionId');
    }
    final worktreePath = await _worktreeAllocator(
      session.workingDirectory,
      session.sessionId,
    );
    if (session.isStarted) {
      await session.backend.interrupt();
      session.isStarted = false;
      session.status = SessionStatus.stopped;
    }
    session.conversationIdToResume = null;
    session.isolatedWorktreePath = worktreePath;
    final link = await _resolveWorktreeLink(
      session.workingDirectory,
      worktreePath,
    );
    if (link != null) session.worktreeLinks.add(link);
    session.hasDirectoryConflict = false;
    _refreshAllConflictFlags();
    notifyListeners();
    return worktreePath;
  }

  /// 세션 브랜치의 변경을 커밋하고 시작 브랜치로 병합한 뒤 worktree를 정리합니다.
  Future<void> mergeSessionWorktree(String sessionId) async {
    final session = _sessions[sessionId];
    final link = session?.activeWorktreeLink;
    if (session == null || link == null) {
      throw StateError('병합할 worktree가 없습니다.');
    }
    if (session.status == SessionStatus.running ||
        session.status == SessionStatus.awaitingApproval) {
      throw StateError('실행 중인 세션은 병합할 수 없습니다.');
    }
    if (!_mergingSessionIds.add(sessionId)) return;
    try {
      final baseDir = session.workingDirectory;
      final current = await _gitOutput(baseDir, [
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      ]);
      if (current != link.baseBranch) {
        throw StateError(
          '${p.basename(baseDir)} 체크아웃이 ${link.baseBranch}가 아닌 $current에 있습니다.',
        );
      }
      final dirty = await _gitOutput(link.worktreeRoot, [
        'status',
        '--porcelain',
      ]);
      if (dirty == null) {
        throw StateError('worktree 상태를 읽을 수 없습니다: ${link.worktreeRoot}');
      }
      if (dirty.isNotEmpty) {
        await _gitOrThrow(link.worktreeRoot, ['add', '-A']);
        await _gitOrThrow(link.worktreeRoot, [
          'commit',
          '-m',
          '작업 반영: ${session.title}',
        ]);
      }
      final tip = await _gitOutput(link.worktreeRoot, ['rev-parse', 'HEAD']);
      if (tip == link.startCommit) {
        throw StateError('병합할 변경 사항이 없습니다.');
      }
      final merge = await _runGit(baseDir, [
        'merge',
        '--no-ff',
        '-m',
        '병합: ${session.title} (${link.branch})',
        link.branch,
      ]);
      if (merge.exitCode != 0) {
        await _runGit(baseDir, ['merge', '--abort']);
        throw StateError('병합 실패: ${merge.stdout}${merge.stderr}'.trim());
      }
      await _completeMerge(session, link);
    } finally {
      _mergingSessionIds.remove(sessionId);
    }
  }

  /// 에이전트가 직접 병합한 경우에도 연결 고리를 표시합니다.
  Future<void> _detectMergeByAgent(ManagedSession session) async {
    final link = session.activeWorktreeLink;
    if (link == null || _mergingSessionIds.contains(session.sessionId)) return;
    final baseDir = session.workingDirectory;
    final tip = await _gitOutput(baseDir, ['rev-parse', link.branch]);
    if (tip == null || tip == link.startCommit) return;
    final isAncestor = await _runGit(baseDir, [
      'merge-base',
      '--is-ancestor',
      tip,
      link.baseBranch,
    ]);
    if (isAncestor.exitCode != 0 || session.activeWorktreeLink != link) return;
    await _completeMerge(session, link, target: link.baseBranch);
  }

  Future<void> _completeMerge(
    ManagedSession session,
    WorktreeLink link, {
    String target = 'HEAD',
  }) async {
    final baseDir = session.workingDirectory;
    final commit = await _gitOutput(baseDir, ['rev-parse', '--short', target]);
    session.worktreeLinks.last = link.merged(commit ?? link.baseBranch);
    // 미커밋 파일이 남아 제거가 거부되면 작업 손실을 막기 위해 worktree를 유지합니다.
    final removed = await _runGit(baseDir, [
      'worktree',
      'remove',
      link.worktreeRoot,
    ]);
    if (removed.exitCode == 0) {
      await _runGit(baseDir, ['branch', '-d', link.branch]);
      session.isolatedWorktreePath = null;
      session.isStarted = false;
      session.conversationIdToResume = null;
      final parent = Directory(p.dirname(link.worktreeRoot));
      if (p.basename(parent.path).startsWith('acc_worktree_')) {
        await parent.delete().then<void>((_) {}, onError: (_) {});
      }
    }
    _refreshAllConflictFlags();
    notifyListeners();
  }

  Future<void> _ensureFolderTrusted(ManagedSession session) async {
    final store = trustedFolders;
    final dir = session.workingDirectory;
    if (store == null || store.isTrusted(dir)) return;
    final allowed = await onFolderTrustRequired?.call(session) ?? false;
    if (!allowed) {
      throw StateError('신뢰하지 않은 폴더라 실행하지 않았습니다: $dir');
    }
    store.add(dir);
  }

  Future<void> sendPrompt(
    String sessionId,
    String prompt, {
    List<String> attachments = const [],
    bool isolateWithWorktree = false,
    String? systemInstructionPrefix,
  }) async {
    final session = _sessions[sessionId];
    if (session == null) return;

    session.lastPrompt = prompt;
    session.lastAttachments = List.of(attachments);
    try {
      await _ensureFolderTrusted(session);
      final shouldIsolate =
          isolateWithWorktree ||
          (autoIsolateWithWorktree &&
              !session.isStarted &&
              await _gitOutput(session.workingDirectory, [
                    'rev-parse',
                    '--verify',
                    'HEAD',
                  ]) !=
                  null);
      if (shouldIsolate && session.isolatedWorktreePath == null) {
        await isolateSessionWithWorktree(sessionId);
      } else {
        final conflicts = findConflictingSessions(
          session.effectiveDirectory,
          excludeSessionId: sessionId,
        );
        session.hasDirectoryConflict = conflicts.isNotEmpty;
      }

      if (session.title.startsWith('작업 #') && prompt.trim().isNotEmpty) {
        final shortTitle = prompt.trim().split('\n').first;
        session.title = shortTitle.length > 28
            ? '${shortTitle.substring(0, 28)}...'
            : shortTitle;
      }
      session.status = SessionStatus.running;
      _refreshAllConflictFlags();

      // 공통 스킬 라우팅 규칙 매칭 및 타임라인 표시
      final routedSkills = _skillRegistry.matchRoutedSkills(prompt);
      for (final match in routedSkills) {
        session.events.add(
          SkillInvokedEvent(
            id: 'skill_route_${DateTime.now().microsecondsSinceEpoch}_${match.skill.name}',
            sessionId: session.sessionId,
            backend: session.backendType,
            model: session.model,
            timestamp: DateTime.now(),
            skillName: match.skill.name,
            skillPath: match.skill.skillMdPath,
            reason: match.reason,
          ),
        );
      }
      notifyListeners();

      if (!session.isStarted) {
        await session.backend.start(
          AgentSessionConfig(
            sessionId: session.sessionId,
            backendType: session.backendType,
            workingDirectory: session.effectiveDirectory,
            model: session.model,
            conversationId: session.conversationIdToResume,
            systemPromptAppend: _skillRegistry.buildRoutingInstructionForPrompt(
              prompt,
            ),
          ),
        );
        session.isStarted = true;
        session.conversationIdToResume = null;
      }
      final effectivePrompt =
          (systemInstructionPrefix != null &&
              systemInstructionPrefix.trim().isNotEmpty)
          ? '$systemInstructionPrefix\n\n$prompt'
          : prompt;
      await session.backend.send(effectivePrompt, attachments: attachments);
    } catch (e) {
      session.status = SessionStatus.failed;
      session.events.add(
        ErrorEvent(
          id: 'err_${DateTime.now().microsecondsSinceEpoch}',
          sessionId: session.sessionId,
          backend: session.backendType,
          model: session.model,
          timestamp: DateTime.now(),
          message: e.toString(),
        ),
      );
      _refreshAllConflictFlags();
      notifyListeners();
    }
  }

  /// Antigravity 마스터 에이전트의 판단 하에 프롬프트를 분석하여
  /// 백그라운드/요약/일반 작업은 Antigravity가 직접 수행하고,
  /// 별도 지시 또는 구현(Claude Code)·리뷰(Codex) 작업은 서브 세션으로 오케스트레이션(위임·병렬 실행)합니다.
  Future<OrchestrationPlan> dispatchOrchestratedPrompt(
    String sessionId,
    String prompt, {
    List<String> attachments = const [],
  }) async {
    final masterSession = _sessions[sessionId];
    if (masterSession == null) {
      throw StateError('세션을 찾을 수 없습니다: $sessionId');
    }

    final shouldAutoEvaluate =
        autoOrchestrateByAntigravity &&
        masterSession.backendType == BackendType.antigravity;

    final plan = _orchestrator.evaluatePrompt(
      prompt,
      autoOrchestrate: shouldAutoEvaluate,
      manualSelectedBackend: masterSession.backendType,
      manualSelectedModel: masterSession.model,
    );

    if (!plan.isDelegated || plan.subTasks.length == 1 && !shouldAutoEvaluate) {
      await sendPrompt(sessionId, prompt, attachments: attachments);
      return plan;
    }

    // 마스터(Antigravity) 세션에 오케스트레이션 판단 및 위임 로그를 기록
    masterSession.events.add(
      MessageEvent(
        id: 'orch_${DateTime.now().microsecondsSinceEpoch}',
        sessionId: masterSession.sessionId,
        backend: BackendType.antigravity,
        model: plan.coordinatorModel,
        timestamp: DateTime.now(),
        role: 'assistant',
        text:
            '**[Antigravity 오케스트레이션 지휘]**\n'
            '- 판단 근거: ${plan.summaryRationale}\n'
            '${plan.subTasks.map((t) => '- 위임 대상: **${t.targetBackend.displayName}** (`${t.targetModel}`) — ${t.role.label}').join('\n')}',
      ),
    );
    notifyListeners();

    // 각 서브태스크별로 전용 백엔드(Claude Code / Codex) 세션을 생성하여 병렬 실행
    for (var i = 0; i < plan.subTasks.length; i++) {
      final subTask = plan.subTasks[i];
      final delegatedSession = createSession(
        title: subTask.title,
        backendType: subTask.targetBackend,
        model: subTask.targetModel,
        workingDirectory: masterSession.workingDirectory,
        makeActive: i == 0,
      );
      await sendPrompt(
        delegatedSession.sessionId,
        subTask.prompt,
        attachments: attachments,
        isolateWithWorktree: i > 0, // 복수 에이전트 동시 수정 충돌 방지용 자동 worktree 격리
      );
    }

    return plan;
  }

  /// 스킬 관리 화면에서 특정 스킬을 지정하여 즉시 호출합니다.
  Future<void> invokeSkill(
    String sessionId,
    SkillDefinition skill,
    String taskPrompt,
  ) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    await sendPrompt(
      sessionId,
      '[스킬 호출: ${skill.name}] $taskPrompt',
      systemInstructionPrefix:
          '반드시 `${skill.name}` 스킬(${skill.skillMdPath})의 지침을 읽고 수행하세요.',
    );
  }

  Future<void> respondToApproval(
    String sessionId,
    ApprovalRequestData request,
    ApprovalDecision rawDecision,
  ) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    final finalDecision = _permissionCenter.recordDecision(request, rawDecision);
    session.resolvedRequestIds.add(request.id);
    if (session.status == SessionStatus.awaitingApproval) {
      session.status = SessionStatus.running;
    }
    await session.backend.respondToApproval(finalDecision);
    notifyListeners();
  }

  Future<void> respondToQuestion(
    String sessionId,
    String requestId,
    Map<String, List<String>> answers,
  ) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.resolvedRequestIds.add(requestId);
    if (session.status == SessionStatus.awaitingApproval) {
      session.status = SessionStatus.running;
    }
    await session.backend.respondToQuestion(requestId, answers);
    notifyListeners();
  }

  Future<void> stopSession(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    await session.backend.interrupt();
    session.status = SessionStatus.stopped;
    _refreshAllConflictFlags();
    notifyListeners();
  }

  Future<void> retrySession(String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null || session.lastPrompt.isEmpty) return;
    await sendPrompt(
      sessionId,
      session.lastPrompt,
      attachments: session.lastAttachments,
    );
  }

  /// 작업을 다른 백엔드로 재실행합니다 (새 세션 생성 후 동일 프롬프트 실행).
  Future<ManagedSession?> rerunWithBackend(
    String sessionId,
    BackendType targetBackend, {
    String? targetModel,
    bool isolateWithWorktree = false,
  }) async {
    final source = _sessions[sessionId];
    if (source == null) return null;
    final newSession = createSession(
      title: '${source.title} (${targetBackend.displayName})',
      backendType: targetBackend,
      model: targetModel ?? targetBackend.defaultModel,
      workingDirectory: source.workingDirectory,
      makeActive: true,
    );
    if (source.lastPrompt.isNotEmpty) {
      await sendPrompt(
        newSession.sessionId,
        source.lastPrompt,
        attachments: source.lastAttachments,
        isolateWithWorktree: isolateWithWorktree,
      );
    }
    return newSession;
  }

  void updateSessionBackend(
    String sessionId,
    BackendType backendType, {
    String? model,
    bool replaceAdapter = true,
  }) {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.conversationIdToResume = null;
    session.backendType = backendType;
    session.model = model ?? backendType.defaultModel;
    if (replaceAdapter) {
      session.eventSub?.cancel();
      session.logSub?.cancel();
      session.backend.dispose();
      session.backend = _registry.create(backendType);
      session.isStarted = false;
      _bindSessionStreams(session);
    }
    notifyListeners();
  }

  void updateSessionModel(String sessionId, String model) {
    final session = _sessions[sessionId];
    if (session == null || session.model == model) return;
    session.conversationIdToResume ??= session.backend.remoteConversationId;
    session.isStarted = false;
    session.model = model;
    notifyListeners();
  }

  void updateSessionWorkingDirectory(String sessionId, String dir) {
    final session = _sessions[sessionId];
    if (session == null) return;
    session.isStarted = false;
    session.conversationIdToResume = null;
    session.workingDirectory = dir;
    session.isolatedWorktreePath = null;
    _refreshAllConflictFlags();
    notifyListeners();
  }

  static Future<ProcessResult> _runGit(String dir, List<String> args) =>
      Process.run('git', args, workingDirectory: dir);

  static Future<void> _gitOrThrow(String dir, List<String> args) async {
    final result = await _runGit(dir, args);
    if (result.exitCode != 0) {
      throw StateError('git ${args.first} 실패: ${result.stderr}'.trim());
    }
  }

  /// 명령 실패나 사라진 디렉터리는 null로 돌려줍니다.
  static Future<String?> _gitOutput(String dir, List<String> args) async {
    try {
      final result = await _runGit(dir, args);
      return result.exitCode == 0 ? result.stdout.toString().trim() : null;
    } on ProcessException catch (_) {
      return null;
    }
  }

  static Future<WorktreeLink?> _defaultWorktreeLinkResolver(
    String baseDir,
    String worktreePath,
  ) async {
    final base = await _gitOutput(baseDir, [
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ]);
    final branch = await _gitOutput(worktreePath, [
      'rev-parse',
      '--abbrev-ref',
      'HEAD',
    ]);
    final root = await _gitOutput(worktreePath, [
      'rev-parse',
      '--show-toplevel',
    ]);
    final start = await _gitOutput(worktreePath, ['rev-parse', 'HEAD']);
    if (base == null ||
        base == 'HEAD' ||
        branch == null ||
        root == null ||
        start == null) {
      return null;
    }
    return WorktreeLink(
      baseBranch: base,
      branch: branch,
      worktreeRoot: root,
      startCommit: start,
    );
  }

  static Future<String> _defaultWorktreeAllocator(
    String baseRepoDir,
    String sessionId,
  ) async {
    final sanitized = sessionId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final prefix = await Process.run('git', [
      'rev-parse',
      '--show-prefix',
    ], workingDirectory: baseRepoDir);
    if (prefix.exitCode != 0) {
      throw StateError('Git 저장소 확인 실패: ${prefix.stderr}');
    }
    final parent = await Directory.systemTemp.createTemp(
      'acc_worktree_${sanitized}_',
    );
    final worktreeDir = p.join(parent.path, 'checkout');
    final branchName = 'acc/${p.basename(parent.path)}';
    final result = await Process.run('git', [
      'worktree',
      'add',
      '-b',
      branchName,
      worktreeDir,
    ], workingDirectory: baseRepoDir);
    if (result.exitCode != 0) {
      throw StateError('Git worktree 생성 실패: ${result.stderr}');
    }
    return p.join(worktreeDir, prefix.stdout.toString().trim());
  }

  @override
  void dispose() {
    for (final s in _sessions.values) {
      s.eventSub?.cancel();
      s.logSub?.cancel();
      s.backend.dispose();
    }
    super.dispose();
  }
}
