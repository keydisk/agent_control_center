import 'dart:io';

import 'package:agent_control_center/ui/theme/mac_theme.dart';
import 'package:agent_control_center/ui/widgets/mac_window_drag_area.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

double _luminanceContrast(Color a, Color b) {
  final hi = a.computeLuminance() > b.computeLuminance() ? a : b;
  final lo = identical(hi, a) ? b : a;
  return (hi.computeLuminance() + 0.05) / (lo.computeLuminance() + 0.05);
}

void main() {
  test('상태 색상은 라이트·다크 창 배경에서 글자 대비 3:1 이상이다', () {
    for (final mac in [MacColors.light, MacColors.dark]) {
      for (final color in [mac.blue, mac.green, mac.red, mac.orange, mac.purple]) {
        expect(_luminanceContrast(color, mac.window), greaterThanOrEqualTo(3));
      }
    }
  });

  test('테마는 밝기에 맞는 색상 토큰을 제공한다', () {
    expect(buildMacTheme(Brightness.light).extension<MacColors>(), MacColors.light);
    expect(buildMacTheme(Brightness.dark).extension<MacColors>(), MacColors.dark);
    expect(buildMacTheme(Brightness.dark).brightness, Brightness.dark);
  });

  testWidgets('테마가 없는 화면도 밝기에 맞는 색상으로 대체한다', (tester) async {
    late MacColors resolved;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Builder(
          builder: (context) {
            resolved = context.mac;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(resolved, MacColors.dark);
  });

  testWidgets('창 이동 영역은 끌기를 네이티브로 전달한다', (tester) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('agent_control_center/window'),
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: MacWindowDragArea(child: SizedBox.expand()),
      ),
    );
    if (!Platform.isMacOS) return;
    await tester.drag(find.byType(MacWindowDragArea), const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(calls, ['startDragging']);
  });
}
