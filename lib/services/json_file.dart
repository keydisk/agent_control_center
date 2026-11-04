import 'dart:convert';
import 'dart:io';

/// 쓰는 도중 앱이 꺼져도 기존 파일이 깨지지 않도록 임시 파일을 거쳐 교체합니다.
void writeJsonAtomically(File file, Object? value) {
  file.parent.createSync(recursive: true);
  final temp = File('${file.path}.$pid.tmp');
  temp.writeAsStringSync(jsonEncode(value), flush: true);
  temp.renameSync(file.path);
}
