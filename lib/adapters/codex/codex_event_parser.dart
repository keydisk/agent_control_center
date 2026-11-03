import 'dart:convert';

import '../../core/models/agent_models.dart';

/// OpenAI Codex CLI (`codex exec --json` 및 `codex app-server --listen stdio://`) 이벤트 파서
class CodexEventParser {
  CodexEventParser({
    required this.sessionId,
    this.model = '',
  });

  final String sessionId;
  String model;
  String? threadId;
  int _counter = 0;

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

    final now = DateTime.now();

    // 1. JSON-RPC 2.0 (codex app-server 프로토콜) 처리
    if (json.containsKey('method')) {
      final method = (json['method'] ?? '').toString();
      final rpcId = json['id']?.toString();
      final params = json['params'] is Map
          ? Map<String, dynamic>.from(json['params'] as Map)
          : <String, dynamic>{};

      // 명령 실행 승인 요청
      if (method == 'item/commandExecution/requestApproval' ||
          method == 'execCommandApproval') {
        final reqId = rpcId ?? _nextId('codex_perm');
        final cmd = (params['command'] ?? params['cmd'] ?? '').toString();
        final args = <String, dynamic>{
          'command': cmd,
          if (params['cwd'] != null) 'cwd': params['cwd'],
          if (params['reason'] != null) 'reason': params['reason'],
        };
        final isDestructive = ApprovalRequestData.detectDestructive(
          'commandExecution',
          args,
        );
        return [
          ApprovalRequestEvent(
            request: ApprovalRequestData(
              id: reqId,
              sessionId: sessionId,
              backend: BackendType.codex,
              toolName: 'commandExecution',
              arguments: args,
              category: ApprovalRequestData.classifyTool(
                'commandExecution',
                args,
              ),
              reason:
                  (params['reason'] ?? 'Codex 에이전트가 셸 명령 실행 승인을 요청했습니다.')
                      .toString(),
              isDestructive: isDestructive,
              createdAt: now,
              targetResource: ApprovalRequestData.extractTargetResource(
                'commandExecution',
                args,
              ),
            ),
            model: model,
            rawLog: trimmed,
          ),
        ];
      }

      // 파일 변경 승인 요청
      if (method == 'item/fileChange/requestApproval' ||
          method == 'applyPatchApproval') {
        final reqId = rpcId ?? _nextId('codex_patch');
        return [
          ApprovalRequestEvent(
            request: ApprovalRequestData(
              id: reqId,
              sessionId: sessionId,
              backend: BackendType.codex,
              toolName: 'fileChange',
              arguments: params,
              category: ApprovalCategory.fileWrite,
              reason:
                  (params['reason'] ?? 'Codex 에이전트가 파일 수정 승인을 요청했습니다.')
                      .toString(),
              isDestructive: false,
              createdAt: now,
              targetResource: (params['grantRoot'] ?? 'workspace').toString(),
            ),
            model: model,
            rawLog: trimmed,
          ),
        ];
      }

      // 사용자 질문 요청 (item/tool/requestUserInput)
      if (method == 'item/tool/requestUserInput') {
        final reqId = rpcId ?? _nextId('codex_q');
        final qList = <AgentQuestionItem>[];
        if (params['questions'] is List) {
          for (final q in params['questions'] as List) {
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
                  }
                }
              }
              qList.add(
                AgentQuestionItem(
                  id: (q['id'] ?? 'q').toString(),
                  header: (q['header'] ?? '질문').toString(),
                  question: (q['question'] ?? '').toString(),
                  options: opts,
                  isSecret: q['isSecret'] == true,
                ),
              );
            }
          }
        }
        return [
          QuestionEvent(
            request: QuestionRequestData(
              id: reqId,
              sessionId: sessionId,
              backend: BackendType.codex,
              questions: qList,
              createdAt: now,
            ),
            model: model,
            rawLog: trimmed,
          ),
        ];
      }
    }

    // 2. codex exec --json 이벤트 스트림 처리
    final type = (json['type'] ?? '').toString();
    if (type == 'thread.started') {
      threadId = (json['thread_id'] ?? threadId)?.toString();
      return const [];
    }

    if ((type == 'item.started' || type == 'item.completed') &&
        json['item'] is Map) {
      final item = Map<String, dynamic>.from(json['item'] as Map);
      final itemId = (item['id'] ?? _nextId('item')).toString();
      final itemType = (item['type'] ?? '').toString();
      final isCompleted = type == 'item.completed';
      final events = <AgentEvent>[];

      if (itemType == 'agent_message' && isCompleted) {
        final text = (item['text'] ?? '').toString();
        if (text.isNotEmpty) {
          events.add(
            MessageEvent(
              id: itemId,
              sessionId: sessionId,
              backend: BackendType.codex,
              model: model,
              timestamp: now,
              role: 'assistant',
              text: text,
              rawLog: trimmed,
            ),
          );
        }
        return events;
      }

      if (itemType == 'command_execution') {
        final cmd = (item['command'] ?? '').toString();
        final output = (item['aggregated_output'] ?? item['output'] ?? '')
            .toString();
        final exitCode = (item['exit_code'] as num?)?.toInt();

        if (!isCompleted && cmd.contains('ego-browser')) {
          events.add(
            SkillInvokedEvent(
              id: _nextId('skill'),
              sessionId: sessionId,
              backend: BackendType.codex,
              model: model,
              timestamp: now,
              skillName: 'ego-browser',
              skillPath: cmd,
              reason: 'Codex 명령 실행을 통해 ego-browser 호출',
              rawLog: trimmed,
            ),
          );
        } else if (!isCompleted &&
            (cmd.contains('cli-hub') || cmd.contains('cli-anything'))) {
          events.add(
            SkillInvokedEvent(
              id: _nextId('skill'),
              sessionId: sessionId,
              backend: BackendType.codex,
              model: model,
              timestamp: now,
              skillName: 'cli-hub-meta-skill',
              skillPath: cmd,
              reason: 'Codex 명령 실행을 통해 cli-hub 호출',
              rawLog: trimmed,
            ),
          );
        }

        events.add(
          ToolCallEvent(
            id: itemId,
            sessionId: sessionId,
            backend: BackendType.codex,
            model: model,
            timestamp: now,
            toolName: 'command_execution',
            arguments: {'command': cmd},
            result: output.isNotEmpty
                ? output
                : (isCompleted ? '종료 코드: ${exitCode ?? 0}' : '실행 중...'),
            isRunning: !isCompleted,
            isError: exitCode != null && exitCode != 0,
            rawLog: trimmed,
          ),
        );
        return events;
      }

      if (itemType == 'file_change' && isCompleted) {
        final changes = item['changes'];
        if (changes is List) {
          for (final ch in changes) {
            if (ch is Map) {
              events.add(
                FileDiffEvent(
                  id: _nextId('diff'),
                  sessionId: sessionId,
                  backend: BackendType.codex,
                  model: model,
                  timestamp: now,
                  diff: FileDiffItem(
                    filePath: (ch['path'] ?? 'file').toString(),
                    unifiedDiff: (ch['diff'] ?? ch['patch'] ?? '').toString(),
                  ),
                  rawLog: trimmed,
                ),
              );
            }
          }
        } else {
          events.add(
            FileDiffEvent(
              id: _nextId('diff'),
              sessionId: sessionId,
              backend: BackendType.codex,
              model: model,
              timestamp: now,
              diff: FileDiffItem(
                filePath: (item['path'] ?? 'file').toString(),
                unifiedDiff: (item['diff'] ?? '').toString(),
              ),
              rawLog: trimmed,
            ),
          );
        }
        return events;
      }

      if (itemType == 'error' && isCompleted) {
        final msg = (item['message'] ?? '').toString();
        // 스킬 설명 단축 경고나 메타데이터 폴백 경고는 치명적 에러가 아니므로 무시 가능
        if (msg.contains('Skill descriptions were shortened') ||
            msg.contains('Defaulting to fallback metadata')) {
          return const [];
        }
        events.add(
          ErrorEvent(
            id: itemId,
            sessionId: sessionId,
            backend: BackendType.codex,
            model: model,
            timestamp: now,
            message: msg,
            rawLog: trimmed,
          ),
        );
        return events;
      }
    }

    if (type == 'turn.completed') {
      TokenUsage usage = const TokenUsage();
      if (json['usage'] is Map) {
        final u = Map<String, dynamic>.from(json['usage'] as Map);
        final inTok = (u['input_tokens'] as num?)?.toInt() ?? 0;
        final cachedTok = (u['cached_input_tokens'] as num?)?.toInt() ?? 0;
        final outTok = (u['output_tokens'] as num?)?.toInt() ?? 0;
        final reasonTok = (u['reasoning_output_tokens'] as num?)?.toInt() ?? 0;
        usage = TokenUsage(
          inputTokens: inTok,
          outputTokens: outTok,
          thinkingTokens: reasonTok,
          cachedTokens: cachedTok,
          totalTokens: inTok + outTok,
        );
      }
      return [
        DoneEvent(
          id: _nextId('done'),
          sessionId: sessionId,
          backend: BackendType.codex,
          model: model,
          timestamp: now,
          conversationId: threadId ?? '',
          usage: usage,
          rawLog: trimmed,
        ),
      ];
    }

    if (type == 'turn.failed' || type == 'error') {
      final errObj = json['error'];
      final msg = errObj is Map
          ? (errObj['message'] ?? 'Codex 오류').toString()
          : (json['message'] ?? 'Codex 오류').toString();
      if (type == 'error') {
        return [
          ErrorEvent(
            id: _nextId('err'),
            sessionId: sessionId,
            backend: BackendType.codex,
            model: model,
            timestamp: now,
            message: msg,
            isFatal: true,
            rawLog: trimmed,
          ),
        ];
      }
      return [
        DoneEvent(
          id: _nextId('done'),
          sessionId: sessionId,
          backend: BackendType.codex,
          model: model,
          timestamp: now,
          conversationId: threadId ?? '',
          stopReason: 'failed',
          rawLog: trimmed,
        ),
      ];
    }

    return const [];
  }
}
