import 'dart:convert';

import '../../core/models/agent_models.dart';

/// Google Antigravity CLI (`agy --output-format stream-json`) NDJSON 이벤트 파서
class AntigravityEventParser {
  AntigravityEventParser({required this.sessionId, this.model = ''});

  /// 헤드리스 모드가 자동 거부한 명령의 승인 요청 ID 접두어
  static const deniedRequestPrefix = 'agy_denied_';

  final String sessionId;
  String model;
  String? conversationId;
  int _counter = 0;
  bool _askedApprovalForDenial = false;
  final Map<String, Map<String, dynamic>> _unfinishedCommands = {};
  (String, Map<String, dynamic>)? _lastMcpCall;

  /// 자동 거부된 승인 요청별로 `permissions.allow`에 넣을 규칙
  final Map<String, String> deniedRules = {};

  static String? _ruleForDenial(
    String toolName,
    Map<String, dynamic> args,
    String error,
  ) {
    if (!error.contains('denied permission')) return null;
    final named = RegExp(
      r'denied permission for (\w+\(.+\))\s*$',
      multiLine: true,
    ).firstMatch(error);
    if (named != null) return named.group(1);
    final command = args['CommandLine'];
    return toolName == 'run_command' && command is String
        ? 'command($command)'
        : null;
  }

  String _nextId(String prefix) => '${prefix}_${sessionId}_${++_counter}';

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

    final eventType = (json['event'] ?? '').toString();
    final now = DateTime.now();

    if (eventType == 'init') {
      conversationId = (json['conversation_id'] ?? conversationId)?.toString();
      return const [];
    }

