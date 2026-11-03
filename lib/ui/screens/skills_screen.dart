import 'package:flutter/material.dart';
import '../theme/mac_theme.dart';

import '../../services/skill_registry.dart';
import '../widgets/timeline_widgets.dart';

class SkillsManagementDialog extends StatefulWidget {
  const SkillsManagementDialog({
    super.key,
    required this.skillRegistry,
    required this.onInvokeSkill,
  });

  final SkillRegistry skillRegistry;
  final void Function(SkillDefinition skill, String taskPrompt) onInvokeSkill;

  @override
  State<SkillsManagementDialog> createState() => _SkillsManagementDialogState();
}

class _SkillsManagementDialogState extends State<SkillsManagementDialog> {
  String _syncStatusMessage = '';

  @override
  void initState() {
    super.initState();
    widget.skillRegistry.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.skillRegistry.removeListener(_onChanged);
    super.dispose();
  }

  Future<void> _handleSync() async {
    final count = await widget.skillRegistry.syncSkillsAcrossBackends();
    if (!mounted) return;
    setState(() {
      _syncStatusMessage =
          '3대 백엔드(agy, claude, codex) 스킬 폴더 동기화 완료 (신규 링크 $count건)';
    });
  }

  Future<void> _promptInvokeSkill(SkillDefinition skill) async {
    final ctrl = TextEditingController(
      text: skill.name == 'ego-browser'
          ? 'https://news.ycombinator.com 페이지를 열고 상위 헤드라인 3개를 요약해줘'
          : 'Blender용 CLI 하네스를 검색하고 정보를 알려줘',
    );
    final submitted = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${skill.name} 스킬 호출'),
        content: TextField(
          key: const ValueKey('invoke_skill_prompt_field'),
          controller: ctrl,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: '스킬로 수행할 작업 지시',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('confirm_invoke_skill_button'),
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('호출 실행'),
          ),
        ],
      ),
    );
    if (submitted != null && submitted.isNotEmpty && mounted) {
      widget.onInvokeSkill(skill, submitted);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final skills = widget.skillRegistry.skills;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.auto_awesome, color: context.mac.purple),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('스킬 관리 센터 (전 백엔드 공통 SKILL.md)'),
          ),
          FilledButton.tonalIcon(
            key: const ValueKey('sync_skills_button'),
            onPressed: _handleSync,
            icon: const Icon(Icons.sync, size: 16),
            label: const Text('백엔드 폴더 동기화'),
          ),
        ],
      ),
      content: SizedBox(
        width: 720,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: context.mac.purple.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '공통 스킬 자동 라우팅 규칙 (Antigravity / Claude Code / Codex 공통 적용)',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12.5,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    '• 웹 관련 작업(검색, 페이지 열기, 폼 입력, 스크래핑) → ego-browser 스킬\n'
                    '• 별도 소프트웨어/외부 CLI 실행이 필요한 작업 → cli-hub-meta-skill 스킬',
                    style: TextStyle(fontSize: 11.5, color: context.mac.secondaryLabel),
                  ),
                ],
              ),
            ),
            if (_syncStatusMessage.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                _syncStatusMessage,
                key: const ValueKey('sync_status_message'),
                style: TextStyle(
                  fontSize: 12,
                  color: context.mac.green,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: ListView.builder(
                itemCount: skills.length,
                itemBuilder: (context, index) {
                  final skill = skills[index];
                  return Card(
                    key: ValueKey('skill_card_${skill.name}'),
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  skill.name,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              Switch(
                                key: ValueKey('skill_toggle_${skill.name}'),
                                value: skill.isEnabled,
                                onChanged: (val) => widget.skillRegistry
                                    .setSkillEnabled(skill.name, val),
                              ),
                              const SizedBox(width: 6),
                              FilledButton.icon(
                                key: ValueKey('invoke_skill_${skill.name}'),
                                onPressed: skill.isEnabled
                                    ? () => _promptInvokeSkill(skill)
                                    : null,
                                icon: const Icon(Icons.play_arrow, size: 15),
                                label: const Text('즉시 호출'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            skill.description,
                            style: TextStyle(
                              fontSize: 12,
                              color: context.mac.secondaryLabel,
                            ),
                          ),
                          if (skill.routingSummary.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              '라우팅: ${skill.routingSummary}',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: context.mac.orange,
                              ),
                            ),
                          ],
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              for (final b in skill.syncedBackends)
                                BackendModelBadge(backend: b),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
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
