import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/main.dart';
import 'package:agent_control_center/services/permission_center.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:agent_control_center/services/storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('7단계: 권한 센터, drift(SQLite) 영구 저장 및 백엔드별 키체인 분리 보관', () {
    test('AppDriftDatabase에 권한 규칙·감사 로그가 SQLite로 저장·복원되고 백엔드별 비밀값이 분리 보관된다', () async {
      final db = AppDriftDatabase();
      addTearDown(() async {
        await db.close();
      });
      final vault = SecureCredentialVault(useOsKeychain: false);
      final center1 = PermissionCenter(database: db, credentialVault: vault);

      // 1) 스킬별 사이트 접근 권한(ego-browser)을 '항상'으로 승인 기록
      final req = ApprovalRequestData(
        id: 'req_ego_1',
        sessionId: 's1',
        backend: BackendType.claudeCode,
        toolName: 'Bash',
        arguments: const {'command': 'ego-browser open https://github.com'},
        category: ApprovalCategory.skillSiteAccess,
        reason: 'ego-browser 사이트 접근',
        isDestructive: false,
        createdAt: DateTime.now(),
        targetResource: 'https://github.com',
      );
      center1.recordDecision(
        req,
        const ApprovalDecision(
          requestId: 'req_ego_1',
          approved: true,
          scope: ApprovalScope.always,
        ),
      );
      // 비동기 SQLite insert 완료 대기
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 2) 새로운 PermissionCenter 인스턴스에서 SQLite DB 로드 검증
      final center2 = PermissionCenter(database: db, credentialVault: vault);
      await center2.loadFromDatabase();
      expect(center2.rules.length, 1);
      expect(center2.rules.first.backend, BackendType.claudeCode);
      expect(center2.rules.first.targetResource, 'https://github.com');
      expect(center2.auditLogs, isNotEmpty);

      // 3) 백엔드별 비밀값(OAuth 토큰 / API 키) 분리 보관 검증
      await center2.setAccountScopePermission(
        scopeId: 'anthropic_api_key',
        scope: ApprovalScope.always,
        secretTokenValue: 'sk-ant-secret-123',
      );
      await center2.setAccountScopePermission(
        scopeId: 'openai_api_key',
        scope: ApprovalScope.always,
        secretTokenValue: 'sk-proj-openai-456',
      );

      expect(
        await vault.readBackendSecret(
          backend: BackendType.claudeCode,
          credentialName: 'anthropic_api_key',
        ),
        'sk-ant-secret-123',
      );
      expect(
        await vault.readBackendSecret(
          backend: BackendType.codex,
          credentialName: 'anthropic_api_key',
        ),
        isNull, // 다른 백엔드 네임스페이스에서는 접근 불가
      );
      expect(
        await vault.readBackendSecret(
          backend: BackendType.codex,
          credentialName: 'openai_api_key',
        ),
        'sk-proj-openai-456',
      );

      // 철회 시 비밀값 삭제 확인
      await center2.setAccountScopePermission(
        scopeId: 'anthropic_api_key',
        scope: ApprovalScope.denied,
      );
      expect(
        await vault.readBackendSecret(
          backend: BackendType.claudeCode,
          credentialName: 'anthropic_api_key',
        ),
        isNull,
      );
    });

    testWidgets('권한 센터 UI에서 백엔드별 필터, 권한 철회, 자동 승인 위험 확인 다이얼로그 및 감사 로그가 동작한다', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final permissionCenter = PermissionCenter();
      permissionCenter.recordDecision(
        ApprovalRequestData(
          id: 'r_claude',
          sessionId: 's1',
          backend: BackendType.claudeCode,
          toolName: 'Write',
          arguments: const {'file_path': 'lib/app.dart'},
          category: ApprovalCategory.fileWrite,
          reason: '파일 수정',
          isDestructive: false,
          createdAt: DateTime.now(),
          targetResource: 'lib/app.dart',
        ),
        const ApprovalDecision(
          requestId: 'r_claude',
          approved: true,
          scope: ApprovalScope.always,
        ),
      );

      final manager = SessionManager(permissionCenter: permissionCenter);

      await tester.pumpWidget(
        MaterialApp(
          home: ControlCenterHomeScreen(sessionManagerOverride: manager),
        ),
      );
      await tester.pumpAndSettle();

      // 상단 '권한 센터' 버튼 클릭
      await tester.tap(
        find.byKey(const ValueKey('open_permission_center_button')),
      );
      await tester.pumpAndSettle();

      final ruleId = permissionCenter.rules.first.id;
      expect(find.byKey(ValueKey('rule_card_$ruleId')), findsOneWidget);

      // 백엔드 필터: Codex 선택 시 Claude 규칙은 숨겨짐
      await tester.tap(find.byKey(const ValueKey('perm_filter_codex')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('rule_card_$ruleId')), findsNothing);

      // 다시 전체 필터 선택 후 권한 철회
      await tester.tap(find.byKey(const ValueKey('perm_filter_all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('revoke_rule_$ruleId')));
      await tester.pumpAndSettle();
      expect(permissionCenter.rules, isEmpty);

      // '자동 승인 모드 제어' 탭 이동 -> 기본 비활성 확인 및 위험 경고 다이얼로그 테스트
      await tester.tap(find.byKey(const ValueKey('tab_auto_bypass')));
      await tester.pumpAndSettle();

      expect(
        permissionCenter.isAutoBypassEnabled(BackendType.claudeCode),
        isFalse,
      );
      await tester.tap(
        find.byKey(const ValueKey('auto_bypass_switch_claude')),
      );
      await tester.pumpAndSettle();

      // 위험 확인 다이얼로그 노출 확인 및 승인 클릭
      expect(
        find.byKey(const ValueKey('confirm_auto_bypass_danger')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('confirm_auto_bypass_danger')),
      );
      await tester.pumpAndSettle();
      expect(
        permissionCenter.isAutoBypassEnabled(BackendType.claudeCode),
        isTrue,
      );

      // '감사 로그' 탭 이동 -> 승인/철회/자동승인 활성화 로그가 기록되어 있는지 확인
      await tester.tap(find.byKey(const ValueKey('tab_audit_logs')));
      await tester.pumpAndSettle();
      expect(permissionCenter.auditLogs.length, greaterThanOrEqualTo(3));

      manager.dispose();
    });
  });
}
