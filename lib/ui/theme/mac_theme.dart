import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/agent_models.dart';

const String kMonoFont = 'Menlo';

/// macOS 시스템 색상 값. 라이트 모드는 글자 대비를 위해 고대비 변형을 씁니다.
@immutable
class MacColors extends ThemeExtension<MacColors> {
  const MacColors({
    required this.window,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.separator,
    required this.fill,
    required this.selection,
    required this.blue,
    required this.green,
    required this.red,
    required this.orange,
    required this.purple,
    required this.codeBackground,
    required this.codeHeader,
    required this.codeText,
    required this.backendPalette,
  });

  static const light = MacColors(
    window: Color(0xFFFFFFFF),
    label: Color(0xE6000000),
    secondaryLabel: Color(0x99000000),
    tertiaryLabel: Color(0x66000000),
    separator: Color(0x1F000000),
    fill: Color(0x0D000000),
    selection: Color(0x1F007AFF),
    blue: Color(0xFF0066D6),
    green: Color(0xFF248A3D),
    red: Color(0xFFD70015),
    orange: Color(0xFFC93400),
    purple: Color(0xFF8944AB),
    codeBackground: Color(0xFFF5F5F7),
    codeHeader: Color(0xFFEBEBED),
    codeText: Color(0xFF1D1D1F),
    backendPalette: [Color(0xFF0066D6), Color(0xFFC43A70), Color(0xFF7A5CD6)],
  );

  static const dark = MacColors(
    window: Color(0xFF1E1E1E),
    label: Color(0xE6FFFFFF),
    secondaryLabel: Color(0x99FFFFFF),
    tertiaryLabel: Color(0x66FFFFFF),
    separator: Color(0x1FFFFFFF),
    fill: Color(0x12FFFFFF),
    selection: Color(0x400A84FF),
    blue: Color(0xFF409CFF),
    green: Color(0xFF30D158),
    red: Color(0xFFFF6961),
    orange: Color(0xFFFF9F0A),
    purple: Color(0xFFBF5AF2),
    codeBackground: Color(0xFF161618),
    codeHeader: Color(0xFF232325),
    codeText: Color(0xFFE5E5E7),
    backendPalette: [Color(0xFF3B93F5), Color(0xFFD96A95), Color(0xFF9580EA)],
  );

  final Color window;
  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;
  final Color separator;
  final Color fill;
  final Color selection;
  final Color blue;
  final Color green;
  final Color red;
  final Color orange;
  final Color purple;
  final Color codeBackground;
  final Color codeHeader;
  final Color codeText;

  /// [BackendType] 선언 순서의 그래프 색상. 색각 이상 구분까지 검증한 값입니다.
  final List<Color> backendPalette;

  Color backendColor(BackendType backend) => backendPalette[backend.index];

  /// 한도 소진율(0~1)의 상태 색상. 많이 쓸수록 빨강 → 주황 → 초록입니다.
  Color usageLevelColor(double fraction) => fraction >= 0.8
      ? green
      : fraction >= 0.5
      ? orange
      : red;

  /// 네이티브 창의 NSVisualEffectView가 비치는 영역. macOS 외에는 불투명합니다.
  Color get sidebar => Platform.isMacOS ? Colors.transparent : codeHeader;

  @override
  MacColors copyWith() => this;

  // 라이트·다크 전환은 애니메이션 중간색이 필요 없습니다.
  @override
  MacColors lerp(ThemeExtension<MacColors>? other, double t) =>
      t < 0.5 || other is! MacColors ? this : other;
}

extension MacColorsContext on BuildContext {
  MacColors get mac {
    final theme = Theme.of(this);
    return theme.extension<MacColors>() ??
        (theme.brightness == Brightness.dark
            ? MacColors.dark
            : MacColors.light);
  }
}

