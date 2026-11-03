import 'dart:convert';

import '../../core/models/agent_models.dart';

/// Claude Code (`claude -p --output-format stream-json --verbose`) 이벤트 파서
class ClaudeCodeEventParser {
  ClaudeCodeEventParser({required this.sessionId, this.model = ''});

  final String sessionId;
  String model;
  String? remoteSessionId;
  int _counter = 0;
  final Map<String, ToolCallEvent> _inFlightTools = {};
  String? _streamingMessageId;
  final Set<String> _streamedMessageIds = {};

  String _nextId(String prefix) => '${prefix}_${sessionId}_${++_counter}';

  /// `--include-partial-messages`의 토큰 단위 델타를 실시간 메시지로 변환합니다.
  List<AgentEvent> _parseStreamEvent(Map event, String raw, DateTime now) {
    final eventType = event['type'];
    if (eventType == 'message_start' && event['message'] is Map) {
      _streamingMessageId = (event['message'] as Map)['id']?.toString();
      return const [];
    }
    final id = _streamingMessageId;
    final delta = event['delta'];
    if (eventType != 'content_block_delta' || delta is! Map || id == null) {
      return const [];
    }
    final text = delta['type'] == 'text_delta'
        ? (delta['text'] ?? '').toString()
        : '';
    final thinking = delta['type'] == 'thinking_delta'
        ? (delta['thinking'] ?? '').toString()
        : '';
    if (text.isEmpty && thinking.isEmpty) return const [];
    _streamedMessageIds.add(id);
    return [
      MessageEvent(
        id: id,
        sessionId: sessionId,
        backend: BackendType.claudeCode,
        model: model,
        timestamp: now,
        role: 'assistant',
        text: text,
        thinking: thinking,
        isDelta: true,
        rawLog: raw,
      ),
    ];
  }

