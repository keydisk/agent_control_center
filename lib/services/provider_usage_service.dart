import 'dart:convert';
import 'dart:io';

import '../core/backend/agent_backend.dart';
import '../core/models/agent_models.dart';

class UsageWindow {
  const UsageWindow(this.usedPercent, this.resetsAt);

  final double usedPercent;
  final DateTime? resetsAt;
}

class ProviderUsage {
  const ProviderUsage({
    required this.backend,
    required this.name,
    this.fiveHour,
    this.weekly,
    this.contextUsed,
    this.contextLimit,
  });

  final BackendType backend;
  final String name;
  final UsageWindow? fiveHour;
  final UsageWindow? weekly;
  final int? contextUsed;
  final int? contextLimit;
}

/// 공급자가 로컬 CLI/캐시에 공개한 값만 읽습니다. 계정 자격 증명은 읽지 않습니다.
class ProviderUsageService {
  const ProviderUsageService();

  Future<List<ProviderUsage>> load() async {
    final results = await Future.wait([_claude(), _codex(), _antigravity()]);
    return results.expand((items) => items).toList();
  }

  Future<List<ProviderUsage>> _claude() async {
    final home =
        Platform.environment['CLAUDE_CONFIG_DIR']?.split(',').first ??
        Platform.environment['HOME'];
    if (home == null) return const [];
    try {
      final file = File('$home/.claude.json');
      final root =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final cache = root['cachedUsageUtilization'] as Map<String, dynamic>?;
      if (cache == null ||
          cache['accountUuid'] != null &&
              cache['accountUuid'] !=
                  (root['oauthAccount'] as Map?)?['accountUuid']) {
        return const [];
      }
      final fetched = (cache['fetchedAtMs'] as num?)?.toInt();
      if (fetched == null ||
          DateTime.now().difference(
                DateTime.fromMillisecondsSinceEpoch(fetched),
              ) >
              const Duration(hours: 6)) {
        return const [];
      }
      final utilization = cache['utilization'] as Map<String, dynamic>?;
      if (utilization == null) return const [];
      final suffixes = <String>{''};
      for (final key in utilization.keys) {
        if (key.startsWith('five_hour_')) {
          suffixes.add(key.substring('five_hour'.length));
        } else if (key.startsWith('seven_day_')) {
          suffixes.add(key.substring('seven_day'.length));
        }
      }
      return [
        for (final suffix in suffixes)
          if (utilization['five_hour$suffix'] != null ||
              utilization['seven_day$suffix'] != null)
            ProviderUsage(
              backend: BackendType.claudeCode,
              name: suffix.isEmpty
                  ? BackendType.claudeCode.displayName
                  : 'Claude ${suffix.substring(1)}',
              fiveHour: parseClaudeWindow(utilization['five_hour$suffix']),
              weekly: parseClaudeWindow(utilization['seven_day$suffix']),
            ),
      ];
    } on Object {
      return const [];
    }
  }

  Future<List<ProviderUsage>> _codex() async {
    final home =
        Platform.environment['CODEX_HOME'] ??
        (Platform.environment['HOME'] == null
            ? null
            : '${Platform.environment['HOME']}/.codex');
    if (home == null) return const [];
    final now = DateTime.now();
    final files = <File>[];
    for (var daysAgo = 0; daysAgo < 7; daysAgo++) {
      final day = now.subtract(Duration(days: daysAgo));
      final path =
          '$home/sessions/${day.year}/${day.month.toString().padLeft(2, '0')}/${day.day.toString().padLeft(2, '0')}';
      try {
        files.addAll(Directory(path).listSync().whereType<File>());
      } on FileSystemException {
        continue;
      }
    }
    files.sort((a, b) => b.path.compareTo(a.path));
    final found = <String, ProviderUsage>{};
    // shortcut: 최근 8개 로그만 읽습니다. 오래된 모델 한도가 필요해지면 범위를 늘립니다.
    for (final file in files.take(8)) {
      try {
        final lines = await file.readAsLines();
        for (final line in lines.reversed) {
          if (!line.contains('"token_count"')) continue;
          final event = jsonDecode(line) as Map<String, dynamic>;
          final payload = event['payload'] as Map<String, dynamic>?;
          final rates = payload?['rate_limits'] as Map<String, dynamic>?;
          if (rates == null) continue;
          final id = rates['limit_id']?.toString() ?? 'codex';
          if (found.containsKey(id)) continue;
          final info = payload?['info'] as Map<String, dynamic>?;
          final last = info?['last_token_usage'] as Map<String, dynamic>?;
          found[id] = ProviderUsage(
            backend: BackendType.codex,
            name:
                rates['limit_name']?.toString() ??
                (id == 'codex' ? BackendType.codex.displayName : id),
            fiveHour: (rates['primary'] as Map?)?['window_minutes'] == 300
                ? parseCodexWindow(rates['primary'])
                : null,
            weekly: (rates['secondary'] as Map?)?['window_minutes'] == 10080
                ? parseCodexWindow(rates['secondary'])
                : null,
            contextUsed: (last?['input_tokens'] as num?)?.toInt(),
            contextLimit: (info?['model_context_window'] as num?)?.toInt(),
          );
        }
      } on Object {
        continue;
      }
    }
    return found.values.toList();
  }

