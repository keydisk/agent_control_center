import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/agent_models.dart';
import '../../services/effort_preference_store.dart';
import '../../services/session_manager.dart';
import '../../services/trusted_folder_store.dart';
import '../../services/workspace_group_store.dart';
import '../theme/mac_theme.dart';

Future<String?> pickFolderInFinder(String prompt) async {
  final res = await Process.run('osascript', [
    '-e',
    'POSIX path of (choose folder with prompt "$prompt")',
  ]);
  return res.exitCode == 0 ? res.stdout.toString().trim() : null;
}

class NewSessionRequest {
  const NewSessionRequest({
    required this.backend,
    required this.model,
    required this.effort,
    required this.folder,
    this.title,
    this.instructions = '',
    this.continueFrom,
  });

  /// 비어 있으면 첫 대화를 보고 이름을 짓습니다.
  final String? title;
  final BackendType backend;
  final String model;
  final ReasoningEffort effort;
  final String folder;
  final String instructions;

  /// 마지막 작업을 이어받을 이전 세션. null이면 새로 시작합니다.
  final SessionSnapshot? continueFrom;
}

class SessionSettingsResult {
  const SessionSettingsResult({
    required this.title,
    required this.backend,
    required this.effort,
    required this.folder,
    this.instructions = '',
    this.model,
  });

  final String instructions;
  final String title;
  final BackendType backend;

  /// 사용자가 바꾸지 않았으면 null입니다.
  final String? model;
  final ReasoningEffort effort;
  final String folder;
}

class _FolderField extends StatelessWidget {
  const _FolderField({
    required this.controller,
    required this.fieldKey,
    this.label = '작업 폴더',
    this.enabled = true,
    this.errorText,
    this.onChanged,
  });

  final TextEditingController controller;
  final Key fieldKey;
  final String label;
  final bool enabled;
  final String? errorText;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            key: fieldKey,
            controller: controller,
            enabled: enabled,
            onChanged: onChanged,
            decoration: InputDecoration(
              labelText: label,
              errorText: errorText,
              errorMaxLines: 3,
            ),
          ),
        ),
        if (Platform.isMacOS) ...[
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: enabled
                ? () async {
                    final picked = await pickFolderInFinder('작업 폴더를 선택하세요');
                    if (picked != null) {
                      controller.text = picked;
                      onChanged?.call(picked);
                    }
                  }
                : null,
            child: const Text('선택'),
          ),
        ],
      ],
    );
  }
}

class _InstructionsField extends StatelessWidget {
  const _InstructionsField({
    required this.controller,
    required this.fieldKey,
    required this.label,
    this.helper,
  });

  final TextEditingController controller;
  final Key fieldKey;
  final String label;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      controller: controller,
      minLines: 2,
      maxLines: 5,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        alignLabelWithHint: true,
      ),
    );
  }
}

class _BackendDropdown extends StatelessWidget {
  const _BackendDropdown({
    required this.value,
    required this.onChanged,
    this.dropdownKey,
  });

  final BackendType value;
  final ValueChanged<BackendType>? onChanged;
  final Key? dropdownKey;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<BackendType>(
      key: dropdownKey,
      initialValue: value,
      isDense: true,
      borderRadius: BorderRadius.circular(8),
      decoration: const InputDecoration(labelText: '백엔드'),
      items: [
        for (final b in BackendType.values)
          DropdownMenuItem(
            value: b,
            child: Text(b.displayName, style: const TextStyle(fontSize: 13)),
          ),
      ],
      onChanged: onChanged == null
          ? null
          : (b) {
              if (b != null) onChanged!(b);
            },
    );
  }
}

class _ModelDropdown extends StatelessWidget {
  const _ModelDropdown({
    required this.backend,
    required this.value,
    required this.onChanged,
  });

  final BackendType backend;
  final String value;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      // 백엔드가 바뀌면 목록과 선택값을 새로 초기화합니다.
      key: ValueKey('session_model_${backend.id}'),
      initialValue: value,
      isDense: true,
      borderRadius: BorderRadius.circular(8),
      decoration: const InputDecoration(labelText: '모델'),
      items: [
        for (final m in backend.availableModels)
          DropdownMenuItem(
            value: m,
            child: Text(m, style: const TextStyle(fontSize: 13)),
          ),
      ],
      onChanged: onChanged == null
          ? null
          : (m) {
              if (m != null) onChanged!(m);
            },
    );
  }
}

class _EffortDropdown extends StatelessWidget {
  const _EffortDropdown({
    required this.backend,
    required this.value,
    required this.onChanged,
  });

