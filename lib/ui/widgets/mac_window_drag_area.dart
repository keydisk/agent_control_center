import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _windowChannel = MethodChannel('agent_control_center/window');

/// 제목 표시줄을 덮은 영역에서 창 이동을 처리합니다.
/// 더블탭 인식기는 안쪽 버튼의 탭을 지연시키므로 더블클릭 확대는 넣지 않습니다.
class MacWindowDragArea extends StatelessWidget {
  const MacWindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => _windowChannel.invokeMethod<void>('startDragging'),
      child: child,
    );
  }
}
