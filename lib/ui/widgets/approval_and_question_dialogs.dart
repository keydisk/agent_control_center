import 'package:flutter/material.dart';

import '../../core/models/agent_models.dart';
import 'timeline_widgets.dart';

/// 모든 백엔드(Antigravity / Claude Code / Codex) 공통 승인 요청 다이얼로그.
/// - 일반 권한: "이번만 허용 / 이 세션 동안 허용 / 항상 허용 / 거부" 제공
/// - 파괴적 작업(삭제, 강제 푸시, 메일 발송, 전체 쿠키 삭제 등): "항상 허용" 옵션 없이 매번 확인
class UnifiedApprovalDialog extends StatelessWidget {
  const UnifiedApprovalDialog({
    super.key,
    required this.request,
    required this.onDecision,
  });

  final ApprovalRequestData request;
  final ValueChanged<ApprovalDecision> onDecision;

  @override
  Widget build(BuildContext context) {
    final isDestructive =
        request.isDestructive ||
        request.category == ApprovalCategory.destructive;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            isDestructive
                ? Icons.warning_amber_rounded
                : Icons.verified_user_outlined,
            color: isDestructive ? Colors.redAccent : Colors.amberAccent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isDestructive ? '파괴적 작업 승인 확인' : '에이전트 권한 승인 요청',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          BackendModelBadge(backend: request.backend),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isDestructive)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.redAccent),
                  ),
                  child: const Text(
                    '⚠️ 이 작업은 파일 삭제, 강제 푸시, 외부 발송 등 되돌릴 수 없는 변경을 포함하므로 "항상 허용"할 수 없으며 매번 확인합니다.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              _InfoRow(label: '권한 분류', value: request.category.label),
              _InfoRow(label: '도구 / 기능', value: request.toolName),
              if (request.targetResource.isNotEmpty)
                _InfoRow(label: '대상 리소스', value: request.targetResource),
              _InfoRow(label: '요청 목적', value: request.reason),
              const SizedBox(height: 10),
              const Text(
                '실행 인자 상세:',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  request.formattedArguments,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('approval_btn_deny'),
          onPressed: () => onDecision(
            ApprovalDecision(
              requestId: request.id,
              approved: false,
              scope: ApprovalScope.denied,
              reason: '사용자가 권한 요청을 거부했습니다.',
            ),
          ),
          child: const Text('거부', style: TextStyle(color: Colors.redAccent)),
        ),
        OutlinedButton(
          key: const ValueKey('approval_btn_once'),
          onPressed: () => onDecision(
            ApprovalDecision(
              requestId: request.id,
              approved: true,
              scope: ApprovalScope.once,
            ),
          ),
          child: const Text('이번만 허용'),
        ),
        if (!isDestructive) ...[
          FilledButton.tonal(
            key: const ValueKey('approval_btn_session'),
            onPressed: () => onDecision(
              ApprovalDecision(
                requestId: request.id,
                approved: true,
                scope: ApprovalScope.session,
              ),
            ),
            child: const Text('이 세션 동안 허용'),
          ),
          FilledButton(
            key: const ValueKey('approval_btn_always'),
            onPressed: () => onDecision(
              ApprovalDecision(
                requestId: request.id,
                approved: true,
                scope: ApprovalScope.always,
              ),
            ),
            child: const Text('항상 허용'),
          ),
        ],
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.white70,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// 에이전트의 질문/선택지를 다이얼로그·버튼·폼으로 표시하고 답을 백엔드에 전달하는 위젯
class AgentQuestionDialog extends StatefulWidget {
  const AgentQuestionDialog({
    super.key,
    required this.request,
    required this.onSubmitAnswers,
  });

  final QuestionRequestData request;
  final void Function(Map<String, List<String>> answers) onSubmitAnswers;

  @override
  State<AgentQuestionDialog> createState() => _AgentQuestionDialogState();
}

class _AgentQuestionDialogState extends State<AgentQuestionDialog> {
  final Map<String, Set<String>> _selectedOptions = {};
  final Map<String, TextEditingController> _customControllers = {};

  @override
  void initState() {
    super.initState();
    for (final q in widget.request.questions) {
      _selectedOptions[q.id] = <String>{
        if (q.options.isNotEmpty) q.options.first.label,
      };
      _customControllers[q.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final ctrl in _customControllers.values) {
      ctrl.dispose();
    }
    super.dispose();
  }

  void _handleSubmit() {
    final result = <String, List<String>>{};
    for (final q in widget.request.questions) {
      final selected = List<String>.from(_selectedOptions[q.id] ?? const {});
      final customText = _customControllers[q.id]?.text.trim() ?? '';
      if (customText.isNotEmpty) {
        selected.add(customText);
      }
      result[q.id] = selected;
    }
    widget.onSubmitAnswers(result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.quiz_outlined, color: Colors.lightBlueAccent),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '에이전트 질문 응답',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          BackendModelBadge(backend: widget.request.backend),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final q in widget.request.questions) ...[
                Text(
                  q.question,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                if (q.options.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final opt in q.options)
                        FilterChip(
                          key: ValueKey('q_opt_${q.id}_${opt.label}'),
                          label: Text(opt.label),
                          selected:
                              _selectedOptions[q.id]?.contains(opt.label) ??
                              false,
                          onSelected: (checked) {
                            setState(() {
                              final set = _selectedOptions.putIfAbsent(
                                q.id,
                                () => <String>{},
                              );
                              if (q.isMultiSelect) {
                                if (checked) {
                                  set.add(opt.label);
                                } else {
                                  set.remove(opt.label);
                                }
                              } else {
                                set
                                  ..clear()
                                  ..add(opt.label);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                TextField(
                  key: ValueKey('q_custom_${q.id}'),
                  controller: _customControllers[q.id],
                  obscureText: q.isSecret,
                  decoration: InputDecoration(
                    labelText: q.options.isEmpty ? '답변 입력' : '직접 입력 (선택 사항)',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
        FilledButton(
          key: const ValueKey('question_submit_btn'),
          onPressed: _handleSubmit,
          child: const Text('답변 전달'),
        ),
      ],
    );
  }
}