    if (eventType == 'step_update' && json['step_update'] is Map) {
      final step = Map<String, dynamic>.from(json['step_update'] as Map);
      conversationId = (step['conversation_id'] ?? conversationId)?.toString();
      final stepIdx = step['step_index'] ?? _counter;
      final state = (step['state'] ?? '').toString(); // ACTIVE | DONE | WAITING
      final stepType = (step['step_type'] ?? '').toString();
      final textDelta = (step['text_delta'] ?? '').toString();
      final thinking = (step['thinking'] ?? '').toString();
      final durationSec = (step['duration_seconds'] as num?)?.toDouble() ?? 0.0;
      final durationMs = (durationSec * 1000).round();

      final events = <AgentEvent>[];

      // 1. 스킬 호출 감지 (skill_used 필드 또는 SKILL.md 조회)
      if (step['skill_used'] != null) {
        final skillRaw = step['skill_used'];
        final skillName = skillRaw is Map
            ? (skillRaw['name'] ?? skillRaw['skill_name'] ?? 'skill').toString()
            : skillRaw.toString();
        events.add(
          SkillInvokedEvent(
            id: _nextId('skill'),
            sessionId: sessionId,
            backend: BackendType.antigravity,
            model: model,
            timestamp: now,
            skillName: skillName,
            rawLog: trimmed,
          ),
        );
      }

      // 2. 사용자 입력과 내부 시스템 메시지 단계는 타임라인에 표시하지 않음
      if (stepType == 'user_input' || stepType == 'system_message') {
        return events;
      }

      // 3. 에이전트 텍스트 응답 스트리밍
      if (stepType == 'agent_response') {
        if (textDelta.isNotEmpty || thinking.isNotEmpty) {
          events.add(
            MessageEvent(
              id: 'agy_msg_$stepIdx',
              sessionId: sessionId,
              backend: BackendType.antigravity,
              model: model,
              timestamp: now,
              role: 'assistant',
              text: textDelta,
              thinking: thinking,
              isDelta: true,
              rawLog: trimmed,
            ),
          );
        }
        return events;
      }

      // 4. 도구 정보 추출
      Map<String, dynamic> toolArgs = {};
      String toolOutput = '';
      String toolError = (step['error'] ?? '').toString();
      String toolName = (step['tool_name'] ?? stepType).toString();
      if (step['tool_info'] is Map) {
        final info = Map<String, dynamic>.from(step['tool_info'] as Map);
        toolName = (info['name'] ?? info['tool_name'] ?? toolName).toString();
        if (info['parameters'] is Map) {
          toolArgs = Map<String, dynamic>.from(info['parameters'] as Map);
        } else if (info['args'] is Map) {
          toolArgs = Map<String, dynamic>.from(info['args'] as Map);
        }
        toolOutput = (info['output'] ?? info['result'] ?? '').toString();
        final infoError = info['error'];
        if (infoError != null) {
          toolError = infoError is Map
              ? (infoError['message'] ?? infoError).toString()
              : infoError.toString();
        }
      } else if (step['args'] is Map) {
        toolArgs = Map<String, dynamic>.from(step['args'] as Map);
      }

      final commandId = '$deniedRequestPrefix$stepIdx';
      if (toolName == 'run_command') {
        // 자동 거부도 결과 없는 DONE으로 오므로 최종 거부 결과까지 명령을 보관합니다.
        if (toolArgs['CommandLine'] is! String &&
            _unfinishedCommands.containsKey(commandId)) {
          toolArgs = _unfinishedCommands[commandId]!;
        }
        if ((state == 'DONE' && toolOutput.isNotEmpty) ||
            toolError.isNotEmpty) {
          _unfinishedCommands.remove(commandId);
        } else if (toolArgs['CommandLine'] is String) {
          _unfinishedCommands[commandId] = Map.of(toolArgs);
        }
      }

      // MCP 거부는 오류 없이 턴을 끝내므로 마지막 호출이 거부 대상입니다.
      _lastMcpCall =
          toolName == 'call_mcp_tool' &&
              toolArgs['ServerName'] is String &&
              toolArgs['ToolName'] is String
          ? (commandId, toolArgs)
          : null;

      // 스킬 파일 읽기 또는 ego-browser / cli-hub 실행 시 SkillInvokedEvent 추가 발행
      final detectedSkill = _detectSkillFromTool(toolName, toolArgs);
      if (detectedSkill != null && state == 'ACTIVE') {
        events.add(
          SkillInvokedEvent(
            id: _nextId('skill'),
            sessionId: sessionId,
            backend: BackendType.antigravity,
            model: model,
            timestamp: now,
            skillName: detectedSkill.$1,
            skillPath: detectedSkill.$2,
            reason: '$toolName 도구를 통해 스킬 실행됨',
            rawLog: trimmed,
          ),
        );
      }

      // 5. 에이전트 질문(ask_question) 단계
      if (stepType == 'ask_question' || toolName == 'ask_question') {
        final questionsList = <AgentQuestionItem>[];
        final rawQuestions = toolArgs['questions'];
        if (rawQuestions is List) {
          for (var i = 0; i < rawQuestions.length; i++) {
            final q = rawQuestions[i];
            if (q is Map) {
              final opts = <QuestionOption>[];
              if (q['options'] is List) {
                for (final o in q['options'] as List) {
                  opts.add(QuestionOption(label: o.toString()));
                }
              }
              questionsList.add(
                AgentQuestionItem(
                  id: 'q_$i',
                  question: (q['question'] ?? '선택해 주세요.').toString(),
                  options: opts,
                  isMultiSelect: q['is_multi_select'] == true,
                ),
              );
            }
          }
        }
        if (questionsList.isNotEmpty && state != 'DONE') {
          events.add(
            QuestionEvent(
              request: QuestionRequestData(
                id: 'agy_q_$stepIdx',
                sessionId: sessionId,
                backend: BackendType.antigravity,
                questions: questionsList,
                createdAt: now,
              ),
              model: model,
              rawLog: trimmed,
            ),
          );
          return events;
        }
      }

      // 6. 승인 대기(WAITING / ask_permission) 감지
      if (state == 'WAITING' ||
          stepType == 'ask_permission' ||
          stepType == 'ask_custom_permission') {
        final isDestructive = ApprovalRequestData.detectDestructive(
          toolName,
          toolArgs,
        );
        events.add(
          ApprovalRequestEvent(
            request: ApprovalRequestData(
              id: 'agy_perm_$stepIdx',
              sessionId: sessionId,
              backend: BackendType.antigravity,
              toolName: toolName,
              arguments: toolArgs,
              category: ApprovalRequestData.classifyTool(toolName, toolArgs),
              reason: 'Antigravity 에이전트가 [$toolName] 실행 승인을 요청했습니다.',
              isDestructive: isDestructive,
              createdAt: now,
              targetResource: ApprovalRequestData.extractTargetResource(
                toolName,
                toolArgs,
              ),
            ),
            model: model,
            rawLog: trimmed,
          ),
        );
        return events;
      }

      // 7. 일반 도구 호출 카드 이벤트
      final isError = state == 'ERROR' || toolError.isNotEmpty;
      events.add(
        ToolCallEvent(
          id: 'agy_tool_$stepIdx',
          sessionId: sessionId,
          backend: BackendType.antigravity,
          model: model,
          timestamp: now,
          toolName: toolName,
          arguments: toolArgs,
          result: toolOutput.isNotEmpty
              ? toolOutput
              : isError
              ? (toolError.isNotEmpty ? toolError : '실패')
              : (state == 'DONE' ? '실행 완료' : '실행 중...'),
          isRunning: state == 'ACTIVE',
          isError: isError,
          durationMs: durationMs,
          rawLog: trimmed,
        ),
      );

      // 헤드리스 모드는 권한을 묻지 못하고 거부하므로 앱에서 대신 묻습니다.
      final deniedRule = _ruleForDenial(toolName, toolArgs, toolError);
      if (deniedRule != null) {
        _unfinishedCommands.remove(commandId);
        events.add(
          _approvalForDenial(
            commandId,
            toolName,
            toolArgs,
            deniedRule,
            trimmed,
          ),
        );
      }

      // 8. 파일 변경 Diff 이벤트 추출
      if (step['file_diffs'] is List) {
        for (final rawDiff in step['file_diffs'] as List) {
          if (rawDiff is Map) {
            events.add(
              FileDiffEvent(
                id: _nextId('diff'),
                sessionId: sessionId,
                backend: BackendType.antigravity,
                model: model,
                timestamp: now,
                diff: FileDiffItem(
                  filePath: (rawDiff['path'] ?? rawDiff['file_path'] ?? 'file')
                      .toString(),
                  oldContent: (rawDiff['old_content'] ?? '').toString(),
                  newContent: (rawDiff['new_content'] ?? '').toString(),
                  unifiedDiff: (rawDiff['diff'] ?? rawDiff['patch'] ?? '')
                      .toString(),
                ),
                rawLog: trimmed,
              ),
            );
          }
        }
      } else if (state == 'DONE' &&
          (toolName == 'edit_file' ||
              toolName == 'write_file' ||
              toolName == 'write_to_file' ||
              toolName == 'replace_file_content')) {
        final path =
            (toolArgs['Path'] ??
                    toolArgs['TargetFile'] ??
                    toolArgs['file_path'] ??
                    '')
                .toString();
        if (path.isNotEmpty) {
          events.add(
            FileDiffEvent(
              id: _nextId('diff'),
              sessionId: sessionId,
              backend: BackendType.antigravity,
              model: model,
              timestamp: now,
              diff: FileDiffItem(
                filePath: path,
                oldContent: (toolArgs['Target'] ?? '').toString(),
                newContent:
                    (toolArgs['Replacement'] ?? toolArgs['Content'] ?? '')
                        .toString(),
              ),
              rawLog: trimmed,
            ),
          );
        }
      }

      return events;
    }

