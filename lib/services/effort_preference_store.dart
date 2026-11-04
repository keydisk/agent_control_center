import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/models/agent_models.dart';
import 'json_file.dart';

/// 백엔드별로 마지막에 고른 추론 강도를 JSON 파일로 보관합니다.
class EffortPreferenceStore {
  EffortPreferenceStore({File? file}) : _file = file {
    final f = file;
    if (f == null || !f.existsSync()) return;
    try {
      final saved = jsonDecode(f.readAsStringSync()) as Map;
      for (final backend in BackendType.values) {
        final effort = ReasoningEffort.values.asNameMap()[saved[backend.id]];
        if (backend.supportedEfforts.contains(effort)) {
          _efforts[backend] = effort!;
        }
      }
    } on Exception catch (_) {
      // 손상된 파일은 저장된 값이 없는 것으로 취급합니다.
    } on TypeError catch (_) {
      _efforts.clear();
    }
  }

  factory EffortPreferenceStore.load() {
    final home = Platform.environment['HOME'];
    return EffortPreferenceStore(
      file: home == null
          ? null
          : File(p.join(home, '.agent_control_center', 'efforts.json')),
    );
  }

  final File? _file;
  final Map<BackendType, ReasoningEffort> _efforts = {};

  ReasoningEffort? effortFor(BackendType backend) => _efforts[backend];

  void remember(BackendType backend, ReasoningEffort effort) {
    if (_efforts[backend] == effort) return;
    _efforts[backend] = effort;
    final file = _file;
    if (file == null) return;
    try {
      writeJsonAtomically(file, {
        for (final e in _efforts.entries) e.key.id: e.value.name,
      });
    } on FileSystemException catch (_) {
      // 저장에 실패해도 이번 실행의 강도 변경은 막지 않습니다.
    }
  }
}
