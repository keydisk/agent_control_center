import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/trusted_folder_store.dart';
import '../widgets/session_dialogs.dart';

/// 에이전트 실행을 허용할 폴더를 추가·해제하는 다이얼로그
class TrustedFoldersDialog extends StatefulWidget {
  const TrustedFoldersDialog({super.key, required this.store});

  final TrustedFolderStore store;

  @override
  State<TrustedFoldersDialog> createState() => _TrustedFoldersDialogState();
}

class _TrustedFoldersDialogState extends State<TrustedFoldersDialog> {
  final _pathCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  void _add() {
    final path = _pathCtrl.text.trim();
    if (path.isEmpty) return;
    setState(() {
      try {
        widget.store.add(path);
        _pathCtrl.clear();
        _error = null;
      } on StateError catch (e) {
        _error = e.message;
      }
    });
  }

  Future<void> _pickFromFinder() async {
    final picked = await pickFolderInFinder('신뢰할 폴더를 선택하세요');
    if (picked != null) {
      _pathCtrl.text = picked;
    }
  }

  @override
  Widget build(BuildContext context) {
    final folders = widget.store.folders;
    return AlertDialog(
      key: const ValueKey('trusted_folders_dialog'),
      title: const Text('신뢰 폴더'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '에이전트는 이 폴더와 하위 폴더에서만 실행됩니다.',
              style: TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 8),
            if (folders.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('등록된 폴더가 없습니다.', style: TextStyle(fontSize: 12)),
              ),
            for (final folder in folders)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(folder, style: const TextStyle(fontSize: 12)),
                trailing: IconButton(
                  key: ValueKey('remove_trusted_$folder'),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: '신뢰 해제',
                  onPressed: () => setState(() => widget.store.remove(folder)),
                ),
              ),
            TextField(
              key: const ValueKey('trusted_folder_input'),
              controller: _pathCtrl,
              decoration: InputDecoration(
                labelText: '폴더 경로',
                errorText: _error,
                errorMaxLines: 3,
              ),
              onSubmitted: (_) => _add(),
            ),
          ],
        ),
      ),
      actions: [
        if (Platform.isMacOS)
          TextButton(
            onPressed: _pickFromFinder,
            child: const Text('Finder에서 선택'),
          ),
        TextButton(
          key: const ValueKey('add_trusted_folder_button'),
          onPressed: _add,
          child: const Text('추가'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
