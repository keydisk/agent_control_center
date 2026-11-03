import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/mac_theme.dart';
import 'session_dialogs.dart';

import 'package:flutter/services.dart';

import '../../core/models/agent_models.dart';
import '../../services/skill_registry.dart';
import '../../services/workspace_group_store.dart';

/// 멀티라인 프롬프트 입력창 + 파일/이미지 첨부 + 백엔드별 슬래시 명령·스킬 자동완성 + 백엔드/모델/폴더 선택 바
class PromptInputBar extends StatefulWidget {
  const PromptInputBar({
    super.key,
    required this.selectedBackend,
    required this.selectedModel,
    required this.workingDirectory,
    required this.onBackendChanged,
    required this.onModelChanged,
    required this.onWorkingDirectoryChanged,
    this.workingDirectoryLocked = false,
    required this.onSubmit,
    this.selectedEffort = ReasoningEffort.auto,
    this.onEffortChanged,
    this.selectedPermissionMode = PermissionMode.manual,
    this.onPermissionModeChanged,
    this.selectedDevice = TargetDeviceType.macosDesktop,
    this.onDeviceChanged,
    this.isBusy = false,
    this.onInterrupt,
    this.skills = const [],
    this.savedSessions = const [],
    this.onLoadSession,
  });

  final BackendType selectedBackend;
  final String selectedModel;
  final String workingDirectory;
  final ValueChanged<BackendType> onBackendChanged;
  final ValueChanged<String> onModelChanged;
  final ReasoningEffort selectedEffort;
  final ValueChanged<ReasoningEffort>? onEffortChanged;
  final PermissionMode selectedPermissionMode;
  final ValueChanged<PermissionMode>? onPermissionModeChanged;
  final ValueChanged<String> onWorkingDirectoryChanged;

  /// 그룹 세션처럼 폴더를 바꿀 수 없을 때 true입니다.
  final bool workingDirectoryLocked;
  final void Function(String prompt, List<String> attachments) onSubmit;
  final TargetDeviceType selectedDevice;
  final ValueChanged<TargetDeviceType>? onDeviceChanged;
  final bool isBusy;
  final VoidCallback? onInterrupt;
  final List<SkillDefinition> skills;
  final List<SessionSnapshot> savedSessions;
  final ValueChanged<SessionSnapshot>? onLoadSession;

  @override
  State<PromptInputBar> createState() => _PromptInputBarState();
}

/// 세션의 권한 처리 방식을 고르는 메뉴
class _PermissionModeMenu extends StatelessWidget {
  const _PermissionModeMenu({required this.selected, this.onSelected});

  final PermissionMode selected;
  final ValueChanged<PermissionMode>? onSelected;

  @override
  Widget build(BuildContext context) {
    final mac = context.mac;
    final isBypass = selected == PermissionMode.bypass;
    return PopupMenuButton<PermissionMode>(
      key: const ValueKey('permission_mode_button'),
      tooltip: '권한 모드',
      enabled: onSelected != null,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final mode in PermissionMode.values)
          PopupMenuItem(
            key: ValueKey('permission_mode_${mode.name}'),
            value: mode,
            child: SizedBox(
              width: 280,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          mode.label,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: mac.label,
                          ),
                        ),
                        Text(
                          mode.description,
                          style: TextStyle(
                            fontSize: 11,
                            color: mac.secondaryLabel,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (mode == selected)
                    Icon(Icons.check, size: 15, color: mac.blue),
                ],
              ),
            ),
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isBypass ? Icons.gpp_maybe_outlined : Icons.shield_outlined,
            size: 13,
            color: isBypass ? mac.red : mac.secondaryLabel,
          ),
          const SizedBox(width: 3),
          Text(
            selected.label,
            style: TextStyle(
              fontSize: 12,
              color: isBypass ? mac.red : mac.secondaryLabel,
            ),
          ),
          Icon(Icons.arrow_drop_down, size: 14, color: mac.secondaryLabel),
        ],
      ),
    );
  }
}

