import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/models/agent_models.dart';
import 'json_file.dart';

/// 백엔드별로 마지막에 선택한 모델을 보관합니다.
class ModelPreferenceStore {
  ModelPreferenceStore({File? file}) : _file = file {
    if (file == null || !file.existsSync()) return;
    try {
      final saved = jsonDecode(file.readAsStringSync()) as Map;
      for (final backend in BackendType.values) {
        final model = saved[backend.id];
        if (model is String && backend.availableModels.contains(model)) {
          _models[backend] = model;
        }
      }
    } on Exception catch (_) {
      // 손상된 파일은 저장된 값이 없는 것으로 취급합니다.
    } on TypeError catch (_) {
      _models.clear();
    }
  }

  factory ModelPreferenceStore.load() {
    final home = Platform.environment['HOME'];
    return ModelPreferenceStore(
      file: home == null
          ? null
          : File(p.join(home, '.agent_control_center', 'models.json')),
    );
  }

  final File? _file;
  final Map<BackendType, String> _models = {};

  String modelFor(BackendType backend) =>
      _models[backend] ?? backend.defaultModel;

  void remember(BackendType backend, String model) {
    final base = backend.baseModel(model);
    if (!backend.availableModels.contains(base) || _models[backend] == base) {
      return;
    }
    _models[backend] = base;
    final file = _file;
    if (file == null) return;
    try {
      writeJsonAtomically(file, {
        for (final entry in _models.entries) entry.key.id: entry.value,
      });
    } on FileSystemException catch (_) {
      // 저장에 실패해도 이번 실행의 모델 변경은 막지 않습니다.
    }
  }
}
