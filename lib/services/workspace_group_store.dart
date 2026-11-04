import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/models/agent_models.dart';
import 'json_file.dart';

/// 세션의 기본값이 되는 작업 그룹 설정
class WorkspaceGroup {
  const WorkspaceGroup({
    required this.id,
    required this.name,
    required this.folder,
    required this.backend,
    required this.model,
    required this.effort,
    this.useDefaultInstructions = true,
    this.instructions = '',
  });

  factory WorkspaceGroup.fromJson(Map<String, dynamic> json) {
    final backend = BackendType.fromId(json['backend'] as String);
    return WorkspaceGroup(
      id: json['id'] as String,
      name: json['name'] as String,
      folder: json['folder'] as String,
      backend: backend,
      model: json['model'] as String,
      effort:
          ReasoningEffort.values.asNameMap()[json['effort']] ??
          ReasoningEffort.auto,
      useDefaultInstructions: json['useDefaultInstructions'] as bool,
      instructions: json['instructions'] as String,
    );
  }

  final String id;
  final String name;
  final String folder;
  final BackendType backend;
  final String model;
  final ReasoningEffort effort;
  final bool useDefaultInstructions;
  final String instructions;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'folder': folder,
    'backend': backend.id,
    'model': model,
    'effort': effort.name,
    'useDefaultInstructions': useDefaultInstructions,
    'instructions': instructions,
  };
}

/// 앱을 다시 켠 뒤에도 이어갈 수 있도록 남기는 세션의 작업 기록
class SessionSnapshot {
  const SessionSnapshot({
    required this.id,
    required this.title,
    required this.backend,
    required this.lastTurn,
    required this.updatedAt,
    this.events = const [],
    this.conversationId,
    this.model = '',
    this.effort = ReasoningEffort.auto,
    this.workingDirectory = '',
    this.groupId,
    this.instructions = '',
    this.permissionMode,
  });

  factory SessionSnapshot.fromJson(Map<String, dynamic> json) {
    final rawEvents = json['events'];
    return SessionSnapshot(
      id: json['id'] as String,
      title: json['title'] as String,
      backend: BackendType.fromId(json['backend'] as String),
      lastTurn: json['lastTurn'] as String,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      events: rawEvents is List
          ? [
              for (final item in rawEvents)
                if (item is Map)
                  ?AgentEvent.fromJson(Map<String, dynamic>.from(item)),
            ]
          : const [],
      conversationId: json['conversationId'] as String?,
      model: (json['model'] ?? '') as String,
      effort:
          ReasoningEffort.values.asNameMap()[json['effort']] ??
          ReasoningEffort.auto,
      workingDirectory: (json['workingDirectory'] ?? '') as String,
      groupId: json['groupId'] as String?,
      instructions: (json['instructions'] ?? '') as String,
      permissionMode: _restorablePermissionMode(json['permissionMode']),
    );
  }

  /// 권한 무시는 켤 때마다 확인을 거치도록 복원하지 않습니다.
  static PermissionMode? _restorablePermissionMode(Object? name) {
    final mode = PermissionMode.values.asNameMap()[name];
    return mode == PermissionMode.bypass ? null : mode;
  }

  final String id;
  final String title;
  final BackendType backend;
  final String lastTurn;
  final DateTime updatedAt;
  final List<AgentEvent> events;
  final String? conversationId;
  final String model;
  final ReasoningEffort effort;
  final String workingDirectory;
  final String? groupId;
  final String instructions;
  final PermissionMode? permissionMode;

  String get searchableText {
    final buffer = StringBuffer()
      ..writeln(title)
      ..writeln(lastTurn);
    for (final event in events) {
      switch (event) {
        case MessageEvent():
          buffer.writeln(event.text);
        case ToolCallEvent():
          buffer.writeln(event.displayLine);
          if (event.result.isNotEmpty) buffer.writeln(event.result);
        case FileDiffEvent():
          buffer.writeln(event.diff.filePath);
        case ErrorEvent():
          buffer.writeln(event.message);
        default:
          break;
      }
    }
    return buffer.toString();
  }