  final BackendType backend;
  final ReasoningEffort value;
  final ValueChanged<ReasoningEffort>? onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<ReasoningEffort>(
      // 백엔드마다 선택지가 달라 새로 초기화합니다.
      key: ValueKey('session_effort_${backend.id}'),
      initialValue: value,
      isDense: true,
      borderRadius: BorderRadius.circular(8),
      decoration: const InputDecoration(labelText: 'Effort'),
      items: [
        for (final effort in backend.supportedEfforts)
          DropdownMenuItem(
            value: effort,
            child: Text(effort.label, style: const TextStyle(fontSize: 13)),
          ),
      ],
      onChanged: onChanged == null
          ? null
          : (e) {
              if (e != null) onChanged!(e);
            },
    );
  }
}

/// 백엔드와 작업 폴더를 지정해 세션을 만듭니다. 지정한 폴더는 신뢰 목록에 추가됩니다.
class NewSessionDialog extends StatefulWidget {
  const NewSessionDialog({
    super.key,
    required this.initialBackend,
    required this.initialFolder,
    this.initialModel,
    this.initialEffort = ReasoningEffort.auto,
    this.trustedFolders,
    this.effortPreferences,
    this.title = '새 세션',
    this.note,
    this.showInstructions = false,
    this.lockFolder = false,
    this.initialInstructions = '',
    this.previousSessions = const [],
  });

  final String title;
  final String? note;
  final bool showInstructions;

  /// 그룹 세션은 작업 폴더가 그룹 폴더로 고정됩니다.
  final bool lockFolder;
  final String initialInstructions;
  final List<SessionSnapshot> previousSessions;
  final BackendType initialBackend;
  final String? initialModel;
  final ReasoningEffort initialEffort;
  final String initialFolder;
  final TrustedFolderStore? trustedFolders;
  final EffortPreferenceStore? effortPreferences;

  @override
  State<NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<NewSessionDialog> {
  final _nameCtrl = TextEditingController();
  late final _folderCtrl = TextEditingController(text: widget.initialFolder);
  late final _instructionsCtrl = TextEditingController(
    text: widget.initialInstructions,
  );
  SessionSnapshot? _continueFrom;
  late BackendType _backend = widget.initialBackend;
  late String _model =
      _backend.availableModels.contains(
        _backend.baseModel(widget.initialModel ?? ''),
      )
      ? _backend.baseModel(widget.initialModel!)
      : _backend.defaultModel;
  late ReasoningEffort _effort = _backend.resolveEffort(
    widget.initialEffort,
    widget.initialModel ?? _backend.defaultModel,
  );
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _folderCtrl.dispose();
    _instructionsCtrl.dispose();
    super.dispose();
  }

  void _create() {
    final folder = _folderCtrl.text.trim();
    if (!Directory(folder).existsSync()) {
      setState(() => _error = '존재하지 않는 폴더입니다.');
      return;
    }
    try {
      // 그룹 폴더의 신뢰를 해제했다면 조용히 되살리지 않고 실행 때 다시 묻습니다.
      if (!widget.lockFolder) widget.trustedFolders?.add(folder);
    } on StateError catch (e) {
      setState(() => _error = e.message);
      return;
    }
    final name = _nameCtrl.text.trim();
    Navigator.of(context).pop(
      NewSessionRequest(
        title: name.isEmpty ? null : name,
        backend: _backend,
        model: _model,
        effort: _effort,
        folder: folder,
        instructions: _instructionsCtrl.text.trim(),
        continueFrom: _continueFrom,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('new_session_dialog'),
      scrollable: true,
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('new_session_title'),
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: '세션 이름 (선택)',
                helperText: '비워 두면 첫 대화를 보고 자동으로 정합니다.',
              ),
            ),
            const SizedBox(height: 12),
            _BackendDropdown(
              dropdownKey: const ValueKey('new_session_backend'),
              value: _backend,
              onChanged: (b) => setState(() {
                _backend = b;
                _model = b.defaultModel;
                _effort = widget.effortPreferences?.effortFor(b) ?? b.defaultEffort;
              }),
            ),
            const SizedBox(height: 12),
            _ModelDropdown(
              backend: _backend,
              value: _model,
              onChanged: (m) => setState(() => _model = m),
            ),
            const SizedBox(height: 12),
            _EffortDropdown(
              backend: _backend,
              value: _effort,
              onChanged: (e) => setState(() => _effort = e),
            ),
            const SizedBox(height: 12),
            _FolderField(
              fieldKey: const ValueKey('new_session_folder'),
              controller: _folderCtrl,
              enabled: !widget.lockFolder,
              errorText: _error,
            ),
            if (widget.lockFolder || widget.trustedFolders != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.lockFolder
                    ? '작업 폴더는 그룹 폴더를 따릅니다.'
                    : '이 폴더는 신뢰 폴더로 등록됩니다. 세션 환경 설정에서 해제할 수 있습니다.',
                style: TextStyle(
                  fontSize: 11.5,
                  color: context.mac.secondaryLabel,
                ),
              ),
            ],
            if (widget.showInstructions) ...[
              const SizedBox(height: 12),
              _InstructionsField(
                fieldKey: const ValueKey('new_session_instructions'),
                controller: _instructionsCtrl,
                label: '세션별 지침 (선택)',
              ),
            ],
            if (widget.previousSessions.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<SessionSnapshot?>(
                key: const ValueKey('new_session_continue'),
                initialValue: null,
                isExpanded: true,
                isDense: true,
                borderRadius: BorderRadius.circular(8),
                decoration: const InputDecoration(labelText: '이전 세션 이어가기'),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('새로 시작', style: TextStyle(fontSize: 13)),
                  ),
                  for (final s in widget.previousSessions)
                    DropdownMenuItem(
                      value: s,
                      child: Text(
                        '${s.title} · 마지막 작업만 가져오기',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                ],
                onChanged: (s) => setState(() => _continueFrom = s),
              ),
            ],
            if (widget.note != null) ...[
              const SizedBox(height: 8),
              Text(
                widget.note!,
                style: TextStyle(
                  fontSize: 11.5,
                  color: context.mac.secondaryLabel,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('create_session_button'),
          onPressed: _create,
          child: const Text('만들기'),
        ),
      ],
    );
  }
}

