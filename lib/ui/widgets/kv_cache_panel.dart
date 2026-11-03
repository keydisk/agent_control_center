import 'package:flutter/material.dart';

import '../../core/models/agent_models.dart';
import '../theme/mac_theme.dart';

/// 오른쪽 사이드바. 현재 세션과 백엔드별 KV(프롬프트) 캐시 사용량을 표시합니다.
class KvCachePanel extends StatelessWidget {
  const KvCachePanel({
    super.key,
    required this.session,
    required this.usageByBackend,
  });

  final TokenUsage session;
  final Map<BackendType, TokenUsage> usageByBackend;

  static String _percent(TokenUsage usage) =>
      '${(usage.cacheHitRate * 100).toStringAsFixed(1)}%';

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
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
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          ),
          Text(value, key: valueKey, style: valueStyle),
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
            row(
              backend.displayName,
              _percent(usageByBackend[backend] ?? const TokenUsage()),
            ),
          const SizedBox(height: 8),
          Text(
            '턴이 끝날 때 갱신됩니다.',
            style: labelStyle.copyWith(
              fontSize: 10.5,
              color: mac.tertiaryLabel,
            ),
          ),
        ],
      ),
    );
  }
}