  /// 저장된 이벤트가 있으면 그대로 복원하고, 요약 텍스트만 있으면 메시지 이벤트로 변환합니다.
  List<AgentEvent> restoredEvents({String? sessionId}) {
    final targetSessionId = sessionId ?? id;
    if (events.isNotEmpty) {
      return [
        for (final e in events)
          AgentEvent.fromJson({...e.toJson(), 'sessionId': targetSessionId}) ??
              e,
      ];
    }
    if (lastTurn.trim().isEmpty) return const [];
    final parsed = < ({String role, StringBuffer text}) >[];
    for (final line in lastTurn.split('\n')) {
      if (line.startsWith('사용자: ')) {
        parsed.add((
          role: 'user',
          text: StringBuffer(line.substring('사용자: '.length)),
        ));
      } else if (line.startsWith('에이전트: ')) {
        parsed.add((
          role: 'assistant',
          text: StringBuffer(line.substring('에이전트: '.length)),
        ));
      } else if (parsed.isNotEmpty) {
        parsed.last.text
          ..writeln()
          ..write(line);
      } else {
        parsed.add((role: 'assistant', text: StringBuffer(line)));
      }
    }
    return [
      for (final (i, item) in parsed.indexed)
        MessageEvent(
          id: 'restored_${id}_$i',
          sessionId: targetSessionId,
          backend: backend,
          model: model.isNotEmpty ? model : backend.defaultModel,
          timestamp: updatedAt,
          role: item.role,
          text: item.text.toString(),
        ),
    ];
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'backend': backend.id,
    'lastTurn': lastTurn,
    'updatedAt': updatedAt.toIso8601String(),
    if (events.isNotEmpty) 'events': [for (final e in events) e.toJson()],
    if (conversationId != null) 'conversationId': conversationId,
    if (model.isNotEmpty) 'model': model,
    if (effort != ReasoningEffort.auto) 'effort': effort.name,
    if (workingDirectory.isNotEmpty) 'workingDirectory': workingDirectory,
    if (groupId != null) 'groupId': groupId,
    if (instructions.isNotEmpty) 'instructions': instructions,
    if (permissionMode != null && permissionMode != PermissionMode.bypass)
      'permissionMode': permissionMode!.name,
  };
}

/// 작업 그룹과 공통 기본 지침은 [_file]에, 세션 기록은 [_historyFile]에 따로 보관합니다.
/// 기록을 쓸 때 그룹을 덮어쓰지 않으므로, 기록이 깨지거나 그룹을 모르는 다른 실행본이
/// 기록을 남겨도 그룹은 사라지지 않습니다.
// ponytail: 파일 전체를 쓰므로 여러 실행본이 그룹을 동시에 고치면 마지막 쓰기가 남습니다. 필요해지면 쓰기 전에 다시 읽어 합칩니다.
class WorkspaceGroupStore {
  WorkspaceGroupStore({File? file})
    : _file = file,
      _historyFile = file == null
          ? null
          : File('${p.withoutExtension(file.path)}_history.json') {
    if (file == null) return;
    final hasLegacyHistory = _loadGroups(file);
    _loadHistory(_historyFile!);
    // 예전 형식은 기록을 먼저 옮기는 데 성공한 뒤에만 그룹 파일에서 걷어냅니다.
    if (hasLegacyHistory && _saveHistory()) _saveGroups();
  }

  factory WorkspaceGroupStore.load() {
    final home = Platform.environment['HOME'];
    return WorkspaceGroupStore(
      file: home == null
          ? null
          : File(p.join(home, '.agent_control_center', 'workspace_groups.json')),
    );
  }

  static const _maxSnapshotsPerGroup = 10;
  static const _maxSavedSessions = 50;