  Future<List<ProviderUsage>> _antigravity() async {
    try {
      final process = await Process.start('agy', [
        '-p',
        '/usage',
        '--output-format',
        'json',
        '--log-file',
        '${Directory.systemTemp.path}/agent-control-center-agy-usage.log',
      ], environment: IoProcessSpawner.buildMergedEnvironment(null));
      final output = process.stdout.transform(utf8.decoder).join();
      process.stderr.drain<void>().ignore();
      final exit = await process.exitCode.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      if (exit != 0) return const [];
      return parseAntigravityUsage(await output);
    } on Object {
      return const [];
    }
  }
}

UsageWindow? parseClaudeWindow(Object? raw) {
  if (raw is! Map) return null;
  final used = raw['utilization'];
  if (used is! num || !used.isFinite) return null;
  final reset = DateTime.tryParse(raw['resets_at']?.toString() ?? '');
  if (reset != null && reset.isBefore(DateTime.now())) {
    return UsageWindow(0, reset);
  }
  return UsageWindow(used.toDouble().clamp(0, 100).toDouble(), reset);
}

UsageWindow? parseCodexWindow(Object? raw) {
  if (raw is! Map || raw['used_percent'] is! num) return null;
  final used = (raw['used_percent'] as num).toDouble();
  if (!used.isFinite) return null;
  final reset = raw['resets_at'];
  final at = reset is num
      ? DateTime.fromMillisecondsSinceEpoch(reset.toInt() * 1000)
      : null;
  if (at != null && at.isBefore(DateTime.now())) return UsageWindow(0, at);
  return UsageWindow(used.clamp(0, 100).toDouble(), at);
}

List<ProviderUsage> parseAntigravityUsage(String output) {
  try {
    final root = jsonDecode(output) as Map<String, dynamic>;
    final command = root['command'] as Map<String, dynamic>?;
    final data = command?['data'] as Map<String, dynamic>?;
    final groups = data?['groups'] as List?;
    if (groups == null) return const [];
    return [
      for (final item in groups)
        if (item is Map && item['buckets'] is List)
          ProviderUsage(
            backend: BackendType.antigravity,
            name:
                item['displayName']?.toString() ??
                item['name']?.toString() ??
                'Antigravity',
            fiveHour: _agyWindow(item['buckets'] as List, weekly: false),
            weekly: _agyWindow(item['buckets'] as List, weekly: true),
          ),
    ];
  } on Object {
    return const [];
  }
}

UsageWindow? _agyWindow(List buckets, {required bool weekly}) {
  for (final item in buckets) {
    if (item is! Map || item['disabled'] == true) continue;
    final label = [
      item['bucketId'],
      item['id'],
      item['displayName'],
      item['name'],
      item['window'],
    ].whereType<String>().join(' ').toLowerCase();
    final isWeek =
        label.contains('week') ||
        label.contains('7d') ||
        label.contains('seven');
    if (weekly != isWeek) continue;
    if (!weekly &&
        !label.contains('session') &&
        !label.contains('hour') &&
        !label.contains('5')) {
      continue;
    }
    final rawRemaining =
        item['remainingFraction'] ??
        item['remaining_fraction'] ??
        (item['remaining'] is Map
            ? (item['remaining'] as Map)['remainingFraction']
            : null);
    final remaining = num.tryParse(rawRemaining?.toString() ?? '');
    if (remaining == null || !remaining.isFinite) continue;
    final reset = DateTime.tryParse(
      (item['resetTime'] ??
                  item['reset_time'] ??
                  item['resetAt'] ??
                  item['reset_at'])
              ?.toString() ??
          '',
    );
    return UsageWindow((100 - remaining * 100).clamp(0, 100).toDouble(), reset);
  }
  return null;
}
