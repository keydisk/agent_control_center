import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/agent_models.dart';

/// 각 메시지/작업에 어떤 백엔드·모델이 처리했는지 표시하는 배지 위젯
class BackendModelBadge extends StatelessWidget {
  const BackendModelBadge({
    super.key,
    required this.backend,
    this.model = '',
  });

  final BackendType backend;
  final String model;

  Color _badgeColor() {
    switch (backend) {
      case BackendType.antigravity:
        return const Color(0xFF1A73E8);
      case BackendType.claudeCode:
        return const Color(0xFFD97757);
      case BackendType.codex:
        return const Color(0xFF10A37F);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _badgeColor();
    final label = model.isNotEmpty
        ? '${backend.displayName} · $model'
        : backend.displayName;
    return Container(
      constraints: const BoxConstraints(maxWidth: 140),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 마크다운 및 코드블록 문법 하이라이트 렌더러
class MarkdownMessageView extends StatelessWidget {
  const MarkdownMessageView({
    super.key,
    required this.markdown,
  });

  final String markdown;

  @override
  Widget build(BuildContext context) {
    final blocks = _parseBlocks(markdown);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in blocks)
          if (block.isCode)
            _CodeBlockHighlightedCard(
              language: block.language,
              code: block.content,
            )
          else
            _MarkdownParagraphBlock(text: block.content),
      ],
    );
  }

  List<_MdBlock> _parseBlocks(String raw) {
    final result = <_MdBlock>[];
    final codeBlockRegex = RegExp(
      r'```([a-zA-Z0-9_+-]*)\n([\s\S]*?)```',
      multiLine: true,
    );
    var lastIndex = 0;
    for (final match in codeBlockRegex.allMatches(raw)) {
      if (match.start > lastIndex) {
        final prose = raw.substring(lastIndex, match.start).trim();
        if (prose.isNotEmpty) {
          result.add(_MdBlock(isCode: false, content: prose));
        }
      }
      result.add(
        _MdBlock(
          isCode: true,
          language: (match.group(1) ?? '').trim(),
          content: (match.group(2) ?? '').trimRight(),
        ),
      );
      lastIndex = match.end;
    }
    if (lastIndex < raw.length) {
      final tail = raw.substring(lastIndex).trim();
      if (tail.isNotEmpty) {
        result.add(_MdBlock(isCode: false, content: tail));
      }
    }
    if (result.isEmpty && raw.isNotEmpty) {
      result.add(_MdBlock(isCode: false, content: raw));
    }
    return result;
  }
}

class _MdBlock {
  const _MdBlock({
    required this.isCode,
    required this.content,
    this.language = '',
  });

  final bool isCode;
  final String language;
  final String content;
}

class _MarkdownParagraphBlock extends StatelessWidget {
  const _MarkdownParagraphBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines) _buildLine(context, line),
      ],
    );
  }

  Widget _buildLine(BuildContext context, String line) {
    if (line.startsWith('### ')) {
      return Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 2),
        child: SelectableText(
          line.substring(4),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
      );
    }
    if (line.startsWith('## ')) {
      return Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 3),
        child: SelectableText(
          line.substring(3),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      );
    }
    if (line.startsWith('# ')) {
      return Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: SelectableText(
          line.substring(2),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: SelectableText.rich(_parseInlineSpans(line)),
    );
  }

  TextSpan _parseInlineSpans(String input) {
    final spans = <InlineSpan>[];
    final tokenRegex = RegExp(r'(`[^`]+`|\*\*[^*]+\*\*)');
    var idx = 0;
    for (final match in tokenRegex.allMatches(input)) {
      if (match.start > idx) {
        spans.add(TextSpan(text: input.substring(idx, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('`') && token.endsWith('`')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: const TextStyle(
              fontFamily: 'monospace',
              backgroundColor: Color(0x26888888),
              fontWeight: FontWeight.w500,
            ),
          ),
        );
      } else if (token.startsWith('**') && token.endsWith('**')) {
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );
      }
      idx = match.end;
    }
    if (idx < input.length) {
      spans.add(TextSpan(text: input.substring(idx)));
    }
    return TextSpan(style: const TextStyle(fontSize: 13.5), children: spans);
  }
}

class _CodeBlockHighlightedCard extends StatelessWidget {
  const _CodeBlockHighlightedCard({
    required this.language,
    required this.code,
  });

