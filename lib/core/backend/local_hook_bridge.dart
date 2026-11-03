import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/agent_models.dart';

/// 로컬 루프백 HTTP 브리지 서버.
/// CLI 백엔드(예: agy의 PreToolUse 훅 등)가 도구 실행 전 승인 요청을
/// POST /approval 로 보내면 UI(PermissionCenter)에서 사용자 응답을 받아 반환합니다.
class LocalHookBridgeServer {
  HttpServer? _server;
  final Map<String, Completer<ApprovalDecision>> _pendingApprovals = {};
  final StreamController<ApprovalRequestData> _approvalRequestsController =
      StreamController<ApprovalRequestData>.broadcast();

  Stream<ApprovalRequestData> get approvalRequests =>
      _approvalRequestsController.stream;

  int get port => _server?.port ?? 0;
  bool get isRunning => _server != null;

  Future<int> start() async {
    if (_server != null) return _server!.port;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleHttpRequest);
    return _server!.port;
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    if (request.method != 'POST' || request.uri.path != '/approval') {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not Found');
      await request.response.close();
      return;
    }

    try {
      final body = await utf8.decoder.bind(request).join();
      final payload = jsonDecode(body) as Map<String, dynamic>;
      final responseJson = await handleHookPayload(payload);

      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(responseJson));
      await request.response.close();
    } catch (e) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'decision': 'deny',
            'reason': 'Hook bridge parse error: $e',
          }),
        );
      await request.response.close();
    }
  }

  Future<Map<String, dynamic>> handleHookPayload(
    Map<String, dynamic> payload,
  ) async {
    final sessionId =
        (payload['sessionId'] ?? payload['conversationId'] ?? 'default')
            .toString();
    final backendId = (payload['backend'] ?? 'agy').toString();
    final backend = BackendType.fromId(backendId);

    Map<String, dynamic> toolCallMap = {};
    if (payload['toolCall'] is Map) {
      toolCallMap = Map<String, dynamic>.from(payload['toolCall'] as Map);
    } else if (payload['tool_input'] is Map) {
      toolCallMap = {
        'name': payload['tool_name'] ?? 'tool',
        'args': payload['tool_input'],
      };
    }

    final toolName =
        (toolCallMap['name'] ?? payload['tool_name'] ?? 'unknown_tool')
            .toString();
    final rawArgs = toolCallMap['args'] ?? payload['tool_input'] ?? {};
    final args = rawArgs is Map
        ? Map<String, dynamic>.from(rawArgs)
        : <String, dynamic>{'value': rawArgs.toString()};

    final reqId =
        'hook_${DateTime.now().microsecondsSinceEpoch}_${_pendingApprovals.length}';
    final isDestructive = ApprovalRequestData.detectDestructive(toolName, args);
    final category = ApprovalRequestData.classifyTool(toolName, args);
    final targetResource = ApprovalRequestData.extractTargetResource(
      toolName,
      args,
    );

    final reqData = ApprovalRequestData(
      id: reqId,
      sessionId: sessionId,
      backend: backend,
      toolName: toolName,
      arguments: args,
      category: category,
      reason: isDestructive
          ? '파괴적 작업($toolName)이 감지되었습니다. 실행 전 반드시 확인이 필요합니다.'
          : '${backend.displayName} 에이전트가 [$toolName] 도구 실행 승인을 요청했습니다.',
      isDestructive: isDestructive,
      createdAt: DateTime.now(),
      targetResource: targetResource,
    );

    final completer = Completer<ApprovalDecision>();
    _pendingApprovals[reqId] = completer;
    _approvalRequestsController.add(reqData);

    final decision = await completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () => ApprovalDecision(
        requestId: reqId,
        approved: false,
        scope: ApprovalScope.denied,
        reason: '승인 대기 시간이 초과되었습니다.',
      ),
    );
    _pendingApprovals.remove(reqId);

    return <String, dynamic>{
      'decision': decision.approved ? 'allow' : 'deny',
      'reason':
          decision.reason ??
          (decision.approved ? '사용자 승인 완료' : '사용자가 실행을 거부했습니다.'),
      if (decision.approved && targetResource.isNotEmpty)
        'permissionOverrides': ['command($targetResource)'],
      if (decision.updatedInput != null) 'overwrite': decision.updatedInput,
    };
  }

  void resolveApproval(ApprovalDecision decision) {
    final completer = _pendingApprovals.remove(decision.requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(decision);
    }
  }

  /// 작업 디렉터리(또는 임시 디렉터리)에 agy 호환 PreToolUse 훅 스크립트를 생성합니다.
  Future<File> writeAgyHookScript({
    required Directory directory,
    required String sessionId,
    required BackendType backend,
  }) async {
    final portNum = await start();
    final scriptFile = File('${directory.path}/acc_pre_tool_hook.sh');
    final scriptContent = '''#!/bin/sh
INPUT=\$(cat)
PAYLOAD=\$(python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw) if raw.strip() else {}
except Exception:
    data = {}
data["sessionId"] = "$sessionId"
data["backend"] = "${backend.id}"
print(json.dumps(data))
' <<EOF
\$INPUT
EOF
)
curl -s -X POST "http://127.0.0.1:$portNum/approval" -H "Content-Type: application/json" -d "\$PAYLOAD"
''';
    await scriptFile.writeAsString(scriptContent);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', scriptFile.path]);
    }
    return scriptFile;
  }

  Future<void> dispose() async {
    for (final completer in _pendingApprovals.values) {
      if (!completer.isCompleted) {
        completer.complete(
          const ApprovalDecision(
            requestId: '',
            approved: false,
            scope: ApprovalScope.denied,
            reason: '브리지 서버가 종료되었습니다.',
          ),
        );
      }
    }
    _pendingApprovals.clear();
    await _server?.close(force: true);
    _server = null;
    await _approvalRequestsController.close();
  }
}