class WorkspaceGroupResult {
  const WorkspaceGroupResult({
    required this.group,
    required this.defaultInstructions,
  });

  final WorkspaceGroup group;
  final String defaultInstructions;
}

/// 작업 그룹의 신뢰 폴더, 세션 기본 설정, 지침을 만들거나 고칩니다.
class WorkspaceGroupDialog extends StatefulWidget {
  const WorkspaceGroupDialog({
    super.key,
    required this.defaultInstructions,
    required this.initialFolder,
    this.group,
    this.trustedFolders,
    this.effortPreferences,
  });

  final WorkspaceGroup? group;
  final String defaultInstructions;
  final String initialFolder;
  final TrustedFolderStore? trustedFolders;
  final EffortPreferenceStore? effortPreferences;

  @override
  State<WorkspaceGroupDialog> createState() => _WorkspaceGroupDialogState();
}

class _WorkspaceGroupDialogState extends State<WorkspaceGroupDialog> {
  late final _nameCtrl = TextEditingController(text: widget.group?.name);
  late final _folderCtrl = TextEditingController(
    text: widget.group?.folder ?? widget.initialFolder,
  );
  late final _defaultCtrl = TextEditingController(
    text: widget.defaultInstructions,
  );
  late final _extraCtrl = TextEditingController(
    text: widget.group?.instructions,
  );
  late BackendType _backend = widget.group?.backend ?? BackendType.antigravity;
  late String _model = widget.group?.model ?? _backend.defaultModel;
  late ReasoningEffort _effort =
      widget.group?.effort ??
      widget.effortPreferences?.effortFor(_backend) ??
      _backend.defaultEffort;
  late bool _useDefault = widget.group?.useDefaultInstructions ?? true;
  String? _nameError;
  String? _folderError;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _folderCtrl.dispose();
    _defaultCtrl.dispose();
    _extraCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameCtrl.text.trim();
    final folder = _folderCtrl.text.trim();
    setState(() {
      _nameError = name.isEmpty ? '그룹 이름을 입력해 주세요.' : null;
      _folderError = Directory(folder).existsSync() ? null : '존재하지 않는 폴더입니다.';
    });
    if (_nameError != null || _folderError != null) return;
    try {
      widget.trustedFolders?.add(folder);
    } on StateError catch (e) {
      setState(() => _folderError = e.message);
      return;
    }
    Navigator.of(context).pop(
      WorkspaceGroupResult(
        defaultInstructions: _defaultCtrl.text.trim(),
        group: WorkspaceGroup(
          id:
              widget.group?.id ??
              'group_${DateTime.now().microsecondsSinceEpoch}',
          name: name,
          folder: folder,
          backend: _backend,
          model: _model,
          effort: _effort,
          useDefaultInstructions: _useDefault,
          instructions: _extraCtrl.text.trim(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('workspace_group_dialog'),
      title: Text(widget.group == null ? '작업 그룹 만들기' : '작업 그룹 설정'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('group_name'),
                controller: _nameCtrl,
                decoration: InputDecoration(
                  labelText: '그룹 이름',
                  errorText: _nameError,
                ),
              ),
              const SizedBox(height: 12),
              _FolderField(
                fieldKey: const ValueKey('group_folder'),
                controller: _folderCtrl,
                label: '신뢰 폴더',
                errorText: _folderError,
              ),
              const SizedBox(height: 12),
              _BackendDropdown(
                value: _backend,
                onChanged: (b) => setState(() {
                  _backend = b;
                  _model = b.defaultModel;
                  _effort =
                      widget.effortPreferences?.effortFor(b) ?? b.defaultEffort;
                }),
              ),
              const SizedBox(height: 12),
              _ModelDropdown(
                backend: _backend,
                value: _model,
                onChanged: (m) => setState(() => _model = m),
              ),
              const SizedBox(height: 12),
              _EffortDropdown(
                backend: _backend,
                value: _effort,
                onChanged: (e) => setState(() => _effort = e),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const ValueKey('group_use_default_instructions'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _useDefault,
                title: const Text('기본 지침 사용'),
                onChanged: (v) => setState(() => _useDefault = v ?? false),
              ),
              if (_useDefault) ...[
                _InstructionsField(
                  fieldKey: const ValueKey('group_default_instructions'),
                  controller: _defaultCtrl,
                  label: '기본 지침',
                  helper: '기본 지침을 쓰는 모든 그룹에 함께 적용됩니다.',
                ),
                const SizedBox(height: 12),
              ],
              _InstructionsField(
                fieldKey: const ValueKey('group_extra_instructions'),
                controller: _extraCtrl,
                label: _useDefault ? '추가 지침 (선택)' : '그룹 지침 (선택)',
                helper: '세션별 지침은 세션을 만들 때나 세션 환경 설정에서 정합니다.',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('save_group_button'),
          onPressed: _save,
          child: const Text('저장'),
        ),
      ],
    );
  }
}

/// 세션 이름·백엔드·모델·폴더와 폴더 신뢰 여부를 변경합니다.
class SessionSettingsDialog extends StatefulWidget {
  const SessionSettingsDialog({
    super.key,
    required this.session,
    this.trustedFolders,
    this.effortPreferences,
  });

  final ManagedSession session;
  final TrustedFolderStore? trustedFolders;
  final EffortPreferenceStore? effortPreferences;

  @override
  State<SessionSettingsDialog> createState() => _SessionSettingsDialogState();
}

class _SessionSettingsDialogState extends State<SessionSettingsDialog> {
  late final _titleCtrl = TextEditingController(text: widget.session.title);
  late final _folderCtrl = TextEditingController(
    text: widget.session.workingDirectory,
  );
  late final _instructionsCtrl = TextEditingController(
    text: widget.session.instructions,
  );
  late BackendType _backend = widget.session.backendType;
  late final String _initialModel =
      _backend.availableModels.contains(
        _backend.baseModel(widget.session.model),
      )
      ? _backend.baseModel(widget.session.model)
      : _backend.defaultModel;
  late String _model = _initialModel;
  late ReasoningEffort _effort = _backend.resolveEffort(
    widget.session.effort,
    widget.session.model,
  );
  late bool _trusted =
      widget.trustedFolders?.isTrusted(widget.session.workingDirectory) ??
      false;
  String? _error;

  bool get _isBusy =>
      widget.session.status == SessionStatus.running ||
      widget.session.status == SessionStatus.awaitingApproval;

  // 미병합 worktree가 있는 세션의 폴더를 바꾸면 작업 브랜치와 연결이 끊깁니다.
  bool get _canChangeFolder =>
      widget.session.groupId == null &&
      !_isBusy &&
      widget.session.activeWorktreeLink == null;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _folderCtrl.dispose();
    _instructionsCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final folder = _folderCtrl.text.trim();
    if (folder != widget.session.workingDirectory &&
        !Directory(folder).existsSync()) {
      setState(() => _error = '존재하지 않는 폴더입니다.');
      return;
    }
    final store = widget.trustedFolders;
    if (store != null) {
      if (_trusted && !store.isTrusted(folder)) {
        try {
          store.add(folder);
        } on StateError catch (e) {
          setState(() => _error = e.message);
          return;
        }
      } else if (!_trusted) {
        store.coveringFolders(folder).forEach(store.remove);
      }
    }
    final title = _titleCtrl.text.trim();
    Navigator.of(context).pop(
      SessionSettingsResult(
        title: title.isEmpty ? widget.session.title : title,
        backend: _backend,
        model: _backend != widget.session.backendType || _model != _initialModel
            ? _model
            : null,
        effort: _effort,
        folder: folder,
        instructions: _instructionsCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    return AlertDialog(
      key: const ValueKey('session_settings_dialog'),
      title: const Text('세션 환경 설정'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('session_settings_title'),
              controller: _titleCtrl,
              decoration: const InputDecoration(labelText: '세션 이름'),
            ),
            const SizedBox(height: 12),
            _BackendDropdown(
              value: _backend,
              onChanged: _isBusy
                  ? null
                  : (b) => setState(() {
                      _backend = b;
                      _model = b.defaultModel;
                      _effort = widget.effortPreferences?.effortFor(b) ?? b.defaultEffort;
                    }),
            ),
            const SizedBox(height: 12),
            _ModelDropdown(
              backend: _backend,
              value: _model,
              onChanged: _isBusy ? null : (m) => setState(() => _model = m),
            ),
            const SizedBox(height: 12),
            _EffortDropdown(
              backend: _backend,
              value: _effort,
              onChanged: _isBusy ? null : (e) => setState(() => _effort = e),
            ),
            const SizedBox(height: 12),
            _FolderField(
              fieldKey: const ValueKey('session_settings_folder'),
              controller: _folderCtrl,
              enabled: _canChangeFolder,
              errorText: _error,
              onChanged: (_) => setState(() {}),
            ),
            if (!_canChangeFolder) ...[
              const SizedBox(height: 4),
              Text(
                widget.session.groupId != null
                    ? '작업 폴더는 그룹 폴더를 따릅니다. 그룹 설정에서 바꿀 수 있습니다.'
                    : _isBusy
                    ? '실행 중에는 폴더를 바꿀 수 없습니다.'
                    : '병합되지 않은 worktree가 있어 폴더를 바꿀 수 없습니다.',
                style: TextStyle(fontSize: 11.5, color: mac.secondaryLabel),
              ),
            ],
            if (widget.trustedFolders != null) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                key: const ValueKey('session_settings_trust'),
                contentPadding: EdgeInsets.zero,
                value: _trusted,
                title: const Text('이 폴더 신뢰'),
                subtitle: Text(
                  _trustDescription(),
                  style: TextStyle(fontSize: 11.5, color: mac.secondaryLabel),
                ),
                onChanged: (v) => setState(() => _trusted = v),
              ),
            ],
            const SizedBox(height: 12),
            _InstructionsField(
              fieldKey: const ValueKey('session_settings_instructions'),
              controller: _instructionsCtrl,
              label: '세션별 지침 (선택)',
              helper: '다음 프롬프트부터 적용됩니다.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('save_session_settings_button'),
          onPressed: _save,
          child: const Text('저장'),
        ),
      ],
    );
  }

