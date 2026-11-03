import 'dart:math' show max;

import 'package:flutter/material.dart';

import '../../core/models/agent_models.dart';
import '../../services/provider_usage_service.dart';
import '../theme/mac_theme.dart';

/// 오른쪽 사이드바. 토큰 사용량 그래프와 KV(프롬프트) 캐시 적중률을 표시합니다.
class KvCachePanel extends StatelessWidget {
  const KvCachePanel({
    super.key,
    required this.session,
    required this.usageByBackend,
    this.providerUsages = const [],
  });

  final TokenUsage session;
  final Map<BackendType, TokenUsage> usageByBackend;
  final List<ProviderUsage> providerUsages;

  static String _window(UsageWindow? window) {
    if (window == null) return '정보 없음';
    final remaining = window.resetsAt?.difference(DateTime.now());
    final reset = remaining == null || remaining.isNegative
        ? ''
        : ' · ${remaining.inHours}시간 ${remaining.inMinutes.remainder(60)}분 후';
    return '${window.usedPercent.toStringAsFixed(0)}%$reset';
  }

  static String _contextLabel(ProviderUsage usage) {
    final used = usage.contextUsed;
    final limit = usage.contextLimit;
    if (used == null || limit == null || limit <= 0) return '정보 없음';
    return '$used/$limit tok';
  }

  static String _percent(TokenUsage usage) =>
      '${(usage.cacheHitRate * 100).toStringAsFixed(1)}%';

  static String _breakdown(TokenUsage usage) =>
      '입력 ${usage.promptTokens} · 출력 ${usage.outputTokens}'
      '${usage.costUsd > 0 ? ' · \$${usage.costUsd.toStringAsFixed(4)}' : ''}';

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    final maxTokens = usageByBackend.values.fold(
      0,
      (largest, usage) => max(largest, usage.totalTokens),
    );
    final labelStyle = TextStyle(fontSize: 11, color: mac.secondaryLabel);
    final valueStyle = TextStyle(
      fontSize: 11,
      color: mac.label,
      fontFamily: kMonoFont,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Widget row(String label, String value, {Key? valueKey}) => Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              value,
              key: valueKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: valueStyle,
            ),
          ),
        ],
      ),
    );

    Widget barRow(
      String label,
      String value, {
      required double fraction,
      Key? barKey,
      Key? valueKey,
      String? semanticsLabel,
      double minHeight = 5,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row(label, value, valueKey: valueKey),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              key: barKey,
              value: fraction.clamp(0.0, 1.0),
              minHeight: minHeight,
              color: mac.blue,
              backgroundColor: mac.fill,
              semanticsLabel: semanticsLabel ?? '$label $value',
            ),
          ),
        ],
      ),
    );

    return Container(
      key: const ValueKey('kv_cache_panel'),
      width: 200,
      color: mac.sidebar,
      // 창이 낮아도 넘치지 않도록 스크롤합니다.
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            '사용량',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          row(
            '현재 세션',
            '${session.totalTokens} tok',
            valueKey: const ValueKey('usage_session_tokens'),
          ),
          const SizedBox(height: 6),
          for (final backend in BackendType.values)
            Builder(
              builder: (context) {
                final usage = usageByBackend[backend] ?? const TokenUsage();
                return Tooltip(
                  message: _breakdown(usage),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        row(backend.displayName, '${usage.totalTokens} tok'),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            key: ValueKey('usage_bar_${backend.id}'),
                            value: maxTokens == 0
                                ? 0
                                : usage.totalTokens / maxTokens,
                            minHeight: 6,
                            color: mac.blue,
                            backgroundColor: mac.fill,
                            semanticsLabel:
                                '${backend.displayName} 토큰 사용량 '
                                '${usage.totalTokens}',
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 12),
          const Text(
            'KV 캐시',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Text('현재 세션', style: labelStyle),
          const SizedBox(height: 4),
          Text(
            _percent(session),
            key: const ValueKey('kv_cache_hit_rate'),
            style: valueStyle.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: session.cacheHitRate,
              minHeight: 4,
              color: mac.blue,
              backgroundColor: mac.fill,
              semanticsLabel: 'KV 캐시 적중률',
            ),
          ),
          const SizedBox(height: 8),
          row(
            '캐시 적중',
            '${session.cachedTokens} tok',
            valueKey: const ValueKey('kv_cache_tokens'),
          ),
          row('전체 입력', '${session.promptTokens} tok'),
          const SizedBox(height: 12),
          Text('백엔드별 적중률', style: labelStyle),
          const SizedBox(height: 4),
          for (final backend in BackendType.values)
            Builder(
              builder: (context) {
                final usage = usageByBackend[backend] ?? const TokenUsage();
                return barRow(
                  backend.displayName,
                  _percent(usage),
                  fraction: usage.cacheHitRate,
                  barKey: ValueKey('kv_cache_bar_${backend.id}'),
                  minHeight: 4,
                );
              },
            ),
          const SizedBox(height: 8),
          Text(
            '턴이 끝날 때 갱신됩니다.',
            style: labelStyle.copyWith(
              fontSize: 10.5,
              color: mac.tertiaryLabel,
            ),
          ),
          const SizedBox(height: 12),
          const Divider(),
          const Text(
            '공급자 한도',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          for (final backend in BackendType.values) ...[
            Text(backend.displayName, style: labelStyle),
            const SizedBox(height: 4),
            for (final usage in providerUsages.where(
              (u) => u.backend == backend,
            )) ...[
              if (usage.name != backend.displayName)
                Text(
                  usage.name,
                  style: labelStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              barRow(
                '5시간',
                _window(usage.fiveHour),
                fraction: (usage.fiveHour?.usedPercent ?? 0) / 100,
                barKey: ValueKey(
                  'provider_five_hour_bar_${backend.id}_${usage.name}',
                ),
              ),
              barRow(
                '일주일',
                _window(usage.weekly),
                fraction: (usage.weekly?.usedPercent ?? 0) / 100,
                barKey: ValueKey(
                  'provider_weekly_bar_${backend.id}_${usage.name}',
                ),
              ),
              barRow(
                '최근 컨텍스트',
                _contextLabel(usage),
                fraction: usage.contextFraction,
                barKey: ValueKey(
                  'provider_context_bar_${backend.id}_${usage.name}',
                ),
              ),
              const SizedBox(height: 6),
            ],
            if (!providerUsages.any((u) => u.backend == backend))
              barRow(
                '사용량 정보 없음',
                '0%',
                fraction: 0,
                barKey: ValueKey('provider_empty_bar_${backend.id}'),
              ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