class _PromptInputBarState extends State<PromptInputBar> {
  final TextEditingController _controller = TextEditingController();
  late final FocusNode _focusNode = FocusNode(onKeyEvent: _onPromptKeyEvent);
  final List<String> _attachments = [];
  String _lastText = '';
  int _highlightedIndex = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    setState(() {
      if (_controller.text != _lastText) {
        _lastText = _controller.text;
        _highlightedIndex = 0;
      }
    });
  }

  static final _sessionCmdPattern = RegExp(
    r'^/(?:load|resume|불러오기|검색)(?:\s+(.*))?$',
    caseSensitive: false,
  );

  String? get _sessionSearchQuery {
    final text = _controller.text;
    if (text.contains('\n')) return null;
    final match = _sessionCmdPattern.firstMatch(text);
    if (match == null) return null;
    return (match.group(1) ?? '').trim();
  }

  List<SessionSnapshot> get _sessionSuggestions {
    final query = _sessionSearchQuery;
    if (query == null) return const [];
    final q = query.toLowerCase();
    final filtered = [
      for (final s in widget.savedSessions)
        if (q.isEmpty || s.searchableText.toLowerCase().contains(q)) s,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return filtered.take(10).toList(growable: false);
  }

  List<({String cmd, SkillDefinition? skill})> get _slashSuggestions {
    final query = _controller.text.toLowerCase();
    if (!query.startsWith('/') || query.contains(' ') || query.contains('\n')) {
      return const [];
    }
    final commands = widget.selectedBackend.slashCommands
        .where((cmd) => cmd.toLowerCase().startsWith(query))
        .toList();
    return [
      for (final skill in widget.skills)
        if (skill.isEnabled &&
            '/${skill.name}'.toLowerCase().startsWith(query) &&
            !commands.contains('/${skill.name}'))
          (cmd: '/${skill.name}', skill: skill),
      for (final cmd in commands) (cmd: cmd, skill: null),
    ];
  }

  void _applySuggestion(String cmd) {
    _controller.text = '$cmd ';
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
    _focusNode.requestFocus();
  }

  void _applySessionSuggestion(SessionSnapshot snapshot) {
    _controller.clear();
    if (widget.onLoadSession != null) {
      widget.onLoadSession!(snapshot);
    } else {
      widget.onSubmit('/load ${snapshot.id}', const []);
    }
    _focusNode.requestFocus();
  }

  /// 자동완성 목록이 열려 있을 때 ↑/↓로 이동하고 Tab/Enter로 완성합니다.
  KeyEventResult _onPromptKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event is KeyDownEvent && _isSendShortcut(event.logicalKey)) {
      // 실행 중에는 입력을 지우지 않습니다. 전송 버튼도 이때는 중지 버튼입니다.
      if (!_isInterruptible) _handleSend();
      return KeyEventResult.handled;
    }
    final suggestions = _slashSuggestions;
    final sessionMatches = suggestions.isEmpty
        ? _sessionSuggestions
        : const <SessionSnapshot>[];
    final count = suggestions.isNotEmpty
        ? suggestions.length
        : sessionMatches.length;
    if (count == 0) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final delta = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      setState(() {
        _highlightedIndex = (_highlightedIndex + delta) % count;
      });
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (key == LogicalKeyboardKey.tab ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter)) {
      if (suggestions.isNotEmpty) {
        _applySuggestion(suggestions[_highlightedIndex % count].cmd);
      } else {
        _applySessionSuggestion(sessionMatches[_highlightedIndex % count]);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildSlashSuggestions() {
    final suggestions = _slashSuggestions;
    final sessionMatches = _sessionSuggestions;
    if (suggestions.isEmpty && sessionMatches.isEmpty) {
      return const SizedBox.shrink();
    }
    final highlighted = suggestions.isNotEmpty
        ? _highlightedIndex % suggestions.length
        : _highlightedIndex % sessionMatches.length;
    final description = suggestions.isNotEmpty
        ? suggestions[highlighted].skill?.description
        : sessionMatches[highlighted].lastTurn;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (suggestions.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.15,
              ),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (index, item) in suggestions.indexed)
                      _buildSlashChip(
                        item.cmd,
                        avatar: item.skill == null
                            ? null
                            : const Icon(Icons.auto_awesome, size: 14),
                        tooltip: item.skill?.description,
                        isHighlighted: index == highlighted,
                      ),
                  ],
                ),
              ),
            ),
          if (sessionMatches.isNotEmpty) ...[
            if (suggestions.isNotEmpty) const SizedBox(height: 6),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.2,
              ),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (index, s) in sessionMatches.indexed)
                      ActionChip(
                        key: ValueKey('slash_session_${s.id}'),
                        avatar: const Icon(Icons.history, size: 14),
                        tooltip: s.lastTurn,
                        backgroundColor:
                            suggestions.isEmpty && index == highlighted
                            ? Theme.of(context).colorScheme.primaryContainer
                            : null,
                        label: Text(
                          '${s.title} (${s.backend.displayName})',
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: () => _applySessionSuggestion(s),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            key: const ValueKey('slash_suggestion_hint'),
            '${description == null || description.isEmpty ? '' : '$description\n'}↑↓ 선택 · Tab/Enter ${suggestions.isNotEmpty ? '완성' : '불러오기'}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildSlashChip(
    String cmd, {
    Widget? avatar,
    String? tooltip,
    required bool isHighlighted,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Builder(
      builder: (chipContext) {
        if (isHighlighted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (chipContext.mounted) {
              Scrollable.ensureVisible(chipContext, alignment: 0.5);
            }
          });
        }
        return ActionChip(
          key: ValueKey('slash_chip_$cmd'),
          avatar: avatar,
          tooltip: tooltip,
          backgroundColor: isHighlighted ? colors.primaryContainer : null,
          side: isHighlighted ? BorderSide(color: colors.primary) : null,
          label: Text(cmd, style: const TextStyle(fontSize: 12)),
          onPressed: () => _applySuggestion(cmd),
        );
      },
    );
  }

  bool get _isInterruptible => widget.isBusy && widget.onInterrupt != null;

  bool _isSendShortcut(LogicalKeyboardKey key) {
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    return Platform.isMacOS
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
  }

  String get _sendShortcutLabel => Platform.isMacOS ? '⌘↩' : 'Ctrl+Enter';

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final attached = List<String>.from(_attachments);
    _controller.clear();
    setState(() {
      _attachments.clear();
    });
    widget.onSubmit(text, attached);
  }

  Future<void> _showAddAttachmentDialog() async {
    final pathCtrl = TextEditingController();
    final added = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('파일 / 이미지 첨부'),
        content: TextField(
          controller: pathCtrl,
          decoration: const InputDecoration(
            labelText: '파일 절대 경로 입력',
            hintText: '/path/to/image.png 또는 /path/to/file.dart',
          ),
        ),
        actions: [
          if (Platform.isMacOS)
            TextButton(
              onPressed: () async {
                final res = await Process.run('osascript', [
                  '-e',
                  'POSIX path of (choose file with prompt "첨부할 파일을 선택하세요")',
                ]);
                if (res.exitCode == 0) {
                  pathCtrl.text = res.stdout.toString().trim();
                }
              },
              child: const Text('Finder에서 선택'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(pathCtrl.text.trim()),
            child: const Text('첨부'),
          ),
        ],
      ),
    );
    if (added != null && added.isNotEmpty) {
      setState(() {
        _attachments.add(added);
      });
    }
  }

  Future<void> _showWorkingDirDialog() async {
    final dirCtrl = TextEditingController(text: widget.workingDirectory);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('작업 디렉터리 변경'),
        content: TextField(
          controller: dirCtrl,
          decoration: const InputDecoration(labelText: '작업 디렉터리 경로'),
        ),
        actions: [
          if (Platform.isMacOS)
            TextButton(
              onPressed: () async {
                final picked = await pickFolderInFinder('작업 폴더를 선택하세요');
                if (picked != null) {
                  dirCtrl.text = picked;
                }
              },
              child: const Text('Finder에서 선택'),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(dirCtrl.text.trim()),
            child: const Text('적용'),
          ),
        ],
      ),
    );
    if (updated != null && updated.isNotEmpty) {
      widget.onWorkingDirectoryChanged(updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    final models = widget.selectedBackend.availableModels;
    final activeModel = models.contains(widget.selectedModel)
        ? widget.selectedModel
        : widget.selectedBackend.defaultModel;

    final mac = context.mac;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 슬래시 명령·스킬 자동완성 팝업 바
          _buildSlashSuggestions(),

          // 첨부 파일 목록
          if (_attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final file in _attachments)
                    InputChip(
                      avatar: const Icon(Icons.attach_file, size: 14),
                      label: Text(
                        file.split('/').last,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      onDeleted: () {
                        setState(() {
                          _attachments.remove(file);
                        });
                      },
                    ),
                ],
              ),
            ),

          // 입력창과 제어 버튼을 묶은 작성 영역
          DecoratedBox(
            decoration: BoxDecoration(
              color: mac.fill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: mac.separator, width: 0.5),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('prompt_textfield'),
                    controller: _controller,
                    focusNode: _focusNode,
                    minLines: 1,
                    maxLines: 6,
                    decoration: InputDecoration(
                      hintText:
                          '에이전트에게 작업을 지시하세요... ("/" 자동완성 · $_sendShortcutLabel 전송)',
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 8,
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        key: const ValueKey('attach_button'),
                        tooltip: '파일/이미지 첨부',
                        onPressed: _showAddAttachmentDialog,
                        icon: const Icon(Icons.attach_file),
                      ),
                      const SizedBox(width: 6),
                      Expanded(child: _buildControls(activeModel, models)),
                      const SizedBox(width: 8),
                      _buildSendButton(mac),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 백엔드·모델·작업 폴더 선택
  Widget _buildControls(String activeModel, List<String> models) {
    final mac = context.mac;
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        DropdownButtonHideUnderline(
          child: DropdownButton<BackendType>(
            key: const ValueKey('backend_dropdown'),
            value: widget.selectedBackend,
            isDense: true,
            iconSize: 14,
            focusColor: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            items: [
              for (final b in BackendType.values)
                DropdownMenuItem(
                  value: b,
                  child: Text(
                    b.displayName,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: mac.label,
                    ),
                  ),
                ),
            ],
            onChanged: (val) {
              if (val != null) {
                widget.onBackendChanged(val);
              }
            },
          ),
        ),
        DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            key: const ValueKey('model_dropdown'),
            value: activeModel,
            isDense: true,
            iconSize: 14,
            focusColor: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            items: [
              for (final m in models)
                DropdownMenuItem(
                  value: m,
                  child: Text(
                    m,
                    style: TextStyle(fontSize: 12, color: mac.secondaryLabel),
                  ),
                ),
            ],
            onChanged: (val) {
              if (val != null) {
                widget.onModelChanged(val);
              }
            },
          ),
        ),
        DropdownButtonHideUnderline(
          child: DropdownButton<ReasoningEffort>(
            key: const ValueKey('effort_dropdown'),
            value: widget.selectedBackend.resolveEffort(
              widget.selectedEffort,
              widget.selectedModel,
            ),
            isDense: true,
            iconSize: 14,
            focusColor: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            selectedItemBuilder: (context) => [
              for (final effort in widget.selectedBackend.supportedEfforts)
                Text(
                  'Effort: ${effort.label}',
                  style: TextStyle(fontSize: 12, color: mac.secondaryLabel),
                ),
            ],
            items: [
              for (final effort in widget.selectedBackend.supportedEfforts)
                DropdownMenuItem(
                  value: effort,
                  child: Text(
                    effort.label,
                    style: TextStyle(fontSize: 12, color: mac.label),
                  ),
                ),
            ],
            onChanged: (val) {
              if (val != null) {
                widget.onEffortChanged?.call(val);
              }
            },
          ),
        ),
        _PermissionModeMenu(
          selected: widget.selectedPermissionMode,
          onSelected: widget.onPermissionModeChanged,
        ),
        TextButton.icon(
          key: const ValueKey('workdir_button'),
          onPressed: widget.workingDirectoryLocked
              ? null
              : _showWorkingDirDialog,
          style: TextButton.styleFrom(
            foregroundColor: mac.secondaryLabel,
            padding: const EdgeInsets.symmetric(horizontal: 6),
          ),
          icon: const Icon(Icons.folder_outlined, size: 14),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              widget.workingDirectory,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSendButton(MacColors mac) {
    final interrupting = _isInterruptible;
    return IconButton(
      key: ValueKey(interrupting ? 'interrupt_button' : 'send_button'),
      tooltip: interrupting ? '중지' : '전송 ($_sendShortcutLabel)',
      onPressed: interrupting ? widget.onInterrupt : _handleSend,
      style: IconButton.styleFrom(
        backgroundColor: interrupting
            ? mac.red
            : Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
      ),
      icon: Icon(
        interrupting ? Icons.stop_rounded : Icons.arrow_upward_rounded,
        size: 16,
      ),
    );
  }
}