    if (eventType == 'result' && json['result'] is Map) {
      final res = Map<String, dynamic>.from(json['result'] as Map);
      conversationId = (res['conversation_id'] ?? conversationId)?.toString();
      final status = (res['status'] ?? 'SUCCESS').toString();
      final errorMsg = (res['error'] ?? '').toString();
      final durationSec = (res['duration_seconds'] as num?)?.toDouble() ?? 0.0;
      final finishedReason = (res['finished_reason'] ?? 'completed').toString();

      TokenUsage usage = const TokenUsage();
      if (res['usage'] is Map) {
        final u = Map<String, dynamic>.from(res['usage'] as Map);
        final inTok = (u['input_tokens'] as num?)?.toInt() ?? 0;
        final cachedTok = (u['cache_read_tokens'] as num?)?.toInt() ?? 0;
        usage = TokenUsage(
          inputTokens: inTok,
          outputTokens: (u['output_tokens'] as num?)?.toInt() ?? 0,
          thinkingTokens: (u['thinking_tokens'] as num?)?.toInt() ?? 0,
          cachedTokens: cachedTok,
          // ponytail: Gemini처럼 입력에 캐시가 포함된다고 가정합니다. 실제 캐시 적중 로그로 확인되면 조정합니다.
          promptTokens: inTok > cachedTok ? inTok : cachedTok,
          totalTokens: (u['total_tokens'] as num?)?.toInt() ?? 0,
        );
      }

      final events = <AgentEvent>[];
      final denied = res['denied_actions'];
      if (denied is List &&
          denied.any(
            (action) => action is Map && action['action'] == 'command',
          )) {
        for (final entry in _unfinishedCommands.entries) {
          events.add(
            _approvalForDenial(
              entry.key,
              'run_command',
              entry.value,
              'command(${entry.value['CommandLine']})',
              trimmed,
            ),
          );
        }
      }
      _unfinishedCommands.clear();
      final mcpCall = _lastMcpCall;
      if (mcpCall != null &&
          denied is List &&
          denied.any((action) => action is Map && action['action'] == 'mcp')) {
        final (id, args) = mcpCall;
        events.add(
          _approvalForDenial(
            id,
            'call_mcp_tool',
            args,
            'mcp(${args['ServerName']}/${args['ToolName']})',
            trimmed,
          ),
        );
      }
      _lastMcpCall = null;
      // 구체적인 명령을 복원할 수 없는 거부는 이유를 직접 알립니다.
      if (denied is List && denied.isNotEmpty && !_askedApprovalForDenial) {
        final names = denied
            .map((d) => d is Map ? d['display_name'] ?? d['action'] : d)
            .join(', ');
        events.add(
          MessageEvent(
            id: _nextId('denied'),
            sessionId: sessionId,
            backend: BackendType.antigravity,
            model: model,
            timestamp: now,
            role: 'system',
            text: '권한이 거부되어 작업을 끝내지 못했습니다: $names. 원본 로그에서 거부된 도구를 확인해 주세요.',
            rawLog: trimmed,
          ),
        );
      }
      _askedApprovalForDenial = false;
      if (status == 'ERROR' || errorMsg.isNotEmpty) {
        events.add(
          ErrorEvent(
            id: _nextId('err'),
            sessionId: sessionId,
            backend: BackendType.antigravity,
            model: model,
            timestamp: now,
            message: errorMsg.isNotEmpty ? errorMsg : 'Antigravity 실행 오류',
            code: finishedReason,
            isFatal: true,
            rawLog: trimmed,
          ),
        );
      }
      events.add(
        DoneEvent(
          id: _nextId('done'),
          sessionId: sessionId,
          backend: BackendType.antigravity,
          model: model,
          timestamp: now,
          conversationId: conversationId ?? '',
          usage: usage,
          durationMs: (durationSec * 1000).round(),
          stopReason: finishedReason,
          rawLog: trimmed,
        ),
      );
      return events;
    }