  final File? _file;
  final File? _historyFile;
  final Map<String, WorkspaceGroup> _groups = {};
  final Map<String, List<SessionSnapshot>> _snapshots = {};
  final List<SessionSnapshot> _savedSessions = [];
  String _defaultInstructions = '';

  List<WorkspaceGroup> get groups => _groups.values.toList(growable: false);

  String get defaultInstructions => _defaultInstructions;

  WorkspaceGroup? groupById(String? id) => _groups[id];

  /// 기본 지침 → 그룹 지침 순으로 합칩니다. 그룹이 없으면 빈 문자열입니다.
  String instructionsFor(String? groupId) {
    final group = _groups[groupId];
    if (group == null) return '';
    return [
      if (group.useDefaultInstructions) _defaultInstructions,
      group.instructions,
    ].where((text) => text.trim().isNotEmpty).join('\n\n');
  }

  /// 최근 작업 순으로 돌려줍니다.
  List<SessionSnapshot> snapshotsFor(String groupId) =>
      List.unmodifiable(_snapshots[groupId] ?? const <SessionSnapshot>[]);

  /// 저장된 모든 세션을 키워드로 검색하고 최근 날짜순(내림차순)으로 상위 [limit]개만 돌려줍니다.
  /// [query]가 비어 있으면 전체 저장 세션을 최근 날짜순으로 상위 [limit]개만 돌려줍니다.
  List<SessionSnapshot> searchSessions([String query = '', int limit = 10]) {
    final byId = <String, SessionSnapshot>{};
    for (final list in _snapshots.values) {
      for (final s in list) {
        byId[s.id] = s;
      }
    }
    for (final s in _savedSessions) {
      final existing = byId[s.id];
      if (existing == null || !s.updatedAt.isBefore(existing.updatedAt)) {
        byId[s.id] = s;
      }
    }
    final q = query.trim().toLowerCase();
    final filtered = [
      for (final s in byId.values)
        if (q.isEmpty || s.searchableText.toLowerCase().contains(q)) s,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (filtered.length > limit) {
      return List.unmodifiable(filtered.sublist(0, limit));
    }
    return List.unmodifiable(filtered);
  }

  void _upsertSavedSession(SessionSnapshot snapshot) {
    _savedSessions
      ..removeWhere((s) => s.id == snapshot.id)
      ..add(snapshot)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (_savedSessions.length > _maxSavedSessions) {
      _savedSessions.removeRange(_maxSavedSessions, _savedSessions.length);
    }
  }

  void upsert(WorkspaceGroup group, {String? defaultInstructions}) {
    _groups[group.id] = group;
    _defaultInstructions = defaultInstructions ?? _defaultInstructions;
    _saveGroups();
  }

  void remove(String groupId) {
    _groups.remove(groupId);
    _snapshots.remove(groupId);
    _saveGroups();
    _saveHistory();
  }

  void recordSnapshot(String groupId, SessionSnapshot snapshot) {
    if (!_groups.containsKey(groupId)) return;
    final list = _snapshots.putIfAbsent(groupId, () => [])
      ..removeWhere((s) => s.id == snapshot.id)
      ..insert(0, snapshot);
    if (list.length > _maxSnapshotsPerGroup) list.removeLast();
    _upsertSavedSession(snapshot);
    _saveHistory();
  }

  /// 그룹 여부와 무관하게 세션 내용과 메타데이터를 저장합니다.
  void recordSession(SessionSnapshot snapshot) {
    _upsertSavedSession(snapshot);
    final groupId = snapshot.groupId;
    if (groupId != null && _groups.containsKey(groupId)) {
      final list = _snapshots.putIfAbsent(groupId, () => [])
        ..removeWhere((s) => s.id == snapshot.id)
        ..insert(0, snapshot);
      if (list.length > _maxSnapshotsPerGroup) list.removeLast();
    }
    _saveHistory();
  }

  void removeSnapshot(String snapshotId) {
    for (final list in _snapshots.values) {
      list.removeWhere((s) => s.id == snapshotId);
    }
    _savedSessions.removeWhere((s) => s.id == snapshotId);
    _saveHistory();
  }

  /// 예전 형식처럼 기록이 함께 들어 있으면 true를 돌려줍니다.
  bool _loadGroups(File file) {
    if (!file.existsSync()) return false;
    try {
      final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      _defaultInstructions = saved['defaultInstructions'] as String;
      var hasLegacyHistory = saved.containsKey('sessions');
      for (final item in saved['groups'] as List) {
        final json = item as Map<String, dynamic>;
        final group = WorkspaceGroup.fromJson(json);
        _groups[group.id] = group;
        if (json.containsKey('snapshots')) {
          hasLegacyHistory = true;
          _addGroupSnapshots(group.id, json['snapshots']);
        }
      }
      _addSavedSessions(saved['sessions']);
      return hasLegacyHistory;
    } on Exception catch (_) {
      _discardCorrupt(file);
    } on TypeError catch (_) {
      _discardCorrupt(file);
    }
    _groups.clear();
    _snapshots.clear();
    _savedSessions.clear();
    _defaultInstructions = '';
    return false;
  }

  void _loadHistory(File file) {
    if (!file.existsSync()) return;
    try {
      final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final byGroup = saved['groupSnapshots'];
      if (byGroup is Map) {
        byGroup.forEach((groupId, snapshots) {
          if (_groups.containsKey(groupId)) {
            _addGroupSnapshots(groupId as String, snapshots);
          }
        });
      }
      _addSavedSessions(saved['sessions']);
    } on Exception catch (_) {
      _discardCorrupt(file);
    } on TypeError catch (_) {
      _discardCorrupt(file);
    }
  }

  void _addGroupSnapshots(String groupId, Object? raw) {
    final snapshots = _parseSnapshots(raw);
    _snapshots[groupId] = snapshots;
    snapshots.forEach(_upsertSavedSession);
  }

  void _addSavedSessions(Object? raw) =>
      _parseSnapshots(raw).forEach(_upsertSavedSession);

  /// 읽을 수 없는 기록 하나 때문에 나머지를 잃지 않도록 항목별로 건너뜁니다.
  static List<SessionSnapshot> _parseSnapshots(Object? raw) => [
    if (raw is List)
      for (final item in raw)
        if (item is Map) ?_parseSnapshot(item),
  ];

  static SessionSnapshot? _parseSnapshot(Map raw) {
    try {
      return SessionSnapshot.fromJson(Map<String, dynamic>.from(raw));
    } on Exception catch (_) {
      return null;
    } on TypeError catch (_) {
      return null;
    }
  }

  /// 손상된 파일은 다음 저장에 덮이지 않도록 옆으로 옮겨 둡니다.
  static void _discardCorrupt(File file) {
    try {
      file.renameSync('${file.path}.corrupt');
    } on FileSystemException catch (_) {
      // 옮기지 못해도 이번 실행은 빈 상태로 계속합니다.
    }
  }

  void _saveGroups() {
    final file = _file;
    if (file == null) return;
    try {
      writeJsonAtomically(file, {
        'defaultInstructions': _defaultInstructions,
        'groups': [for (final group in _groups.values) group.toJson()],
      });
    } on FileSystemException catch (_) {
      // 저장에 실패해도 이번 실행의 그룹 변경은 막지 않습니다.
    }
  }

  bool _saveHistory() {
    final file = _historyFile;
    if (file == null) return false;
    try {
      writeJsonAtomically(file, {
        'groupSnapshots': {
          for (final groupId in _groups.keys)
            groupId: [for (final s in snapshotsFor(groupId)) s.toJson()],
        },
        'sessions': [for (final s in _savedSessions) s.toJson()],
      });
      return true;
    } on FileSystemException catch (_) {
      return false;
    }
  }
}