  final String language;
  final String code;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E2E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFF181825),
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  language.isEmpty ? 'code' : language,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white70,
                    fontFamily: 'monospace',
                  ),
                ),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: code));
                  },
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.copy, size: 13, color: Colors.white70),
                      SizedBox(width: 4),
                      Text(
                        '복사',
                        style: TextStyle(fontSize: 11, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText.rich(
              _highlightSyntax(code),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.4,
                color: Color(0xFFCDD6F4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  TextSpan _highlightSyntax(String source) {
    final keywordRegex = RegExp(
      r'\b(import|class|final|const|void|return|async|await|if|else|for|while|switch|case|def|from|function|var|let|true|false|null)\b',
    );
    final spans = <InlineSpan>[];
    var idx = 0;
    for (final m in keywordRegex.allMatches(source)) {
      if (m.start > idx) {
        spans.add(TextSpan(text: source.substring(idx, m.start)));
      }
      spans.add(
        TextSpan(
          text: m.group(0),
          style: const TextStyle(
            color: Color(0xFFCBA6F7),
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      idx = m.end;
    }
    if (idx < source.length) {
      spans.add(TextSpan(text: source.substring(idx)));
    }
    return TextSpan(children: spans);
  }
}

/// 접히는 도구 호출 카드 (도구명, 인자, 결과, 소요 시간)
class ToolCallCard extends StatelessWidget {
  const ToolCallCard({
    super.key,
    required this.event,
  });

  final ToolCallEvent event;

  @override
  Widget build(BuildContext context) {
    final argsJson = event.arguments.isEmpty
        ? '{}'
        : const JsonEncoder.withIndent('  ').convert(event.arguments);
    final statusColor = event.isError
        ? Colors.redAccent
        : (event.isRunning ? Colors.amber : Colors.teal);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: statusColor.withValues(alpha: 0.35)),
      ),
      child: ExpansionTile(
        leading: Icon(
          event.isError
              ? Icons.error_outline
              : (event.isRunning
                    ? Icons.hourglass_top_rounded
                    : Icons.build_circle_outlined),
          color: statusColor,
          size: 20,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '도구 호출: ${event.toolName}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: BackendModelBadge(
                backend: event.backend,
                model: event.model,
              ),
            ),
          ],
        ),
        subtitle: Text(
          event.durationMs > 0
              ? '소요 시간: ${event.durationMs}ms · ${event.isRunning ? "실행 중" : "완료"}'
              : (event.isRunning ? '실행 중...' : '완료'),
          style: const TextStyle(fontSize: 11.5),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '인자 (Arguments):',
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(
              argsJson,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
            ),
          ),
          if (event.result.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              '결과 (Result):',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SelectableText(
                event.result,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 파일 변경 Diff 뷰어 카드
class FileDiffViewerCard extends StatelessWidget {
  const FileDiffViewerCard({
    super.key,
    required this.event,
  });

  final FileDiffEvent event;

  @override
  Widget build(BuildContext context) {
    final diffLines = event.diff.computeUnifiedDiff().split('\n');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.blueGrey.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.difference_outlined, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '파일 변경 Diff: ${event.diff.filePath}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: BackendModelBadge(
                    backend: event.backend,
                    model: event.model,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF14161F),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final line in diffLines)
                    Container(
                      color: line.startsWith('+') && !line.startsWith('+++')
                          ? Colors.green.withValues(alpha: 0.18)
                          : (line.startsWith('-') && !line.startsWith('---')
                                ? Colors.red.withValues(alpha: 0.18)
                                : Colors.transparent),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      child: SelectableText(
                        line,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11.5,
                          color: line.startsWith('+') && !line.startsWith('+++')
                              ? Colors.greenAccent
                              : (line.startsWith('-') && !line.startsWith('---')
                                    ? Colors.redAccent
                                    : Colors.white70),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 스킬 호출 표시 배너
class SkillInvokedBanner extends StatelessWidget {
  const SkillInvokedBanner({
    super.key,
    required this.event,
  });

  final SkillInvokedEvent event;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.deepPurple.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.auto_awesome,
            size: 16,
            color: Colors.deepPurpleAccent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '스킬 호출됨: ${event.skillName}${event.reason.isNotEmpty ? " (${event.reason})" : ""}',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          BackendModelBadge(backend: event.backend, model: event.model),
        ],
      ),
    );
  }
}
