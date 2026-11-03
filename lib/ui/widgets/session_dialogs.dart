import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/agent_models.dart';
import '../../services/session_manager.dart';
import '../../services/trusted_folder_store.dart';
import '../theme/mac_theme.dart';

Future<String?> pickFolderInFinder(String prompt) async {
  final res = await Process.run('osascript', [
    '-e',
    'POSIX path of (choose folder with prompt "$prompt")',
  ]);
  return res.exitCode == 0 ? res.stdout.toString().trim() : null;
}

class NewSessionRequest {
  const NewSessionRequest({required this.backend, required this.folder});

  final BackendType backend;
  final String folder;
}

class SessionSettingsResult {
  const SessionSettingsResult({
    required this.title,
    required this.backend,
    required this.folder,
    this.model,
  });

  final String title;
  final BackendType backend;

  /// 사용자가 바꾸지 않았으면 null입니다.
  final String? model;
  final String folder;
}

class _FolderField extends StatelessWidget {
  const _FolderField({
    required this.controller,
    required this.fieldKey,
    this.enabled = true,
    this.errorText,
    this.onChanged,
  });

  final TextEditingController controller;
  final Key fieldKey;
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
              labelText: '작업 폴더',
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

/// 백엔드와 작업 폴더를 지정해 세션을 만듭니다. 지정한 폴더는 신뢰 목록에 추가됩니다.
class NewSessionDialog extends StatefulWidget {
  const NewSessionDialog({
    super.key,
    required this.initialBackend,
    required this.initialFolder,
    this.trustedFolders,
  });

  final BackendType initialBackend;
  final String initialFolder;
  final TrustedFolderStore? trustedFolders;

  @override
  State<NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<NewSessionDialog> {
  late final _folderCtrl = TextEditingController(text: widget.initialFolder);
  late BackendType _backend = widget.initialBackend;
  String? _error;

  @override
  void dispose() {
    _folderCtrl.dispose();
    super.dispose();
  }

  void _create() {
    final folder = _folderCtrl.text.trim();
    if (!Directory(folder).existsSync()) {
      setState(() => _error = '존재하지 않는 폴더입니다.');
      return;
    }
    try {
      widget.trustedFolders?.add(folder);
    } on StateError catch (e) {
      setState(() => _error = e.message);
      return;
    }
    Navigator.of(context)
        .pop(NewSessionRequest(backend: _backend, folder: folder));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey('new_session_dialog'),
      title: const Text('새 세션'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BackendDropdown(
              dropdownKey: const ValueKey('new_session_backend'),
              value: _backend,
              onChanged: (b) => setState(() => _backend = b),
            ),
            const SizedBox(height: 12),
            _FolderField(
              fieldKey: const ValueKey('new_session_folder'),
              controller: _folderCtrl,
              errorText: _error,
            ),
            if (widget.trustedFolders != null) ...[
              const SizedBox(height: 8),
              Text(
                '이 폴더는 신뢰 폴더로 등록됩니다. 세션 환경 설정에서 해제할 수 있습니다.',
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

/// 세션 이름·백엔드·모델·폴더와 폴더 신뢰 여부를 변경합니다.
class SessionSettingsDialog extends StatefulWidget {
  const SessionSettingsDialog({
    super.key,
    required this.session,
    this.trustedFolders,
  });

  final ManagedSession session;
  final TrustedFolderStore? trustedFolders;

  @override
  State<SessionSettingsDialog> createState() => _SessionSettingsDialogState();
}

class _SessionSettingsDialogState extends State<SessionSettingsDialog> {
  late final _titleCtrl = TextEditingController(text: widget.session.title);
  late final _folderCtrl = TextEditingController(
    text: widget.session.workingDirectory,
  );
  late BackendType _backend = widget.session.backendType;
  late final String _initialModel =
      _backend.availableModels.contains(widget.session.model)
      ? widget.session.model
      : _backend.defaultModel;
  late String _model = _initialModel;
  late bool _trusted =
      widget.trustedFolders?.isTrusted(widget.session.workingDirectory) ??
      false;
  String? _error;

  bool get _isBusy =>
      widget.session.status == SessionStatus.running ||
      widget.session.status == SessionStatus.awaitingApproval;

  // 미병합 worktree가 있는 세션의 폴더를 바꾸면 작업 브랜치와 연결이 끊깁니다.
  bool get _canChangeFolder =>
      !_isBusy && widget.session.activeWorktreeLink == null;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _folderCtrl.dispose();
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
        folder: folder,
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
                    }),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('session_settings_model_${_backend.id}'),
              initialValue: _model,
              isDense: true,
              borderRadius: BorderRadius.circular(8),
              decoration: const InputDecoration(labelText: '모델'),
              items: [
                for (final m in _backend.availableModels)
                  DropdownMenuItem(
                    value: m,
                    child: Text(m, style: const TextStyle(fontSize: 13)),
                  ),
              ],
              onChanged: _isBusy
                  ? null
                  : (m) {
                      if (m != null) setState(() => _model = m);
                    },
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
                _isBusy
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
