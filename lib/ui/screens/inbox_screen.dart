import 'package:flutter/material.dart';

import '../../services/inbox_service.dart';
import '../../services/notification_service.dart';
import '../widgets/timeline_widgets.dart';

class InboxSummaryDialog extends StatefulWidget {
  const InboxSummaryDialog({
    super.key,
    required this.inboxService,
    required this.notificationService,
    this.initialSummaryId,
  });

  final InboxService inboxService;
  final NotificationService notificationService;
  final String? initialSummaryId;

  @override
  State<InboxSummaryDialog> createState() => _InboxSummaryDialogState();
}

class _InboxSummaryDialogState extends State<InboxSummaryDialog> {
  bool _showMobileRelaySpec = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialSummaryId != null &&
        widget.initialSummaryId!.isNotEmpty &&
        widget.inboxService.selectedSummaryId != widget.initialSummaryId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.inboxService.selectSummary(widget.initialSummaryId!);
        }
      });
    }
    widget.inboxService.addListener(_onChanged);
    widget.notificationService.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.inboxService.removeListener(_onChanged);
    widget.notificationService.removeListener(_onChanged);
    super.dispose();
  }

  Color _urgencyColor(UrgencyLevel urgency) {
    switch (urgency) {
      case UrgencyLevel.low:
        return Colors.blueGrey;
      case UrgencyLevel.medium:
        return Colors.lightBlueAccent;
      case UrgencyLevel.high:
        return Colors.orangeAccent;
      case UrgencyLevel.critical:
        return Colors.redAccent;
    }
  }

  Future<void> _simulateIncomingMessage(InboxSourceType source) async {
    await widget.inboxService.ingestAndSummarize(
      InboxMessageRaw(
        id: 'demo_${DateTime.now().millisecondsSinceEpoch}',
        source: source,
        sender: source == InboxSourceType.gmail
            ? 'security-team@company.com'
            : (source == InboxSourceType.slack
                  ? '@devops-lead'
                  : '팀장님 (iMessage)'),
        subject: '[긴급] 프로덕션 배포 승인 요청 및 보안 점검 안내',
        body:
            '주영님, 오늘 오후 5시 프로덕션 릴리즈 전에 권한 센터 감사 로그 검토와 최종 배포 승인이 필요합니다. '
            '첨부된 체크리스트를 확인하신 후 회신 부탁드립니다. (이 뒷부분은 원문 전송 제한 설정에 따라 외부 모델 전송 시 절삭될 수 있습니다.)',
        receivedAt: DateTime.now(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final summaries = widget.inboxService.summaries;
    final selected = widget.inboxService.selectedSummary;
    final backend = widget.inboxService.summaryBackend;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.mark_email_unread_outlined, color: Colors.tealAccent),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Inbox 요약 센터 & 알림 (Gmail / Slack / Mail / iMessage)'),
          ),
          FilterChip(
            key: const ValueKey('toggle_mobile_relay_spec'),
            label: const Text('모바일 원격 알림(FCM/APNs) 설계안'),
            selected: _showMobileRelaySpec,
            onSelected: (v) {
              setState(() {
                _showMobileRelaySpec = v;
              });
            },
          ),
        ],
      ),
      content: SizedBox(
        width: 860,
        height: 540,
        child: _showMobileRelaySpec
            ? SingleChildScrollView(
                key: const ValueKey('mobile_relay_spec_view'),
                child: MarkdownMessageView(
                  markdown: NotificationService.mobileRelayArchitectureDoc,
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 요약 모델 및 외부 전송 범위 설정 바
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text(
                          '백그라운드 요약 전담:',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        BackendModelBadge(
                          backend: backend,
                          model: widget.inboxService.summaryModel,
                        ),
                        const Text(
                          '외부 모델 원문 전송 범위:',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        DropdownButton<ContentForwardingPolicy>(
                          key: const ValueKey('forwarding_policy_dropdown'),
                          value: widget.inboxService.forwardingPolicy,
                          isDense: true,
                          items: [
                            for (final p in ContentForwardingPolicy.values)
                              DropdownMenuItem(
                                value: p,
                                child: Text(
                                  p.label,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                          onChanged: (p) {
                            if (p != null) {
                              widget.inboxService.updateForwardingPolicy(p);
                            }
                          },
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '실시간 자동 감지:',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Switch(
                              key: const ValueKey('inbox_auto_watch_switch'),
                              value: widget.inboxService.isAutoMonitoring,
                              onChanged: (val) {
                                if (val) {
                                  widget.inboxService.startAutoMonitoring();
                                } else {
                                  widget.inboxService.stopAutoMonitoring();
                                }
                              },
                            ),
                            OutlinedButton.icon(
                              key: const ValueKey('inbox_poll_now_button'),
                              onPressed: () => widget.inboxService
                                  .pollAllAuthorizedSourcesOnce(),
                              icon: const Icon(Icons.radar, size: 15),
                              label: const Text(
                                '지금 스캔',
                                style: TextStyle(fontSize: 11.5),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // 지원 소스 및 카카오톡 불가 안내 바
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      FilledButton.tonalIcon(
                        key: const ValueKey('simulate_gmail_button'),
                        onPressed: () =>
                            _simulateIncomingMessage(InboxSourceType.gmail),
                        icon: const Icon(Icons.email_outlined, size: 15),
                        label: const Text('Gmail 수신 요약 테스트'),
                      ),
                      FilledButton.tonalIcon(
                        key: const ValueKey('simulate_slack_button'),
                        onPressed: () =>
                            _simulateIncomingMessage(InboxSourceType.slack),
                        icon: const Icon(Icons.chat_bubble_outline, size: 15),
                        label: const Text('Slack 수신 요약 테스트'),
                      ),
                      FilledButton.tonalIcon(
                        key: const ValueKey('simulate_imessage_button'),
                        onPressed: () =>
                            _simulateIncomingMessage(InboxSourceType.imessage),
                        icon: const Icon(Icons.sms_outlined, size: 15),
                        label: const Text('iMessage 수신 요약 테스트'),
                      ),
                      Chip(
                        key: const ValueKey('kakaotalk_unsupported_chip'),
                        avatar: const Icon(
                          Icons.block,
                          size: 15,
                          color: Colors.redAccent,
                        ),
                        label: Text(
                          InboxSourceType.kakaoTalk.supportNote,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // 좌측 요약 목록 + 우측 상세 뷰 (딥링크 타겟)
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: summaries.isEmpty
                              ? const Center(
                                  child: Text(
                                    '수신된 요약 항목이 없습니다.',
                                    style: TextStyle(color: Colors.white60),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: summaries.length,
                                  itemBuilder: (context, index) {
                                    final item = summaries[index];
                                    final isSelected =
                                        selected?.id == item.id;
                                    final uColor = _urgencyColor(item.urgency);
                                    return Card(
                                      key: ValueKey('inbox_item_${item.id}'),
                                      color: isSelected
                                          ? Theme.of(context)
                                                .colorScheme
                                                .primaryContainer
                                                .withValues(alpha: 0.35)
                                          : null,
                                      child: ListTile(
                                        onTap: () => widget.inboxService
                                            .selectSummary(item.id),
                                        title: Text(
                                          item.subject,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        subtitle: Text(
                                          '${item.source.label} · ${item.sender}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                        trailing: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: uColor.withValues(alpha: 0.2),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Text(
                                            item.urgency.label,
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.bold,
                                              color: uColor,
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: selected == null
                              ? const Center(
                                  child: Text(
                                    '좌측에서 메일·메시지 요약을 선택하세요.',
                                    style: TextStyle(color: Colors.white60),
                                  ),
                                )
                              : Container(
                                  key: ValueKey(
                                    'inbox_detail_${selected.id}',
                                  ),
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: SingleChildScrollView(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                selected.subject,
                                                style: const TextStyle(
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ),
                                            BackendModelBadge(
                                              backend:
                                                  selected.summarizedByBackend,
                                              model: selected.summarizedByModel,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          '발신자: ${selected.sender} (${selected.source.label}) · 긴급도: ${selected.urgency.label}',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.white70,
                                          ),
                                        ),
                                        const Divider(height: 18),
                                        const Text(
                                          '핵심 3줄 요약:',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 13,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        for (final line
                                            in selected.threeLineSummary)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 4,
                                            ),
                                            child: Text(
                                              line,
                                              style: const TextStyle(
                                                fontSize: 12.5,
                                              ),
                                            ),
                                          ),
                                        const SizedBox(height: 10),
                                        Container(
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(
                                            color: Colors.amber.withValues(
                                              alpha: 0.14,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              const Icon(
                                                Icons.task_alt,
                                                size: 16,
                                                color: Colors.amberAccent,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  '필요한 액션: ${selected.requiredAction}',
                                                  style: const TextStyle(
                                                    fontSize: 12.5,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        const Text(
                                          '외부 요약 모델에 전달된 페이로드 (프라이버시 필터 적용됨):',
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white70,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: Colors.black26,
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                          ),
                                          child: SelectableText(
                                            selected.forwardedSnippet,
                                            style: const TextStyle(
                                              fontFamily: 'monospace',
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
