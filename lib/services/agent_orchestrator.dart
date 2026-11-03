import '../core/models/agent_models.dart';

enum OrchestrationRole {
  antigravityMaster('Antigravity (백그라운드 지휘·요약·기본 수행)'),
  claudeImplementation('Claude Code (코드 구현·리팩터링 위임)'),
  codexReview('OpenAI Codex (코드 리뷰·보안 검증 위임)');

  const OrchestrationRole(this.label);
  final String label;
}

class OrchestratedSubTask {
  const OrchestratedSubTask({
    required this.title,
    required this.targetBackend,
    required this.targetModel,
    required this.role,
    required this.prompt,
    required this.rationale,
  });

  final String title;
  final BackendType targetBackend;
  final String targetModel;
  final OrchestrationRole role;
  final String prompt;
  final String rationale;
}

class OrchestrationPlan {
  const OrchestrationPlan({
    required this.originalPrompt,
    required this.coordinatorBackend,
    required this.coordinatorModel,
    required this.isDelegated,
    required this.summaryRationale,
    required this.subTasks,
  });

  final String originalPrompt;
  final BackendType coordinatorBackend; // 항상 BackendType.antigravity
  final String coordinatorModel;
  final bool isDelegated;
  final String summaryRationale;
  final List<OrchestratedSubTask> subTasks;
}

/// 백그라운드 지시·요약은 모두 Google Antigravity(`agy`)가 전담하고,
/// 별도 지시나 구현/리뷰 특화 작업은 Antigravity 에이전트 판단 하에
/// Claude Code 또는 Codex로 오케스트레이션(위임·병렬 실행)하는 정책 엔진입니다.
class AgentOrchestrator {
  const AgentOrchestrator({
    this.coordinatorModel = 'gemini-3.8-flash-high',
    this.backgroundSummaryModel = 'gemini-3-flash',
  });

  /// 모든 백그라운드 지시 및 요약의 고정 백엔드 (항상 Antigravity)
  static const BackendType backgroundBackend = BackendType.antigravity;

  final String coordinatorModel;
  final String backgroundSummaryModel;