  List<AgentEvent> parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('{')) {
      return const [];
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(trimmed) as Map<String, dynamic>;
    } catch (_) {
      return const [];
    }

    final type = (json['type'] ?? '').toString();
    final now = DateTime.now();
    remoteSessionId = (json['session_id'] ?? remoteSessionId)?.toString();

    if (type == 'stream_event' && json['event'] is Map) {
      return _parseStreamEvent(json['event'] as Map, trimmed, now);
    }

    if (type == 'system') {
      final subtype = (json['subtype'] ?? '').toString();
      if (subtype == 'init') {
        final initModel = (json['model'] ?? '').toString();
        if (initModel.isNotEmpty) {
          model = initModel;
        }
      }
      return const [];
    }

    // Claude Code stdio permission prompt (control_request / can_use_tool)
    if (type == 'control_request' && json['request'] is Map) {
      final reqId = (json['request_id'] ?? _nextId('ctrl')).toString();
      final req = Map<String, dynamic>.from(json['request'] as Map);
      final subtype = (req['subtype'] ?? '').toString();
      if (subtype == 'can_use_tool') {
        final toolName = (req['tool_name'] ?? 'tool').toString();
        final rawInput = req['input'];
        final args = rawInput is Map
            ? Map<String, dynamic>.from(rawInput)
            : <String, dynamic>{};

        if (toolName == 'AskUserQuestion' && args['questions'] is List) {
          final qItems = <AgentQuestionItem>[];
          final rawQs = args['questions'] as List;
          for (var i = 0; i < rawQs.length; i++) {
            final q = rawQs[i];
            if (q is Map) {
              final opts = <QuestionOption>[];
              if (q['options'] is List) {
                for (final o in q['options'] as List) {
                  if (o is Map) {
                    opts.add(
                      QuestionOption(
                        label: (o['label'] ?? '').toString(),
                        description: (o['description'] ?? '').toString(),
                      ),
                    );
                  } else {
                    opts.add(QuestionOption(label: o.toString()));
                  }
                }
              }
              qItems.add(
                AgentQuestionItem(
                  id: (q['header'] ?? 'q_$i').toString(),
                  header: (q['header'] ?? '질문').toString(),
                  question: (q['question'] ?? '').toString(),
                  options: opts,
                  isMultiSelect: q['multiSelect'] == true,
                ),
              );
            }
          }
          return [
            QuestionEvent(
              request: QuestionRequestData(
                id: reqId,
                sessionId: sessionId,
                backend: BackendType.claudeCode,
                questions: qItems,
                createdAt: now,
              ),
              model: model,
              rawLog: trimmed,
            ),
          ];
        }

        final isDestructive = ApprovalRequestData.detectDestructive(
          toolName,
          args,
        );
        return [
          ApprovalRequestEvent(
            request: ApprovalRequestData(
              id: reqId,
              sessionId: sessionId,
              backend: BackendType.claudeCode,
              toolName: toolName,
              arguments: args,
              category: ApprovalRequestData.classifyTool(toolName, args),
              reason:
                  (req['decision_reason'] ??
                          'Claude Code가 [$toolName] 도구 실행 승인을 요청했습니다.')
                      .toString(),
              isDestructive: isDestructive,
              createdAt: now,
              targetResource: ApprovalRequestData.extractTargetResource(
                toolName,
                args,
              ),
            ),
            model: model,
            rawLog: trimmed,
          ),
        ];
      }
      return const [];
    }

    if (type == 'assistant' && json['message'] is Map) {
      final msg = Map<String, dynamic>.from(json['message'] as Map);
      final msgModel = (msg['model'] ?? model).toString();
      if (msgModel.isNotEmpty) model = msgModel;
      final msgId = (msg['id'] ?? _nextId('claude_msg')).toString();
      final content = msg['content'];
      final events = <AgentEvent>[];

      if (content is List) {
        final textBuffer = StringBuffer();
        final thinkingBuffer = StringBuffer();

        for (final item in content) {
          if (item is! Map) continue;
          final blockType = (item['type'] ?? '').toString();
          if (blockType == 'text') {
            textBuffer.write((item['text'] ?? '').toString());
          } else if (blockType == 'thinking') {
            thinkingBuffer.write((item['thinking'] ?? '').toString());
          } else if (blockType == 'tool_use') {
            final toolId = (item['id'] ?? _nextId('tool')).toString();
            final toolName = (item['name'] ?? 'tool').toString();
            final input = item['input'] is Map
                ? Map<String, dynamic>.from(item['input'] as Map)
                : <String, dynamic>{};

            // Skill 호출 감지
            if (toolName == 'Skill') {
              final skillName = (input['skill'] ?? input['name'] ?? 'skill')
                  .toString();
              events.add(
                SkillInvokedEvent(
                  id: _nextId('skill'),
                  sessionId: sessionId,
                  backend: BackendType.claudeCode,
                  model: model,
                  timestamp: now,
                  skillName: skillName,
                  reason: 'Claude Skill 도구 호출',
                  rawLog: trimmed,
                ),
              );
            } else {
              final cmd = (input['command'] ?? '').toString();
              if (cmd.contains('ego-browser')) {
                events.add(
                  SkillInvokedEvent(
                    id: _nextId('skill'),
                    sessionId: sessionId,
                    backend: BackendType.claudeCode,
                    model: model,
                    timestamp: now,
                    skillName: 'ego-browser',
                    skillPath: cmd,
                    reason: 'Bash 도구를 통해 ego-browser 실행',
                    rawLog: trimmed,
                  ),
                );
              } else if (cmd.contains('cli-hub') ||
                  cmd.contains('cli-anything')) {
                events.add(
                  SkillInvokedEvent(
                    id: _nextId('skill'),
                    sessionId: sessionId,
                    backend: BackendType.claudeCode,
                    model: model,
                    timestamp: now,
                    skillName: 'cli-hub-meta-skill',
                    skillPath: cmd,
                    reason: 'Bash 도구를 통해 cli-hub 실행',
                    rawLog: trimmed,
                  ),
                );
              }
            }

            final toolEv = ToolCallEvent(
              id: toolId,
              sessionId: sessionId,
              backend: BackendType.claudeCode,
              model: model,
              timestamp: now,
              toolName: toolName,
              arguments: input,
              result: '실행 중...',
              isRunning: true,
              rawLog: trimmed,
            );
            _inFlightTools[toolId] = toolEv;
            events.add(toolEv);

            // Edit / Write 도구면 FileDiffEvent 생성
            if (toolName == 'Edit' || toolName == 'Write') {
              final filePath = (input['file_path'] ?? input['path'] ?? '')
                  .toString();
              if (filePath.isNotEmpty) {
                events.add(
                  FileDiffEvent(
                    id: _nextId('diff'),
                    sessionId: sessionId,
                    backend: BackendType.claudeCode,
                    model: model,
                    timestamp: now,
                    diff: FileDiffItem(
                      filePath: filePath,
                      oldContent: (input['old_string'] ?? '').toString(),
                      newContent:
                          (input['new_string'] ?? input['content'] ?? '')
                              .toString(),
                    ),
                    rawLog: trimmed,
                  ),
                );
              }
            }
          }
        }

        // 델타로 이미 표시한 메시지는 최종본을 다시 추가하지 않습니다.
        if ((textBuffer.isNotEmpty || thinkingBuffer.isNotEmpty) &&
            !_streamedMessageIds.contains(msgId)) {
          events.insert(
            0,
            MessageEvent(
              id: msgId,
              sessionId: sessionId,
              backend: BackendType.claudeCode,
              model: model,
              timestamp: now,
              role: 'assistant',
              text: textBuffer.toString(),
              thinking: thinkingBuffer.toString(),
              rawLog: trimmed,
            ),
          );
        }
      }
      return events;
    }

    if (type == 'user' && json['message'] is Map) {
      final msg = Map<String, dynamic>.from(json['message'] as Map);
      final content = msg['content'];
      final events = <AgentEvent>[];
      if (content is List) {
        for (final item in content) {
          if (item is Map && item['type'] == 'tool_result') {
            final toolUseId = (item['tool_use_id'] ?? '').toString();
            final isErr = item['is_error'] == true;
            final rawContent = item['content'];
            final resContent = rawContent is List
                ? rawContent
                      .whereType<Map>()
                      .map((block) => (block['text'] ?? '').toString())
                      .join('\n')
                : (rawContent ?? '').toString();
            final prev = _inFlightTools[toolUseId];
            if (prev != null) {
              final updated = prev.copyWith(
                result: resContent.isNotEmpty ? resContent : '완료',
                isRunning: false,
                isError: isErr,
              );
              _inFlightTools.remove(toolUseId);
              events.add(updated);
            }
          }
        }
      }
      return events;
    }

    if (type == 'result') {
      final isError = json['is_error'] == true;
      final durationMs = (json['duration_ms'] as num?)?.toInt() ?? 0;
      final costUsd = (json['total_cost_usd'] as num?)?.toDouble() ?? 0.0;
      final stopReason = (json['stop_reason'] ?? json['subtype'] ?? 'completed')
          .toString();

      TokenUsage usage = TokenUsage(costUsd: costUsd);
      if (json['usage'] is Map) {
        final u = Map<String, dynamic>.from(json['usage'] as Map);
        final inTok = (u['input_tokens'] as num?)?.toInt() ?? 0;
        final outTok = (u['output_tokens'] as num?)?.toInt() ?? 0;
        final cacheRead = (u['cache_read_input_tokens'] as num?)?.toInt() ?? 0;
        final cacheCreate =
            (u['cache_creation_input_tokens'] as num?)?.toInt() ?? 0;
        usage = TokenUsage(
          inputTokens: inTok + cacheCreate,
          outputTokens: outTok,
          cachedTokens: cacheRead,
          totalTokens: inTok + outTok + cacheRead + cacheCreate,
          costUsd: costUsd,
        );
      }

      final events = <AgentEvent>[];
      if (isError) {
        events.add(
          ErrorEvent(
            id: _nextId('err'),
            sessionId: sessionId,
            backend: BackendType.claudeCode,
            model: model,
            timestamp: now,
            message: (json['result'] ?? 'Claude Code 실행 오류').toString(),
            code: stopReason,
            isFatal: true,
            rawLog: trimmed,
          ),
        );
      }
      events.add(
        DoneEvent(
          id: _nextId('done'),
          sessionId: sessionId,
          backend: BackendType.claudeCode,
          model: model,
          timestamp: now,
          conversationId: remoteSessionId ?? '',
          usage: usage,
          durationMs: durationMs,
          stopReason: stopReason,
          rawLog: trimmed,
        ),
      );
      return events;
    }

    return const [];
  }
}