    return const [];
  }

  ApprovalRequestEvent _approvalForDenial(
    String id,
    String toolName,
    Map<String, dynamic> toolArgs,
    String deniedRule,
    String rawLog,
  ) {
    _askedApprovalForDenial = true;
    deniedRules[id] = deniedRule;
    return ApprovalRequestEvent(
      request: ApprovalRequestData(
        id: id,
        sessionId: sessionId,
        backend: BackendType.antigravity,
        toolName: toolName,
        arguments: toolArgs,
        category: ApprovalRequestData.classifyTool(toolName, toolArgs),
        reason: 'Antigravity가 $deniedRule 권한을 요청했습니다. 승인하면 작업을 이어갑니다.',
        isDestructive: ApprovalRequestData.detectDestructive(
          toolName,
          toolArgs,
        ),
        createdAt: DateTime.now(),
        targetResource: ApprovalRequestData.extractTargetResource(
          toolName,
          toolArgs,
        ),
      ),
      model: model,
      rawLog: rawLog,
    );
  }

  (String, String)? _detectSkillFromTool(
    String toolName,
    Map<String, dynamic> args,
  ) {
    final path = (args['Path'] ?? args['file_path'] ?? '').toString();
    if (path.endsWith('SKILL.md')) {
      final parts = path.split('/');
      final skillName = parts.length >= 2
          ? parts[parts.length - 2]
          : 'custom-skill';
      return (skillName, path);
    }
    final cmd = (args['CommandLine'] ?? args['command'] ?? '').toString();
    if (cmd.contains('ego-browser')) {
      return ('ego-browser', cmd);
    }
    if (cmd.contains('cli-hub') || cmd.contains('cli-anything')) {
      return ('cli-hub-meta-skill', cmd);
    }
    return null;
  }
}
