import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/backend/agent_backend.dart';
import '../core/backend/backend_registry.dart';
import '../core/models/agent_models.dart';
import 'agent_orchestrator.dart';
import 'effort_preference_store.dart';
import 'model_preference_store.dart';
import 'permission_center.dart';
import 'session_context.dart';
import 'skill_registry.dart';
import 'trusted_folder_store.dart';
import 'workspace_group_store.dart';

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
    this.effort = ReasoningEffort.auto,
    this.groupId,
    this.parentSessionId,
    this.instructions = '',
    this.autoTitle = false,
    this.permissionMode = PermissionMode.manual,
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
       rawLogs = rawLogs ?? [],
       createdAt = DateTime.now();

  final String sessionId;
  String title;
  BackendType backendType;
  String model;
  ReasoningEffort effort;
  String workingDirectory;
  AgentBackend backend;
  final DateTime createdAt;
  String? groupId;
  String? parentSessionId;

  PermissionMode permissionMode;

  /// 사용자가 이름을 정하지 않아 첫 대화로 이름을 지어야 하면 true입니다.
  bool autoTitle;

  /// 그룹 지침에 더해지는 세션별 지침
  String instructions;

  /// 이전·상위 세션에서 압축해 가져온 컨텍스트
  String handoffContext = '';
  Future<void>? handoffReady;
  SessionStatus status;
  bool isStarted;
  String? conversationIdToResume;
  bool hasDirectoryConflict;
  String? isolatedWorktreePath;
  String lastPrompt;
  List<String> lastAttachments;
  DateTime? turnStartedAt;
  int turnEventStart = 0;
  TokenUsage usage;
  final List<AgentEvent> events;
  final List<String> rawLogs;
  final Set<String> resolvedRequestIds = {};
  final List<WorktreeLink> worktreeLinks = [];
  List<SessionSnapshot> lastSearchResults = const [];

  /// 현재 작업 중이며 아직 병합되지 않은 worktree 연결
  WorktreeLink? get activeWorktreeLink =>
      isolatedWorktreePath != null &&
          worktreeLinks.isNotEmpty &&
          !worktreeLinks.last.isMerged
      ? worktreeLinks.last
      : null;

  StreamSubscription<AgentEvent>? eventSub;
  StreamSubscription<String>? logSub;

  /// 세션 번호는 앱을 다시 켜면 반복되므로 생성 시각을 더해 구분합니다.
  String get snapshotId => '$sessionId@${createdAt.microsecondsSinceEpoch}';

  /// 사용자가 처리해야 하는 하위 worktree 작업 수
  int get childAttentionCount => events
      .whereType<ChildWorktreeEvent>()
      .where((e) => e.needsAttention)
      .length;

  /// 화면에 표시할 모델과 강도
  String get modelLabel =>
      effort == ReasoningEffort.auto ? model : '$model · ${effort.label}';

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
    this.effortPreferences,
    this.modelPreferences,
    this.groups,
    this.useHelperAgent = false,
    this.defaultPermissionMode = PermissionMode.manual,
    this.onChildWorktreeFinished,
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
           : ((_, _) async => null),
       _historyStore = groups ?? WorkspaceGroupStore();

  final BackendRegistry _registry;
  final PermissionCenter _permissionCenter;
  final SkillRegistry _skillRegistry;
  final AgentOrchestrator _orchestrator;
  final WorktreeAllocator _worktreeAllocator;
  final WorktreeLinkResolver _resolveWorktreeLink;
  final WorkspaceGroupStore _historyStore;

  /// null이면 폴더 신뢰 검사를 하지 않습니다.
  final TrustedFolderStore? trustedFolders;

  /// null이면 고른 추론 강도를 기억하지 않습니다.
  final EffortPreferenceStore? effortPreferences;

  final ModelPreferenceStore? modelPreferences;

  /// null이면 작업 그룹을 쓰지 않습니다.
  final WorkspaceGroupStore? groups;

  /// 기록 압축과 이름 짓기에 일회용 백엔드를 씁니다. 끄면 잘라낸 기록과 프롬프트 첫 줄을 씁니다.
  final bool useHelperAgent;

  /// 부모 세션이 없는 새 세션의 권한 모드
  PermissionMode defaultPermissionMode;
  final void Function(
    ManagedSession parent,
    ManagedSession child,
    String message,
  )?
  onChildWorktreeFinished;
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
  final Set<String> _namingSessionIds = {};
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
    ReasoningEffort? effort,
    String? workingDirectory,
    AgentBackend? backendOverride,
    List<AgentEvent>? initialEvents,
    List<String>? initialRawLogs,
    bool makeActive = true,
    String? groupId,
    String? parentSessionId,
    String instructions = '',
    String handoffTranscript = '',
    String handoffLabel = '',
    PermissionMode? permissionMode,
  }) {
    _counter++;
    final id = sessionId ?? 'session_$_counter';
    final requestedModel =
        model ??
        modelPreferences?.modelFor(backendType) ??
        backendType.defaultModel;
    final selectedModel = backendType.baseModel(requestedModel);
    final workDir = workingDirectory ?? Directory.current.path;
    final backend = backendOverride ?? _registry.create(backendType);

    final conflicts = findConflictingSessions(workDir, excludeSessionId: id);
    final session = ManagedSession(
      sessionId: id,
      title: title ?? '작업 #$_counter (${backendType.displayName})',
      backendType: backendType,
      model: selectedModel,
      effort: backendType.resolveEffort(
        effort ??
            effortPreferences?.effortFor(backendType) ??
            ReasoningEffort.auto,
        requestedModel,
      ),
      workingDirectory: workDir,
      backend: backend,
      groupId: groupId,
      parentSessionId: parentSessionId,
      instructions: instructions,
      autoTitle: title == null,
      permissionMode: permissionMode ?? defaultPermissionMode,
      hasDirectoryConflict: conflicts.isNotEmpty,
      events: initialEvents != null ? List.of(initialEvents) : null,
      rawLogs: initialRawLogs != null ? List.of(initialRawLogs) : null,
    );

    _bindSessionStreams(session);
    _sessions[id] = session;
    if (makeActive || _activeSessionId == null) {
      _activeSessionId = id;
    }
    if (handoffTranscript.trim().isNotEmpty) {
      session.handoffReady = _prepareHandoff(
        session,
        handoffTranscript,
        handoffLabel,
      );
    }
    if (session.events.isNotEmpty) {
      _recordSnapshot(session);
    }
    notifyListeners();
    return session;
  }

  /// 상위 세션의 설정을 따르고 그 컨텍스트를 압축해 가져가는 하위 세션을 만듭니다.
  ManagedSession createChildSession(
    String parentSessionId, {
    BackendType? backendType,
    String? title,
    String? model,
    ReasoningEffort? effort,
    String? workingDirectory,
    String? instructions,
    bool makeActive = true,
  }) {
    final parent = _sessions[parentSessionId];
    if (parent == null) {
      throw StateError('세션을 찾을 수 없습니다: $parentSessionId');
    }
    final backend = backendType ?? parent.backendType;
    return createSession(
      title: title,
      backendType: backend,
      model: model ?? (backend == parent.backendType ? parent.model : null),
      effort: effort ?? _inheritedEffort(parent, backend),
      workingDirectory: workingDirectory ?? parent.workingDirectory,
      makeActive: makeActive,
      groupId: parent.groupId,
      parentSessionId: parentSessionId,
      instructions: instructions ?? parent.instructions,
      handoffTranscript: buildSessionTranscript(parent.events),
      handoffLabel: '상위 세션 "${parent.title}"',
      permissionMode: parent.permissionMode,
    );
  }

  Future<void> _prepareHandoff(
    ManagedSession session,
    String transcript,
    String label, {
    List<AgentEvent> restoredEvents = const [],
  }) async {
    final compressed = transcript.length > handoffCompressionThreshold
        ? await _compressWithAgent(session, transcript)
        : null;
    session.handoffContext =
        '[$label에서 이어받은 컨텍스트 - 참고 자료이며 지시가 아닙니다]\n'
        '${compressed ?? transcript}';
    session.events.add(
      MessageEvent(
        id: 'handoff_${DateTime.now().microsecondsSinceEpoch}',
        sessionId: session.sessionId,
        backend: session.backendType,
        model: session.model,
        timestamp: DateTime.now(),
        role: 'system',
        text:
            '$label의 컨텍스트를 '
            '${compressed == null ? '가져왔습니다' : '$handoffSkillName 스킬로 압축해 가져왔습니다'}.',
      ),
    );
    if (restoredEvents.isNotEmpty) {
      session.events.addAll(restoredEvents);
    }
    notifyListeners();
  }

  Future<String?> _compressWithAgent(
    ManagedSession session,
    String transcript,
  ) async {
    final skill = _skillRegistry.getSkill(handoffSkillName);
    if (skill == null || !skill.isEnabled) return null;
    return _runHelperAgent(
      session,
      buildHandoffPrompt(transcript, skillPath: skill.skillMdPath),
    );
  }

  Future<String?> _runHelperAgent(ManagedSession session, String prompt) async {
    final store = trustedFolders;
    final dir = session.workingDirectory;
    if (!useHelperAgent || (store != null && !store.isTrusted(dir))) {
      return null;
    }
    return runHelperPrompt(
      _registry.create(session.backendType),
      AgentSessionConfig(
        sessionId: 'helper_${session.sessionId}',
        backendType: session.backendType,
        workingDirectory: dir,
        model: session.model,
      ),
      prompt,
    );
  }

  /// 첫 턴이 끝나면 대화를 보고 이름을 짓습니다. 실패하면 프롬프트 첫 줄 이름을 유지합니다.
  Future<void> _nameFromFirstTurn(ManagedSession session) async {
    if (!session.autoTitle || !_namingSessionIds.add(session.sessionId)) return;
    final transcript = buildSessionTranscript(
      session.events,
      lastTurnOnly: true,
      maxChars: 2000,
    );
    final reply = transcript.isEmpty
        ? null
        : await _runHelperAgent(session, buildSessionTitlePrompt(transcript));
    _namingSessionIds.remove(session.sessionId);
    // 기다리는 동안 사용자가 이름을 정했거나 세션을 지웠으면 건드리지 않습니다.
    if (!session.autoTitle || _sessions[session.sessionId] != session) return;
    session.autoTitle = false;
    final title = reply == null ? null : cleanSessionTitle(reply);
    if (title == null) return;
    session.title = title;
    // worktree를 하위 세션에 맡긴 상위 세션은 직접 턴을 돌리지 않아 같은 이름을 받습니다.
    final parent = _sessions[session.parentSessionId];
    if (parent != null && parent.autoTitle) {
      parent.autoTitle = false;
      parent.title = title;
    }
    _recordSnapshot(session);
    notifyListeners();
  }

  /// 스냅샷의 작업 내용과 컨텍스트를 이어받습니다.
  void continueFromSnapshot(String sessionId, SessionSnapshot snapshot) {
    final session = _sessions[sessionId];
    if (session == null) return;
    if (snapshot.conversationId != null &&
        snapshot.backend == session.backendType) {
      session.conversationIdToResume ??= snapshot.conversationId;
    }
    final transcript = snapshot.events.isNotEmpty
        ? buildSessionTranscript(snapshot.events)
        : snapshot.lastTurn;
    session.handoffReady = _prepareHandoff(
      session,
      transcript,
      '이전 세션 "${snapshot.title}"',
      restoredEvents: snapshot.restoredEvents(sessionId: session.sessionId),
    );
  }

  /// 저장된 세션 스냅샷의 대화 내용과 컨텍스트를 현재 세션으로 불러옵니다.
  Future<void> loadSnapshot(String sessionId, SessionSnapshot snapshot) async {
    final session = _sessions[sessionId];
    if (session == null) return;
    if (session.autoTitle || session.title.startsWith('작업 #')) {
      session.title = snapshot.title;
      session.autoTitle = false;
    }
    session.events.clear();
    session.lastSearchResults = const [];
    session.conversationIdToResume = snapshot.backend == session.backendType
        ? snapshot.conversationId
        : null;
    session.isStarted = false;
    continueFromSnapshot(sessionId, snapshot);
    await session.handoffReady;
    _recordSnapshot(session);
    notifyListeners();
  }

  /// 저장된 기록을 새 세션으로 옮겨, 같은 작업이 목록에 두 번 남지 않게 합니다.
  Future<void> reopenSnapshot(String sessionId, SessionSnapshot snapshot) async {
    await loadSnapshot(sessionId, snapshot);
    _historyStore.removeSnapshot(snapshot.id);
    notifyListeners();
  }

  /// 저장된 세션을 키워드로 검색합니다. 키워드가 비어 있으면 최근 날짜순으로 상위 [limit]개(기본 10개)를 반환합니다.
  List<SessionSnapshot> searchSavedSessions([
    String query = '',
    int limit = 10,
  ]) => _historyStore.searchSessions(query, limit);

  void recordSessionSnapshot(SessionSnapshot snapshot) =>
      _historyStore.recordSession(snapshot);

  void saveGroup(WorkspaceGroup group, {String? defaultInstructions}) {
    final store = groups;
    if (store == null) return;
    final globalChanged =
        defaultInstructions != null &&
        defaultInstructions != store.defaultInstructions;
    store.upsert(group, defaultInstructions: defaultInstructions);
    for (final session in _sessions.values) {
      if (globalChanged || session.groupId == group.id) {
        _restartOnNextPrompt(session);
      }
      // ponytail: 실행 중이거나 미병합 worktree가 있는 세션은 기존 폴더에 남습니다. 함께 옮겨야 하면 병합 후 재적용합니다.
      if (session.groupId == group.id && _canChangeDirectory(session)) {
        _moveToDirectory(session, group.folder);
      }
    }
    notifyListeners();
  }

  bool _canChangeDirectory(ManagedSession session) =>
      session.status != SessionStatus.running &&
      session.status != SessionStatus.awaitingApproval &&
      session.activeWorktreeLink == null;

  List<ManagedSession> _withDescendants(ManagedSession root) {
    final result = [root];
    for (var i = 0; i < result.length; i++) {
      result.addAll(
        _sessions.values.where(
          (s) => s.parentSessionId == result[i].sessionId,
        ),
      );
    }
    return result;
  }

  /// 자신의 하위 세션 옆으로는 옮길 수 없고, 폴더를 바꿀 수 없는 세션은 폴더가 다른 그룹으로 옮길 수 없습니다.
  bool canMoveSession(String sessionId, String? groupId, {String? targetId}) {
    final session = _sessions[sessionId];
    if (session == null) return false;
    final moving = _withDescendants(session);
    if (moving.any((s) => s.sessionId == targetId)) return false;
    if (groupId == null) return true;
    final folder = groups?.groupById(groupId)?.folder;
    if (folder == null) return false;
    return moving.every(
      (s) =>
          s.groupId == groupId ||
          s.workingDirectory == folder ||
          _canChangeDirectory(s),
    );
  }

  /// 세션을 하위 세션과 함께 [groupId]로 옮깁니다. [targetId]가 있으면 그 세션의 앞이나 뒤에
  /// 같은 상위 세션의 하위로 놓고, 없으면 그룹의 맨 끝에 놓습니다.
  void moveSession(
    String sessionId,
    String? groupId, {
    String? targetId,
    bool after = false,
  }) {
    if (!canMoveSession(sessionId, groupId, targetId: targetId)) return;
    final session = _sessions[sessionId]!;
    final target = _sessions[targetId];
    final oldParent = _sessions[session.parentSessionId];
    // 다른 그룹에 남은 상위 세션과의 관계는 유지해 작업 보고를 계속 받습니다.
    final parentId = target != null
        ? target.parentSessionId
        : (oldParent?.groupId == groupId ? null : session.parentSessionId);
    if (session.parentSessionId != parentId) {
      oldParent?.events.removeWhere(
        (e) => e is ChildWorktreeEvent && e.childSessionId == sessionId,
      );
      session.parentSessionId = parentId;
    }
    final folder = groups?.groupById(groupId)?.folder;
    for (final moved in _withDescendants(session)) {
      if (moved.groupId == groupId) continue;
      moved.groupId = groupId;
      _restartOnNextPrompt(moved);
      if (folder != null) _moveToDirectory(moved, folder);
      _recordSnapshot(moved);
    }
    final ordered = [..._sessions.values]..remove(session);
    ordered.insert(
      target == null
          ? ordered.length
          : ordered.indexOf(target) + (after ? 1 : 0),
      session,
    );
    _sessions
      ..clear()
      ..addAll({for (final s in ordered) s.sessionId: s});
    _historyStore.putFirstInOrder([for (final s in ordered) s.snapshotId]);
    notifyListeners();
  }

  void moveSavedSession(
    String snapshotId,
    String? groupId, {
    String? targetId,
    bool after = false,
  }) {
    _historyStore.moveSnapshot(
      snapshotId,
      groupId,
      targetId: targetId,
      after: after,
    );
    notifyListeners();
  }

  List<SessionSnapshot> get orderedSavedSessions =>
      _historyStore.orderedSessions();

  /// 그룹을 지워도 세션은 그룹 없는 세션으로 남습니다.
  void deleteGroup(String groupId) {
    groups?.remove(groupId);
    for (final session in _sessions.values) {
      if (session.groupId == groupId) {
        session.groupId = null;
        _restartOnNextPrompt(session);
      }
    }
    notifyListeners();
  }

  void updateSessionInstructions(String sessionId, String instructions) {
    final session = _sessions[sessionId];
    if (session == null || session.instructions == instructions) return;
    session.instructions = instructions;
    _restartOnNextPrompt(session);
    notifyListeners();
  }

  /// 지침은 시작 시 전달되므로 다음 프롬프트에서 같은 대화를 다시 시작합니다.
  void _restartOnNextPrompt(ManagedSession session) {
    session.conversationIdToResume ??= session.backend.remoteConversationId;
    session.isStarted = false;
  }

  void _recordSnapshot(ManagedSession session) {
    final lastTurn = buildSessionTranscript(session.events, lastTurnOnly: true);
    if (lastTurn.isEmpty && session.events.isEmpty) return;
    _historyStore.recordSession(
      SessionSnapshot(
        id: session.snapshotId,
        title: session.title,
        backend: session.backendType,
        lastTurn: lastTurn.isNotEmpty
            ? lastTurn
            : buildSessionTranscript(session.events),
        updatedAt: DateTime.now(),
        events: List.of(session.events),
        conversationId:
            session.backend.remoteConversationId ??
            session.conversationIdToResume,
        model: session.model,
        effort: session.effort,
        workingDirectory: session.workingDirectory,
        groupId: session.groupId ?? SessionSnapshot.noGroup,
        instructions: session.instructions,
        permissionMode: session.permissionMode,
      ),
    );
  }

  /// 턴이 끝나면 병합 여부를 확인한 뒤 스냅샷을 남기고 상위 세션에 알립니다.
  Future<void> _finishTurn(ManagedSession session) async {
    await _detectMergeByAgent(session);
    _recordSnapshot(session);
    await _reportToParent(session);
  }

  Future<void> _reportToParent(
    ManagedSession child, {
    bool notify = true,
  }) async {
    final parent = _sessions[child.parentSessionId];
    if (parent == null) return;
    final link = child.worktreeLinks.lastOrNull;
    if (link == null &&
        !parent.events.whereType<ChildWorktreeEvent>().any(
          (e) => e.childSessionId == child.sessionId,
        )) {
      return;
    }
    final reportedStatus = child.status;
    final turnEventStart = child.turnEventStart;
    final status = switch (reportedStatus) {
      SessionStatus.completed => ChildWorktreeStatus.completed,
      SessionStatus.failed => ChildWorktreeStatus.failed,
      SessionStatus.stopped => ChildWorktreeStatus.stopped,
      _ => ChildWorktreeStatus.running,
    };
    var message = link != null && link.isMerged
        ? '${link.baseBranch}에 병합되었습니다 (${link.mergeCommit}).'
        : '작업이 완료되었습니다.';
    var needsMerge = false;
    if (child.status == SessionStatus.failed) {
      message = '작업이 실패했습니다. 하위 세션을 확인해 주세요.';
    } else if (child.status == SessionStatus.stopped) {
      message = '작업이 중지되었습니다. 하위 세션에서 이어갈 수 있습니다.';
    } else if (link != null && !link.isMerged) {
      final commits = await _gitOutput(link.worktreeRoot, [
        'rev-list',
        '--count',
        '${link.startCommit}..HEAD',
      ]);
      final dirty = await _gitOutput(link.worktreeRoot, [
        'status',
        '--porcelain',
      ]);
      final fileCount = dirty == null || dirty.isEmpty
          ? 0
          : dirty.split('\n').length;
      needsMerge = commits != '0' || fileCount > 0;
      message = needsMerge
          ? '${link.baseBranch} 병합이 필요합니다 (커밋 ${commits ?? '?'}개, 미커밋 파일 $fileCount개).'
          : '변경 사항이 없습니다. 필요 없으면 하위 세션을 삭제해 주세요.';
    }
    // Git 조회 중 재시작되거나 삭제된 작업의 이전 결과는 반영하지 않습니다.
    if (_sessions[parent.sessionId] != parent ||
        _sessions[child.sessionId] != child ||
        child.status != reportedStatus ||
        child.turnEventStart != turnEventStart) {
      return;
    }
    final turnEvents = child.events.skip(turnEventStart);
    final summary =
        turnEvents
            .whereType<MessageEvent>()
            .where((e) => e.role == 'assistant' && e.text.isNotEmpty)
            .lastOrNull
            ?.text ??
        '';
    final error = turnEvents.whereType<ErrorEvent>().lastOrNull?.message;
    parent.events
      ..removeWhere(
        (e) => e is ChildWorktreeEvent && e.childSessionId == child.sessionId,
      )
      ..add(
        ChildWorktreeEvent(
          id: 'child_${child.sessionId}_${DateTime.now().microsecondsSinceEpoch}',
          sessionId: parent.sessionId,
          backend: child.backendType,
          model: child.model,
          timestamp: DateTime.now(),
          childSessionId: child.sessionId,
          childTitle: child.title,
          message: message,
          status: status,
          summary: error == null
              ? summary
              : [summary, error].where((text) => text.isNotEmpty).join('\n\n'),
          needsAttention:
              needsMerge ||
              status == ChildWorktreeStatus.failed ||
              status == ChildWorktreeStatus.stopped,
          canMerge: needsMerge,
        ),
      );
    final hasRunningChild = _sessions.values.any(
      (s) =>
          s.parentSessionId == parent.sessionId &&
          (s.status == SessionStatus.running ||
              s.status == SessionStatus.awaitingApproval),
    );
    if (!hasRunningChild &&
        parent.status != SessionStatus.running &&
        parent.status != SessionStatus.awaitingApproval) {
      parent.status = reportedStatus;
    }
    _recordSnapshot(parent);
    notifyListeners();
    if (notify) onChildWorktreeFinished?.call(parent, child, message);
  }

  /// 워크트리 작업은 하위 세션이 맡고, 상위 세션은 다음 프롬프트를 받습니다.
  Future<void> _runInWorktreeChild(
    ManagedSession parent,
    String prompt,
    List<String> attachments,
    String? systemInstructionPrefix,
  ) async {
    final child = createChildSession(parent.sessionId, makeActive: false);
    parent.status = SessionStatus.idle;
    final now = DateTime.now();
    parent.events.addAll([
      MessageEvent(
        id: 'user_${now.microsecondsSinceEpoch}',
        sessionId: parent.sessionId,
        backend: parent.backendType,
        model: parent.model,
        timestamp: now,
        role: 'user',
        text: prompt,
      ),
      ChildWorktreeEvent(
        id: 'child_${child.sessionId}_${now.microsecondsSinceEpoch}',
        sessionId: parent.sessionId,
        backend: child.backendType,
        model: child.model,
        timestamp: now,
        childSessionId: child.sessionId,
        childTitle: prompt.trim().split('\n').first,
        message: '하위 세션의 worktree에서 작업을 시작했습니다.',
      ),
    ]);
    notifyListeners();
    await sendPrompt(
      child.sessionId,
      prompt,
      attachments: attachments,
      isolateWithWorktree: true,
      systemInstructionPrefix: systemInstructionPrefix,
    );
  }

  void _bindSessionStreams(ManagedSession session) {
    session.eventSub?.cancel();
    session.logSub?.cancel();

    session.eventSub = session.backend.events.listen((event) {
      if (event is ApprovalRequestEvent) {
        final preApproved = _permissionCenter.checkPreApproved(event.request);
        if (preApproved == null &&
            _canApproveAutomatically(session.permissionMode, event.request)) {
          _approveAutomatically(session, event.request);
          return;
        }
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
        unawaited(_finishTurn(session));
        unawaited(_nameFromFirstTurn(session));
        onSessionFinished?.call(session, true);
      } else if (event is ErrorEvent) {
        session.status = SessionStatus.failed;
        _refreshAllConflictFlags();
        unawaited(_finishTurn(session));
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

  static const _fileReadTools = {
    'Read',
    'Glob',
    'Grep',
    'view_file',
    'read_file',
    'list_dir',
  };

  static bool _canApproveAutomatically(
    PermissionMode mode,
    ApprovalRequestData req,
  ) {
    final destructive =
        req.isDestructive || req.category == ApprovalCategory.destructive;
    return switch (mode) {
      PermissionMode.bypass => true,
      PermissionMode.auto => !destructive,
      PermissionMode.acceptEdits =>
        !destructive &&
            (req.category == ApprovalCategory.fileWrite ||
                _fileReadTools.contains(req.toolName)),
      PermissionMode.manual || PermissionMode.plan => false,
    };
  }

  void updateSessionPermissionMode(String sessionId, PermissionMode mode) {
    final session = _sessions[sessionId];
    if (session == null || session.permissionMode == mode) return;
    session.permissionMode = mode;
    _restartOnNextPrompt(session);
    notifyListeners();
  }

  void _approveAutomatically(
    ManagedSession session,
    ApprovalRequestData request,
  ) {
    session.resolvedRequestIds.add(request.id);
    session.backend.respondToApproval(
      _permissionCenter.recordDecision(
        request,
        ApprovalDecision(
          requestId: request.id,
          approved: true,
          scope: ApprovalScope.once,
          reason: '${session.permissionMode.label} 모드 자동 승인',
        ),
      ),
    );
  }

  /// CLI가 처음부터 승인 없이 접근할 폴더. 세션 폴더를 신뢰할 때만 넘깁니다.
  List<String> _trustedDirectories(ManagedSession session) {
    final store = trustedFolders;
    final asksBeforeEdits =
        session.permissionMode == PermissionMode.manual ||
        session.permissionMode == PermissionMode.plan;
    if (asksBeforeEdits ||
        store == null ||
        !store.isTrusted(session.workingDirectory)) {
      return const [];
    }
    return {
      TrustedFolderStore.canonicalPath(session.effectiveDirectory),
      TrustedFolderStore.canonicalPath(session.workingDirectory),
    }.toList();
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
      await _reportToParent(session, notify: false);
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
    if (await _removeWorktree(baseDir, link)) {
      session.isolatedWorktreePath = null;
      session.isStarted = false;
      session.conversationIdToResume = null;
    }
    _refreshAllConflictFlags();
    notifyListeners();
  }

  Future<bool> _removeWorktree(String baseDir, WorktreeLink link) async {
    final removed = await _runGit(baseDir, [
      'worktree',
      'remove',
      link.worktreeRoot,
    ]);
    if (removed.exitCode != 0) return false;
    await _runGit(baseDir, ['branch', '-d', link.branch]);
    final parent = Directory(p.dirname(link.worktreeRoot));
    if (p.basename(parent.path).startsWith('acc_worktree_')) {
      await parent.delete().then<void>((_) {}, onError: (_) {});
    }
    return true;
  }

  /// 세션을 중지·제거합니다. 변경이 남은 worktree는 지우지 않고 그 경로를 돌려줍니다.
  Future<String?> deleteSession(String sessionId) async {
    final session = _sessions.remove(sessionId);
    if (session == null) return null;
    if (_activeSessionId == sessionId) {
      _activeSessionId = _sessions.keys.lastOrNull;
    }
    _historyStore.removeSnapshot(session.snapshotId);
    for (final other in _sessions.values) {
      if (other.parentSessionId == sessionId) {
        other.parentSessionId = session.parentSessionId;
      }
      other.events.removeWhere(
        (e) => e is ChildWorktreeEvent && e.childSessionId == sessionId,
      );
    }
    _refreshAllConflictFlags();
    notifyListeners();
    await session.eventSub?.cancel();
    await session.logSub?.cancel();
    await session.backend.dispose();

    final link = session.activeWorktreeLink;
    if (link == null) return null;
    final dirty = await _gitOutput(link.worktreeRoot, [
      'status',
      '--porcelain',
    ]);
    final tip = await _gitOutput(link.worktreeRoot, ['rev-parse', 'HEAD']);
    if (dirty == null || dirty.isNotEmpty || tip != link.startCommit) {
      return link.worktreeRoot;
    }
    return await _removeWorktree(session.workingDirectory, link)
        ? null
        : link.worktreeRoot;
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

  static final _loadCommandPattern = RegExp(
    r'^/(?:load|resume|불러오기|검색)(?:\s+(.*))?$',
    caseSensitive: false,
  );

  Future<void> _handleLoadCommand(
    ManagedSession session,
    String rawCommand,
    String keyword,
  ) async {
    final results = searchSavedSessions(keyword, 10);
    session.lastSearchResults = results;
    if (keyword.isNotEmpty) {
      final lower = keyword.toLowerCase();
      final exact = results
          .where(
            (s) =>
                s.id.toLowerCase() == lower || s.title.toLowerCase() == lower,
          )
          .firstOrNull;
      final target = exact ?? (results.length == 1 ? results.single : null);
      if (target != null) {
        await loadSnapshot(session.sessionId, target);
        session.lastSearchResults = results;
        notifyListeners();
        return;
      }
    }
    final now = DateTime.now();
    final lines = <String>[
      if (results.isEmpty)
        keyword.isEmpty
            ? '저장된 세션이 없습니다.'
            : '"$keyword" 키워드와 일치하는 저장된 세션이 없습니다.'
      else ...[
        keyword.isEmpty
            ? '최근 저장된 세션 목록 (상위 ${results.length}개):'
            : '"$keyword" 검색 결과 (최근 날짜순 상위 ${results.length}개):',
        for (final (i, s) in results.indexed)
          '${i + 1}. **${s.title}** (${s.backend.displayName} · ${s.updatedAt.toIso8601String().split('T').first}) — ${s.lastTurn.replaceAll('\n', ' ')}',
      ],
    ];
    session.events.addAll([
      MessageEvent(
        id: 'cmd_user_${now.microsecondsSinceEpoch}',
        sessionId: session.sessionId,
        backend: session.backendType,
        model: session.model,
        timestamp: now,
        role: 'user',
        text: rawCommand,
      ),
      MessageEvent(
        id: 'cmd_sys_${now.microsecondsSinceEpoch}',
        sessionId: session.sessionId,
        backend: session.backendType,
        model: session.model,
        timestamp: now,
        role: 'system',
        text: lines.join('\n'),
      ),
    ]);
    notifyListeners();
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

    final loadMatch = _loadCommandPattern.firstMatch(prompt.trim());
    if (loadMatch != null) {
      await _handleLoadCommand(
        session,
        prompt.trim(),
        (loadMatch.group(1) ?? '').trim(),
      );
      return;
    }

    session.lastPrompt = prompt;
    session.lastAttachments = List.of(attachments);
    session.turnEventStart = session.events.length;
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
      if (session.autoTitle &&
          session.title.startsWith('작업 #') &&
          prompt.trim().isNotEmpty) {
        final shortTitle = prompt.trim().split('\n').first;
        session.title = shortTitle.length > 28
            ? '${shortTitle.substring(0, 28)}...'
            : shortTitle;
      }
      if (shouldIsolate && session.isolatedWorktreePath == null) {
        if (!isolateWithWorktree && session.parentSessionId == null) {
          await _runInWorktreeChild(
            session,
            prompt,
            attachments,
            systemInstructionPrefix,
          );
          return;
        }
        await isolateSessionWithWorktree(sessionId);
      } else {
        final conflicts = findConflictingSessions(
          session.effectiveDirectory,
          excludeSessionId: sessionId,
        );
        session.hasDirectoryConflict = conflicts.isNotEmpty;
      }

      session.status = SessionStatus.running;
      session.turnStartedAt = DateTime.now();
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

      await session.handoffReady;
      // 컨텍스트를 압축하는 동안 사용자가 중지했을 수 있습니다.
      if (session.status != SessionStatus.running) return;
      if (!session.isStarted) {
        await session.backend.start(
          AgentSessionConfig(
            sessionId: session.sessionId,
            backendType: session.backendType,
            workingDirectory: session.effectiveDirectory,
            model: session.model,
            effort: session.effort,
            conversationId: session.conversationIdToResume,
            trustedDirectories: _trustedDirectories(session),
            permissionMode: session.permissionMode,
            // ponytail: Codex·Antigravity는 매 턴 앞에 붙으므로 긴 컨텍스트가 반복됩니다. 비용이 문제되면 첫 턴에만 붙입니다.
            systemPromptAppend: [
              _skillRegistry.buildRoutingInstructionForPrompt(prompt),
              groups?.instructionsFor(session.groupId) ?? '',
              session.instructions,
              session.handoffContext,
            ].where((text) => text.trim().isNotEmpty).join('\n\n'),
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
      await _reportToParent(session);
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
        masterSession.backendType == BackendType.antigravity &&
        !_loadCommandPattern.hasMatch(prompt.trim());

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
      final delegatedSession = createChildSession(
        sessionId,
        title: subTask.title,
        backendType: subTask.targetBackend,
        model: subTask.targetModel,
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

  /// 같은 백엔드에서만 강도를 이어받습니다. 다른 백엔드의 비용을 임의로 올리지 않기 위함입니다.
  ReasoningEffort _inheritedEffort(ManagedSession source, BackendType target) =>
      source.backendType == target
      ? source.effort
      : effortPreferences?.effortFor(target) ?? target.defaultEffort;

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
    final finalDecision = _permissionCenter.recordDecision(
      request,
      rawDecision,
    );
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
    final wasBusy =
        session.status == SessionStatus.running ||
        session.status == SessionStatus.awaitingApproval;
    await session.backend.interrupt();
    // 프로세스가 종료되었으므로 다음 프롬프트는 같은 대화를 새 프로세스로 재개합니다.
    session.conversationIdToResume ??= session.backend.remoteConversationId;
    session.isStarted = false;
    session.status = SessionStatus.stopped;
    if (wasBusy) _markTurnInterrupted(session);
    _recordSnapshot(session);
    _refreshAllConflictFlags();
    notifyListeners();
    await _reportToParent(session, notify: false);
  }

  /// 중지된 턴의 도구 카드와 대기 중인 요청이 실행 중으로 남지 않게 정리합니다.
  void _markTurnInterrupted(ManagedSession session) {
    for (final (i, event) in session.events.indexed) {
      if (event is ToolCallEvent && event.isRunning) {
        session.events[i] = event.copyWith(
          isRunning: false,
          isError: true,
          result: '중지됨',
        );
      } else if (event is ApprovalRequestEvent) {
        session.resolvedRequestIds.add(event.request.id);
      } else if (event is QuestionEvent) {
        session.resolvedRequestIds.add(event.request.id);
      }
    }
    session.events.add(
      DoneEvent(
        id: 'stop_${DateTime.now().microsecondsSinceEpoch}',
        sessionId: session.sessionId,
        backend: session.backendType,
        model: session.model,
        timestamp: DateTime.now(),
        stopReason: DoneEvent.interrupted,
      ),
    );
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
      model: targetModel,
      effort: _inheritedEffort(source, targetBackend),
      workingDirectory: source.workingDirectory,
      makeActive: true,
      groupId: source.groupId,
      parentSessionId: sessionId,
      instructions: source.instructions,
      permissionMode: source.permissionMode,
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
    final requestedModel =
        model ??
        modelPreferences?.modelFor(backendType) ??
        backendType.defaultModel;
    session.model = backendType.baseModel(requestedModel);
    if (model != null) modelPreferences?.remember(backendType, model);
    session.effort = backendType.resolveEffort(
      effortPreferences?.effortFor(backendType) ?? backendType.defaultEffort,
      requestedModel,
    );
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

  void updateSessionTitle(String sessionId, String title) {
    final session = _sessions[sessionId];
    if (session == null || session.title == title) return;
    session.title = title;
    session.autoTitle = false;
    _recordSnapshot(session);
    notifyListeners();
  }

  void updateSessionModel(String sessionId, String model) {
    final session = _sessions[sessionId];
    if (session == null) return;
    final base = session.backendType.baseModel(model);
    modelPreferences?.remember(session.backendType, base);
    if (session.model == base) return;
    session.conversationIdToResume ??= session.backend.remoteConversationId;
    session.isStarted = false;
    session.model = base;
    notifyListeners();
  }

  void updateSessionEffort(String sessionId, ReasoningEffort effort) {
    final session = _sessions[sessionId];
    if (session == null ||
        !session.backendType.supportedEfforts.contains(effort)) {
      return;
    }
    effortPreferences?.remember(session.backendType, effort);
    if (session.effort == effort) return;
    session.conversationIdToResume ??= session.backend.remoteConversationId;
    session.isStarted = false;
    session.effort = effort;
    notifyListeners();
  }

  void updateSessionWorkingDirectory(String sessionId, String dir) {
    final session = _sessions[sessionId];
    // 그룹 세션의 작업 폴더는 그룹 폴더를 따라갑니다.
    if (session == null || session.groupId != null) return;
    _moveToDirectory(session, dir);
    notifyListeners();
  }

  void _moveToDirectory(ManagedSession session, String dir) {
    if (session.workingDirectory == dir) return;
    session.isStarted = false;
    session.conversationIdToResume = null;
    session.workingDirectory = dir;
    session.isolatedWorktreePath = null;
    _refreshAllConflictFlags();
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
