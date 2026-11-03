import '../../adapters/antigravity/antigravity_adapter.dart';
import '../../adapters/claude/claude_code_adapter.dart';
import '../../adapters/codex/codex_adapter.dart';
import '../models/agent_models.dart';
import 'agent_backend.dart';
import 'local_hook_bridge.dart';

typedef BackendBuilder = AgentBackend Function({
  ProcessSpawner? spawner,
  LocalHookBridgeServer? hookBridge,
});

/// 어댑터 레지스트리. 새 백엔드를 어댑터 등록만으로 확장할 수 있습니다.
class BackendRegistry {
  BackendRegistry({
    ProcessSpawner? spawner,
    this.hookBridge,
  }) : _spawner = spawner ?? const IoProcessSpawner() {
    register(
      BackendType.antigravity,
      ({spawner, hookBridge}) =>
          AntigravityAdapter(spawner: spawner, hookBridge: hookBridge),
    );
    register(
      BackendType.claudeCode,
      ({spawner, hookBridge}) => ClaudeCodeAdapter(spawner: spawner),
    );
    register(
      BackendType.codex,
      ({spawner, hookBridge}) => CodexAdapter(spawner: spawner),
    );
  }

  final ProcessSpawner _spawner;
  final LocalHookBridgeServer? hookBridge;
  final Map<BackendType, BackendBuilder> _builders = {};

  void register(BackendType type, BackendBuilder builder) {
    _builders[type] = builder;
  }

  AgentBackend create(BackendType type) {
    final builder = _builders[type];
    if (builder == null) {
      throw ArgumentError('등록되지 않은 백엔드입니다: $type');
    }
    return builder(spawner: _spawner, hookBridge: hookBridge);
  }

  Future<Map<BackendType, BackendInstallationStatus>> checkAllInstallations() async {
    final results = <BackendType, BackendInstallationStatus>{};
    for (final b in BackendType.values) {
      results[b] = await AgentBackend.checkInstallation(b, spawner: _spawner);
    }
    return results;
  }
}
