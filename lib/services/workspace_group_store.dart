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

/// 앱을 다시 켠 뒤에도 이어갈 수 있도록 남기는 세션의 마지막 작업
class SessionSnapshot {
  const SessionSnapshot({
    required this.id,
    required this.title,
    required this.backend,
    required this.lastTurn,
    required this.updatedAt,
  });

  factory SessionSnapshot.fromJson(Map<String, dynamic> json) =>
      SessionSnapshot(
        id: json['id'] as String,
        title: json['title'] as String,
        backend: BackendType.fromId(json['backend'] as String),
        lastTurn: json['lastTurn'] as String,
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );

  final String id;
  final String title;
  final BackendType backend;
  final String lastTurn;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'backend': backend.id,
    'lastTurn': lastTurn,
    'updatedAt': updatedAt.toIso8601String(),
  };
}

/// 작업 그룹, 공통 기본 지침, 그룹별 세션 스냅샷을 JSON 파일로 보관합니다.
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
        _snapshots[group.id] = [
          for (final s in json['snapshots'] as List)
            SessionSnapshot.fromJson(s as Map<String, dynamic>),
        ];
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

  final File? _file;
  final Map<String, WorkspaceGroup> _groups = {};
  final Map<String, List<SessionSnapshot>> _snapshots = {};
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
    _save();
  }

  void removeSnapshot(String snapshotId) {
    for (final list in _snapshots.values) {
      list.removeWhere((s) => s.id == snapshotId);
    }
    _save();
  }

  void _clear() {
    _groups.clear();
    _snapshots.clear();
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
        }),
      );
    } on FileSystemException catch (_) {
      // 저장에 실패해도 이번 실행의 그룹 변경은 막지 않습니다.
    }
  }
}