  /// 프롬프트를 분석하여 Antigravity가 직접 처리할지, Claude Code / Codex로 위임 또는 분할 오케스트레이션할지 결정합니다.
  OrchestrationPlan evaluatePrompt(
    String prompt, {
    bool autoOrchestrate = true,
    BackendType? manualSelectedBackend,
    String? manualSelectedModel,
  }) {
    final trimmed = prompt.trim();
    final lower = trimmed.toLowerCase();

    // 1. 백그라운드 작업 / 요약 / 메일·메시지 관련 작업은 언제나 Antigravity가 직접 처리
    final isBackgroundOrSummary = _matchesAny(lower, const [
      '요약',
      '브리핑',
      '백그라운드',
      '메일',
      '메시지',
      'inbox',
      '알림',
      '정리해',
      'summarize',
      'summary',
    ]);

    if (isBackgroundOrSummary &&
        !_hasExplicitBackendMention(lower, BackendType.claudeCode) &&
        !_hasExplicitBackendMention(lower, BackendType.codex)) {
      return OrchestrationPlan(
        originalPrompt: trimmed,
        coordinatorBackend: BackendType.antigravity,
        coordinatorModel: coordinatorModel,
        isDelegated: false,
        summaryRationale:
            '백그라운드 지시 및 요약 작업이므로 기본 지휘 에이전트인 Google Antigravity가 직접 수행합니다.',
        subTasks: [
          OrchestratedSubTask(
            title: '백그라운드·요약 수행',
            targetBackend: BackendType.antigravity,
            targetModel: coordinatorModel,
            role: OrchestrationRole.antigravityMaster,
            prompt: trimmed,
            rationale: '백그라운드 및 요약 전담 원칙 적용',
          ),
        ],
      );
    }

    // 2. 사용자가 자동 오케스트레이션을 끄고 특정 백엔드를 수동 지정한 경우
    if (!autoOrchestrate && manualSelectedBackend != null) {
      final model = manualSelectedModel ?? manualSelectedBackend.defaultModel;
      return OrchestrationPlan(
        originalPrompt: trimmed,
        coordinatorBackend: BackendType.antigravity,
        coordinatorModel: coordinatorModel,
        isDelegated: manualSelectedBackend != BackendType.antigravity,
        summaryRationale:
            '사용자 수동 백엔드 지정(${manualSelectedBackend.displayName})에 따라 실행합니다.',
        subTasks: [
          OrchestratedSubTask(
            title: '${manualSelectedBackend.displayName} 지정 작업',
            targetBackend: manualSelectedBackend,
            targetModel: model,
            role: _roleForBackend(manualSelectedBackend),
            prompt: trimmed,
            rationale: '사용자 직접 백엔드 선택',
          ),
        ],
      );
    }

    // 3. 프롬프트 내 명시적 지시(@claude / 클로드 / @codex / 코덱스) 또는 작업 성격에 따른 Antigravity 오케스트레이션 판단
    final explicitClaude = _hasExplicitBackendMention(
      lower,
      BackendType.claudeCode,
    );
    final explicitCodex = _hasExplicitBackendMention(lower, BackendType.codex);

    final needsImplementation =
        explicitClaude ||
        _matchesAny(lower, const [
          '구현',
          '작성',
          '리팩터링',
          '리팩토링',
          '기능 추가',
          '컴포넌트 만들어',
          '클래스 추가',
          'implement',
          'refactor',
        ]);

    final needsReview =
        explicitCodex ||
        _matchesAny(lower, const [
          '리뷰',
          '코드 리뷰',
          '코드리뷰',
          '보안 감사',
          '취약점',
          '검증',
          '버그 찾아',
          'review',
          'audit',
        ]);

    // 3-A. 복합 작업: 구현(Claude Code) + 리뷰/검증(Codex) 동시 오케스트레이션
    if (needsImplementation && needsReview) {
      return OrchestrationPlan(
        originalPrompt: trimmed,
        coordinatorBackend: BackendType.antigravity,
        coordinatorModel: coordinatorModel,
        isDelegated: true,
        summaryRationale:
            'Antigravity 오케스트레이터 판단: 복합 요청(구현 + 리뷰)을 감지하여 구현은 Claude Code에, 리뷰·검증은 OpenAI Codex에 병렬 위임합니다.',
        subTasks: [
          OrchestratedSubTask(
            title: '구현 위임 (Claude Code)',
            targetBackend: BackendType.claudeCode,
            targetModel: BackendType.claudeCode.defaultModel,
            role: OrchestrationRole.claudeImplementation,
            prompt: '[Antigravity 오케스트레이션 - 구현 담당] $trimmed',
            rationale: '코드 구현 및 리팩터링 특화 에이전트 위임',
          ),
          OrchestratedSubTask(
            title: '리뷰·검증 위임 (Codex)',
            targetBackend: BackendType.codex,
            targetModel: BackendType.codex.defaultModel,
            role: OrchestrationRole.codexReview,
            prompt: '[Antigravity 오케스트레이션 - 리뷰 및 보안 검증 담당] $trimmed',
            rationale: '코드 리뷰 및 정적 검증 특화 에이전트 위임',
          ),
        ],
      );
    }

    // 3-B. 구현 특화 또는 @claude 명시 지시 -> Claude Code로 위임
    if (needsImplementation) {
      return OrchestrationPlan(
        originalPrompt: trimmed,
        coordinatorBackend: BackendType.antigravity,
        coordinatorModel: coordinatorModel,
        isDelegated: true,
        summaryRationale: explicitClaude
            ? '사용자의 별도 Claude Code 지시를 감지하여 Antigravity가 Claude Code 세션으로 위임합니다.'
            : 'Antigravity 오케스트레이터 판단: 코드 구현·리팩터링 작업이므로 Claude Code로 위임합니다.',
        subTasks: [
          OrchestratedSubTask(
            title: '구현 위임 (Claude Code)',
            targetBackend: BackendType.claudeCode,
            targetModel: BackendType.claudeCode.defaultModel,
            role: OrchestrationRole.claudeImplementation,
            prompt: trimmed,
            rationale: explicitClaude ? '사용자 별도 지시(@claude)' : '구현/리팩터링 자동 위임',
          ),
        ],
      );
    }

    // 3-C. 리뷰/검증 특화 또는 @codex 명시 지시 -> OpenAI Codex로 위임
    if (needsReview) {
      return OrchestrationPlan(
        originalPrompt: trimmed,
        coordinatorBackend: BackendType.antigravity,
        coordinatorModel: coordinatorModel,
        isDelegated: true,
        summaryRationale: explicitCodex
            ? '사용자의 별도 Codex 지시를 감지하여 Antigravity가 OpenAI Codex 세션으로 위임합니다.'
            : 'Antigravity 오케스트레이터 판단: 코드 리뷰·검증 작업이므로 OpenAI Codex로 위임합니다.',
        subTasks: [
          OrchestratedSubTask(
            title: '리뷰 위임 (Codex)',
            targetBackend: BackendType.codex,
            targetModel: BackendType.codex.defaultModel,
            role: OrchestrationRole.codexReview,
            prompt: trimmed,
            rationale: explicitCodex ? '사용자 별도 지시(@codex)' : '코드 리뷰/감사 자동 위임',
          ),
        ],
      );
    }

    // 3-D. 그 외 모든 기본/백그라운드 작업은 Antigravity가 직접 수행
    return OrchestrationPlan(
      originalPrompt: trimmed,
      coordinatorBackend: BackendType.antigravity,
      coordinatorModel: coordinatorModel,
      isDelegated: false,
      summaryRationale:
          'Antigravity 오케스트레이터 판단: 기본 에이전트(Google Antigravity)가 직접 수행합니다.',
      subTasks: [
        OrchestratedSubTask(
          title: 'Antigravity 직접 수행',
          targetBackend: BackendType.antigravity,
          targetModel: coordinatorModel,
          role: OrchestrationRole.antigravityMaster,
          prompt: trimmed,
          rationale: '기본 Antigravity 에이전트 수행',
        ),
      ],
    );
  }

  static OrchestrationRole _roleForBackend(BackendType backend) {
    switch (backend) {
      case BackendType.antigravity:
        return OrchestrationRole.antigravityMaster;
      case BackendType.claudeCode:
        return OrchestrationRole.claudeImplementation;
      case BackendType.codex:
        return OrchestrationRole.codexReview;
    }
  }

  static bool _hasExplicitBackendMention(String lower, BackendType backend) {
    switch (backend) {
      case BackendType.antigravity:
        return _matchesAny(lower, const ['@agy', '@antigravity', '안티그래비티']);
      case BackendType.claudeCode:
        return _matchesAny(lower, const [
          '@claude',
          '클로드에게',
          '클로드로',
          '클로드한테',
          'claude code로',
          'claude에게',
        ]);
      case BackendType.codex:
        return _matchesAny(lower, const [
          '@codex',
          '코덱스에게',
          '코덱스로',
          '코덱스한테',
          'codex로',
          'codex에게',
        ]);
    }
  }

  static bool _matchesAny(String text, List<String> keywords) {
    return keywords.any((k) => text.contains(k));
  }
}
