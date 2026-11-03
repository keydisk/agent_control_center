import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 에이전트 실행을 허용한 폴더 목록을 JSON 파일로 보관합니다.
/// 하위 폴더는 신뢰를 상속하며, 심볼릭 링크는 실제 경로로 판정합니다.
class TrustedFolderStore {
  TrustedFolderStore({File? file}) : _file = file {
    final f = file;
    if (f == null || !f.existsSync()) return;
    try {
      _folders.addAll(
        (jsonDecode(f.readAsStringSync()) as List).cast<String>(),
      );
    } on Exception catch (_) {
      // 손상된 파일은 신뢰 없음으로 취급하고 다시 묻습니다.
    } on TypeError catch (_) {
      _folders.clear();
    }
  }

  factory TrustedFolderStore.load() {
    final home = Platform.environment['HOME'];
    return TrustedFolderStore(
      file: home == null
          ? null
          : File(p.join(home, '.agent_control_center', 'trusted_folders.json')),
    );
  }

  final File? _file;
  final List<String> _folders = [];

  List<String> get folders => List.unmodifiable(_folders);

  bool isTrusted(String path) => coveringFolders(path).isNotEmpty;

  /// 이 경로에 신뢰를 주는 등록 폴더들. 상위 폴더 등록도 포함합니다.
  List<String> coveringFolders(String path) {
    final target = _canonical(path);
    return _folders
        .where((f) => f == target || p.isWithin(f, target))
        .toList(growable: false);
  }

  void add(String path) {
    if (!Directory(path).existsSync()) {
      throw StateError('존재하지 않는 폴더는 신뢰할 수 없습니다: $path');
    }
    final folder = _canonical(path);
    if (p.rootPrefix(folder) == folder) {
      throw StateError('루트 폴더는 신뢰할 수 없습니다. 작업 디렉터리를 프로젝트 폴더로 변경해 주세요.');
    }
    if (_folders.contains(folder)) return;
    _folders.add(folder);
    _save();
  }

  void remove(String folder) {
    if (_folders.remove(folder)) _save();
  }

  void _save() {
    final file = _file;
    if (file == null) return;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(_folders));
  }

  static String _canonical(String path) {
    try {
      return Directory(path).resolveSymbolicLinksSync();
    } on FileSystemException catch (_) {
      return p.normalize(p.absolute(path));
    }
  }
}