ThemeData buildMacTheme(Brightness brightness) {
  final mac = brightness == Brightness.dark ? MacColors.dark : MacColors.light;
  final accent = brightness == Brightness.dark
      ? const Color(0xFF0A84FF)
      : const Color(0xFF007AFF);
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: accent,
        onPrimary: Colors.white,
        primaryContainer: mac.selection,
        onPrimaryContainer: mac.label,
        secondaryContainer: mac.fill,
        onSecondaryContainer: mac.label,
        surface: mac.window,
        onSurface: mac.label,
        onSurfaceVariant: mac.secondaryLabel,
        surfaceContainerLowest: mac.window,
        surfaceContainerLow: mac.window,
        surfaceContainer: mac.fill,
        surfaceContainerHigh: mac.window,
        surfaceContainerHighest: mac.fill,
        outline: mac.separator,
        outlineVariant: mac.separator,
        error: mac.red,
      );
  final hairline = BorderSide(color: mac.separator, width: 0.5);
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(6),
  );
  const buttonText = TextStyle(fontSize: 13, fontWeight: FontWeight.w500);
  const buttonSize = Size(0, 26);
  const buttonPadding = EdgeInsets.symmetric(horizontal: 10);
  OutlineInputBorder inputBorder(BorderSide side) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(6),
    borderSide: side,
  );

  final base = ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    useMaterial3: true,
  );
  return base.copyWith(
    extensions: [mac],
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    splashFactory: NoSplash.splashFactory,
    scaffoldBackgroundColor: mac.window,
    dividerColor: mac.separator,
    hoverColor: mac.fill,
    highlightColor: mac.fill,
    focusColor: mac.selection,
    textTheme: base.textTheme
        .copyWith(
          titleLarge: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          titleMedium: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          titleSmall: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
          bodyLarge: const TextStyle(fontSize: 13, height: 1.4),
          bodyMedium: const TextStyle(fontSize: 13, height: 1.4),
          bodySmall: TextStyle(fontSize: 11, color: mac.secondaryLabel),
          labelLarge: buttonText,
        )
        .apply(bodyColor: mac.label, displayColor: mac.label),
    dividerTheme: DividerThemeData(
      color: mac.separator,
      thickness: 0.5,
      space: 1,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: mac.fill,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: hairline,
      ),
    ),
    dialogTheme: DialogThemeData(
      elevation: 24,
      backgroundColor: mac.window,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: hairline,
      ),
      titleTextStyle: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: mac.label,
      ),
      contentTextStyle: TextStyle(fontSize: 13, height: 1.4, color: mac.label),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: buttonSize,
        padding: buttonPadding,
        shape: buttonShape,
        textStyle: buttonText,
        elevation: 0,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: buttonSize,
        padding: buttonPadding,
        shape: buttonShape,
        textStyle: buttonText,
        foregroundColor: mac.label,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: buttonSize,
        padding: buttonPadding,
        shape: buttonShape,
        textStyle: buttonText,
        foregroundColor: mac.label,
        side: hairline,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(26, 26),
        padding: const EdgeInsets.all(4),
        iconSize: 16,
        shape: buttonShape,
        foregroundColor: mac.secondaryLabel,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: mac.fill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      hintStyle: TextStyle(fontSize: 13, color: mac.tertiaryLabel),
      labelStyle: TextStyle(fontSize: 12, color: mac.secondaryLabel),
      border: inputBorder(hairline),
      enabledBorder: inputBorder(hairline),
      focusedBorder: inputBorder(BorderSide(color: accent, width: 1.5)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      elevation: 8,
      color: mac.window,
      surfaceTintColor: Colors.transparent,
      menuPadding: const EdgeInsets.all(4),
      textStyle: TextStyle(fontSize: 13, color: mac.label),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: hairline,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      textStyle: TextStyle(fontSize: 11, color: mac.label),
      decoration: BoxDecoration(
        color: mac.window,
        borderRadius: BorderRadius.circular(4),
        border: Border.fromBorderSide(hairline),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbIcon: const WidgetStatePropertyAll(Icon(null)),
      trackColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? accent : mac.separator,
      ),
    ),
    chipTheme: ChipThemeData(
      labelStyle: TextStyle(fontSize: 12, color: mac.label),
      backgroundColor: Colors.transparent,
      selectedColor: mac.selection,
      side: hairline,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
    ),
    listTileTheme: const ListTileThemeData(dense: true),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: 420,
      backgroundColor: mac.codeHeader,
      contentTextStyle: TextStyle(fontSize: 13, color: mac.label),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(mac.tertiaryLabel),
    ),
  );
}