  String _trustDescription() {
    final covering = widget.trustedFolders!.coveringFolders(
      _folderCtrl.text.trim(),
    );
    if (_trusted) {
      return covering.isEmpty
          ? '저장하면 신뢰 폴더로 등록합니다.'
          : '신뢰 기준: ${covering.join(', ')}';
    }
    return covering.isEmpty
        ? '해제되어 있습니다. 다음 실행 때 다시 묻습니다.'
        : '저장하면 ${covering.join(', ')} 신뢰를 해제합니다. 이 폴더를 쓰는 다른 세션도 다음 실행 때 다시 묻습니다.';
  }
}

/// 세션 삭제 확인. worktree는 변경이 없을 때만 함께 정리됩니다.
class DeleteSessionDialog extends StatelessWidget {
  const DeleteSessionDialog({super.key, required this.session});

  final ManagedSession session;

  @override
  Widget build(BuildContext context) {
    final link = session.activeWorktreeLink;
    return AlertDialog(
      key: const ValueKey('delete_session_dialog'),
      title: const Text('세션을 삭제할까요?'),
      content: Text(
        '"${session.title}"의 대화 기록이 사라지며 실행 중이면 중지됩니다.'
        '${link == null ? '' : '\n\n${link.branch} worktree는 변경이 없으면 함께 정리하고, 변경이 있으면 브랜치와 폴더를 그대로 남깁니다.'}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('confirm_delete_session_button'),
          style: FilledButton.styleFrom(
            backgroundColor: context.mac.red,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('삭제'),
        ),
      ],
    );
  }
}
