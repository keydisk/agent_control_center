import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/models/agent_models.dart';
import 'json_file.dart';

/// 앱 전역 설정을 JSON 파일로 보관합니다. 모델·추론 강도·신뢰 폴더는 각자의 저장소에 있습니다.
class AppSettingsStore {
  AppSettingsStore({File? file}) : _file = file {
    if (file == null || !file.existsSync()) return;
    try {
      _values.addAll(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
      );
    } on Exception catch (_) {
      // 손상된 파일은 저장된 값이 없는 것으로 취급합니다.
    } on TypeError catch (_) {
      _values.clear();
    }
  }

  factory AppSettingsStore.load() {
    final home = Platform.environment['HOME'];
    return AppSettingsStore(
      file: home == null
          ? null
          : File(p.join(home, '.agent_control_center', 'settings.json')),
    );
  }

  final File? _file;
  final Map<String, dynamic> _values = {};

  bool get showSessionSidebar => _bool('showSessionSidebar', true);
  set showSessionSidebar(bool value) => _set('showSessionSidebar', value);

  bool get showKvCachePanel => _bool('showKvCachePanel', true);
  set showKvCachePanel(bool value) => _set('showKvCachePanel', value);

  bool get showRawLogs => _bool('showRawLogs', false);
  set showRawLogs(bool value) => _set('showRawLogs', value);

  bool get autoOrchestrate => _bool('autoOrchestrate', true);
  set autoOrchestrate(bool value) => _set('autoOrchestrate', value);

  TargetDeviceType get device =>
      TargetDeviceType.values.asNameMap()[_values['device']] ??
      TargetDeviceType.macosDesktop;
  set device(TargetDeviceType value) => _set('device', value.name);

  /// 권한 무시는 켤 때마다 확인을 거치도록 저장하지도, 복원하지도 않습니다.
  PermissionMode? get permissionMode {
    final mode = PermissionMode.values.asNameMap()[_values['permissionMode']];
    return mode == PermissionMode.bypass ? null : mode;
  }

  set permissionMode(PermissionMode value) {
    if (value != PermissionMode.bypass) _set('permissionMode', value.name);
  }

  BackendType? get backend {
    final id = _values['backend'];
    return id is String ? BackendType.fromId(id) : null;
  }

  set backend(BackendType value) => _set('backend', value.id);

  /// 사라진 폴더는 돌려주지 않습니다.
  String? get workingDirectory {
    final dir = _values['workingDirectory'];
    return dir is String && Directory(dir).existsSync() ? dir : null;
  }

  set workingDirectory(String value) => _set('workingDirectory', value);

  bool isGroupCollapsed(String groupId) =>
      _strings('collapsedGroups').contains(groupId);

  void setGroupCollapsed(String groupId, bool collapsed) =>
      _setMember('collapsedGroups', groupId, collapsed);

  bool isSkillDisabled(String name) =>
      _strings('disabledSkills').contains(name);

  void setSkillDisabled(String name, bool disabled) =>
      _setMember('disabledSkills', name, disabled);

  bool _bool(String key, bool fallback) {
    final value = _values[key];
    return value is bool ? value : fallback;
  }

  Set<String> _strings(String key) {
    final value = _values[key];
    return value is List ? value.whereType<String>().toSet() : {};
  }

  void _setMember(String key, String member, bool present) {
    final members = _strings(key);
    if (members.contains(member) == present) return;
    present ? members.add(member) : members.remove(member);
    _set(key, members.toList());
  }

  void _set(String key, Object value) {
    if (_values[key] == value) return;
    _values[key] = value;
    final file = _file;
    if (file == null) return;
    try {
      writeJsonAtomically(file, _values);
    } on FileSystemException catch (_) {
      // 저장에 실패해도 이번 실행의 설정 변경은 막지 않습니다.
    }
  }
}
