import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/models/agent_models.dart';

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
    );
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
  };
}

/// 작업 그룹, 공통 기본 지침, 그룹별·전체 세션 스냅샷을 JSON 파일로 보관합니다.
class WorkspaceGroupStore {
  WorkspaceGroupStore({File? file}) : _file = file {
    final f = file;
    if (f == null || !f.existsSync()) return;
    try {
      final saved = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      _defaultInstructions = saved['defaultInstructions'] as String;
      for (final item in saved['groups'] as List) {
        final json = item as Map<String, dynamic>;
        final group = WorkspaceGroup.fromJson(json);
        _groups[group.id] = group;
        final snaps = [
          for (final s in json['snapshots'] as List)
            SessionSnapshot.fromJson(s as Map<String, dynamic>),
        ];
        _snapshots[group.id] = snaps;
        for (final s in snaps) {
          _upsertSavedSession(s);
        }
      }
      final rawSessions = saved['sessions'];
      if (rawSessions is List) {
        for (final s in rawSessions) {
          if (s is Map) {
            _upsertSavedSession(
              SessionSnapshot.fromJson(Map<String, dynamic>.from(s)),
            );
          }
        }
      }
    } on Exception catch (_) {
      // 손상된 파일은 그룹이 없는 것으로 취급합니다.
      _clear();
    } on TypeError catch (_) {
      _clear();
    }
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
    _save();
  }

  void remove(String groupId) {
    _groups.remove(groupId);
    _snapshots.remove(groupId);
    _save();
  }

  void recordSnapshot(String groupId, SessionSnapshot snapshot) {
    if (!_groups.containsKey(groupId)) return;
    final list = _snapshots.putIfAbsent(groupId, () => [])
      ..removeWhere((s) => s.id == snapshot.id)
      ..insert(0, snapshot);
    if (list.length > _maxSnapshotsPerGroup) list.removeLast();
    _upsertSavedSession(snapshot);
    _save();
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
    _save();
  }

  void removeSnapshot(String snapshotId) {
    for (final list in _snapshots.values) {
      list.removeWhere((s) => s.id == snapshotId);
    }
    _savedSessions.removeWhere((s) => s.id == snapshotId);
    _save();
  }

  void _clear() {
    _groups.clear();
    _snapshots.clear();
    _savedSessions.clear();
    _defaultInstructions = '';
  }

  void _save() {
    final file = _file;
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'defaultInstructions': _defaultInstructions,
          'groups': [
            for (final group in _groups.values)
              {
                ...group.toJson(),
                'snapshots': [
                  for (final s in snapshotsFor(group.id)) s.toJson(),
                ],
              },
          ],
          'sessions': [for (final s in _savedSessions) s.toJson()],
        }),
      );
    } on FileSystemException catch (_) {
      // 저장에 실패해도 이번 실행의 그룹 변경은 막지 않습니다.
    }
  }
}
