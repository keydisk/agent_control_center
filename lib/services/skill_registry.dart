import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/models/agent_models.dart';
import 'app_settings_store.dart';
import 'session_context.dart';

class SkillDefinition {
  SkillDefinition({
    required this.name,
    required this.description,
    required this.skillMdPath,
    required this.directoryPath,
    this.routingSummary = '',
    this.requiredPermissions = const [],
    this.isEnabled = true,
    Set<BackendType>? syncedBackends,
  }) : syncedBackends = syncedBackends ?? {...BackendType.values};

  final String name;
  final String description;
  final String skillMdPath;
  final String directoryPath;
  final String routingSummary;
  final List<String> requiredPermissions;
  bool isEnabled;
  final Set<BackendType> syncedBackends;
}

class SkillRoutingMatch {
  const SkillRoutingMatch({
    required this.skill,
    required this.reason,
  });

  final SkillDefinition skill;
  final String reason;
}

/// 전 백엔드(`agy`, `claude`, `codex`) 공통 스킬 레지스트리 및 라우팅 엔진
class SkillRegistry extends ChangeNotifier {
  SkillRegistry({
    Map<BackendType, String>? backendSkillDirs,
    bool loadDefaults = true,
    this.settings,
  }) : _backendSkillDirs = backendSkillDirs ?? _defaultBackendSkillDirs() {
    if (loadDefaults) {
      _registerBuiltInCoreSkills();
    }
  }

  /// null이면 스킬 켜기/끄기를 기억하지 않습니다.
  final AppSettingsStore? settings;
  final Map<BackendType, String> _backendSkillDirs;
  final Map<String, SkillDefinition> _skills = {};

  List<SkillDefinition> get skills => _skills.values.toList(growable: false);

  SkillDefinition? getSkill(String name) => _skills[name];

  static Map<BackendType, String> _defaultBackendSkillDirs() {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return {
      BackendType.antigravity: p.join(home, '.gemini', 'config', 'skills'),
      BackendType.claudeCode: p.join(home, '.claude', 'skills'),
      BackendType.codex: p.join(home, '.codex', 'skills'),
    };
  }

  void _registerBuiltInCoreSkills() {
    final home = Platform.environment['HOME'] ?? '/Users/juyoungchoi';
    final egoDir = p.join(home, '.gemini', 'config', 'skills', 'ego-browser');
    final cliHubDir = p.join(
      home,
      '.gemini',
      'config',
      'skills',
      'cli-hub-meta-skill',
    );

    registerSkill(
      SkillDefinition(
        name: 'ego-browser',
        description:
            '웹사이트 열기, 검색, 폼 입력, 클릭, 스크린샷, 스크래핑 및 브라우저 자동화를 수행하는 Chromium 기반 에이전트 브라우저 스킬입니다.',
        skillMdPath: p.join(egoDir, 'SKILL.md'),
        directoryPath: egoDir,
        routingSummary: '웹 관련 작업(검색, 페이지 열기, 폼 입력, 스크래핑) → ego-browser 자동 라우팅',
        requiredPermissions: const [
          '사이트 네트워크 접근 (URL 단위 승인)',
          '로컬 프로세스 실행 (ego-browser CLI)',
          '쿠키/캐시 초기화 시 파괴적 작업 매번 확인',
        ],
      ),
    );

    registerSkill(
      SkillDefinition(
        name: 'cli-hub-meta-skill',
        description:
            'Blender, GIMP, LibreOffice 등 외부 소프트웨어용 에이전트 네이티브 CLI 하네스를 검색·설치·실행하는 메타 스킬입니다.',
        skillMdPath: p.join(cliHubDir, 'SKILL.md'),
        directoryPath: cliHubDir,
        routingSummary:
            '별도 소프트웨어/외부 CLI 실행이 필요한 작업 → cli-hub-meta-skill 자동 라우팅',
        requiredPermissions: const [
          '외부 프로그램 검색/설치/실행 (프로그램 단위 승인)',
          '네트워크 레지스트리 조회 (cli-hub search/info)',
        ],
      ),
    );
  }

  void registerSkill(SkillDefinition skill) {
    if (settings?.isSkillDisabled(skill.name) ?? false) skill.isEnabled = false;
    _skills[skill.name] = skill;
    notifyListeners();
  }

  void setSkillEnabled(String name, bool enabled) {
    final s = _skills[name];
    if (s == null) return;
    s.isEnabled = enabled;
    settings?.setSkillDisabled(name, !enabled);
    notifyListeners();
  }

  /// SKILL.md 파일의 YAML frontmatter에서 name과 description을 파싱합니다.
  static SkillDefinition? parseSkillMdFile(File skillMdFile) {
    if (!skillMdFile.existsSync()) return null;
    final content = skillMdFile.readAsStringSync();
    final dirPath = skillMdFile.parent.path;
    String name = p.basename(dirPath);
    String description = '';

    final fmMatch = RegExp(
      r'^---\s*\n([\s\S]*?)\n---',
      multiLine: true,
    ).firstMatch(content);
    if (fmMatch != null) {
      final yamlBlock = fmMatch.group(1) ?? '';
      for (final line in yamlBlock.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('name:')) {
          name = trimmed.substring('name:'.length).trim().replaceAll('"', '');
        } else if (trimmed.startsWith('description:')) {
          description = trimmed
              .substring('description:'.length)
              .trim()
              .replaceAll('"', '');
        }
      }
    }
    return SkillDefinition(
      name: name,
      description: description.isNotEmpty ? description : '$name 스킬',
      skillMdPath: skillMdFile.path,
      directoryPath: dirPath,
    );
  }

  /// 로컬 스킬 디렉터리들을 스캔하여 SKILL.md를 등록합니다.
  Future<void> discoverLocalSkills() async {
    for (final entry in _backendSkillDirs.entries) {
      final rootDir = Directory(entry.value);
      if (!rootDir.existsSync()) continue;
      for (final entity in rootDir.listSync(followLinks: true)) {
        if (entity is Directory) {
          final mdFile = File(p.join(entity.path, 'SKILL.md'));
          if (mdFile.existsSync()) {
            final parsed = parseSkillMdFile(mdFile);
            if (parsed != null && !_skills.containsKey(parsed.name)) {
              _skills[parsed.name] = parsed;
            }
          }
        }
      }
    }
    notifyListeners();
  }

  /// 세션 압축 스킬을 설치하고 3대 백엔드 스킬 폴더에 연결합니다. 기존 항목은 덮어쓰지 않습니다.
  Future<void> installHandoffSkill(String rootDir) async {
    final dir = await Directory(
      p.join(rootDir, handoffSkillName),
    ).create(recursive: true);
    final skillMd = File(p.join(dir.path, 'SKILL.md'));
    await skillMd.writeAsString(handoffSkillMarkdown);
    registerSkill(parseSkillMdFile(skillMd)!);
    for (final backendDir in _backendSkillDirs.values) {
      await Directory(backendDir).create(recursive: true);
      final target = p.join(backendDir, handoffSkillName);
      if (FileSystemEntity.typeSync(target, followLinks: false) ==
          FileSystemEntityType.notFound) {
        await Link(target).create(dir.path);
      }
    }
  }

  /// 활성화된 스킬을 3대 백엔드(`agy`, `claude`, `codex`) 스킬 폴더에 심볼릭 링크로 동기화합니다.
  Future<int> syncSkillsAcrossBackends() async {
    var syncedCount = 0;
    for (final skill in _skills.values) {
      if (!skill.isEnabled) continue;
      final sourceDir = Directory(skill.directoryPath);
      if (!sourceDir.existsSync()) continue;

      for (final entry in _backendSkillDirs.entries) {
        final targetRoot = Directory(entry.value);
        if (!targetRoot.existsSync()) {
          await targetRoot.create(recursive: true);
        }
        final targetPath = p.join(targetRoot.path, skill.name);
        if (p.equals(targetPath, sourceDir.path)) {
          skill.syncedBackends.add(entry.key);
          continue;
        }
        final existingType = FileSystemEntity.typeSync(
          targetPath,
          followLinks: false,
        );
        if (existingType == FileSystemEntityType.notFound) {
          await Link(targetPath).create(sourceDir.path);
          syncedCount++;
        }
        skill.syncedBackends.add(entry.key);
      }
    }
    notifyListeners();
    return syncedCount;
  }

  /// 사용자 프롬프트를 분석하여 공통 라우팅 규칙(웹 → ego-browser, 외부 CLI → cli-hub-meta-skill)에 매칭되는 스킬을 반환합니다.
  List<SkillRoutingMatch> matchRoutedSkills(String prompt) {
    final matches = <SkillRoutingMatch>[];
    final lower = prompt.toLowerCase();

    final ego = _skills['ego-browser'];
    if (ego != null && ego.isEnabled) {
      final webKeywords = [
        'ego-browser',
        '/ego-browser',
        'http://',
        'https://',
        '웹',
        '브라우저',
        '사이트',
        '페이지 열기',
        '페이지 열어',
        '스크래핑',
        '크롤링',
        '폼 입력',
        '검색해',
        '웹검색',
      ];
      if (webKeywords.any((k) => lower.contains(k))) {
        matches.add(
          SkillRoutingMatch(
            skill: ego,
            reason: '웹 관련 작업(검색/페이지 열기/폼 입력/스크래핑) 라우팅 규칙',
          ),
        );
      }
    }

    final cliHub = _skills['cli-hub-meta-skill'];
    if (cliHub != null && cliHub.isEnabled) {
      final cliKeywords = [
        'cli-hub',
        '/cli-hub',
        'cli-anything',
        '외부 cli',
        '외부 소프트웨어',
        '프로그램 실행',
        '하네스',
        'blender',
        'gimp',
        'libreoffice',
        'inkscape',
        'audacity',
        'obs',
        'kdenlive',
        'shotcut',
      ];
      if (cliKeywords.any((k) => lower.contains(k))) {
        matches.add(
          SkillRoutingMatch(
            skill: cliHub,
            reason: '별도 소프트웨어/외부 CLI 실행 라우팅 규칙',
          ),
        );
      }
    }

    // 그 외 명시적으로 스킬 이름이 언급된 활성 스킬 매칭
    for (final s in _skills.values) {
      if (!s.isEnabled) continue;
      if (s.name == 'ego-browser' || s.name == 'cli-hub-meta-skill') continue;
      if (lower.contains(s.name.toLowerCase())) {
        matches.add(
          SkillRoutingMatch(
            skill: s,
            reason: '프롬프트 내 스킬 명시적 호출',
          ),
        );
      }
    }

    return matches;
  }

  /// 모든 백엔드에 공통으로 주입할 스킬 라우팅 시스템 지시문을 생성합니다.
  String buildRoutingInstructionForPrompt(String prompt) {
    final matches = matchRoutedSkills(prompt);
    final egoEnabled = _skills['ego-browser']?.isEnabled ?? false;
    final cliHubEnabled = _skills['cli-hub-meta-skill']?.isEnabled ?? false;

    final buffer = StringBuffer()
      ..writeln('[SKILL ROUTING RULES - 전 백엔드 공통 규칙]');
    if (egoEnabled) {
      buffer.writeln(
        '- 웹 관련 작업(검색, 페이지 열기, 폼 입력, 스크래핑)은 반드시 `ego-browser` 스킬(${_skills['ego-browser']!.skillMdPath})을 사용하세요.',
      );
    }
    if (cliHubEnabled) {
      buffer.writeln(
        '- 별도 소프트웨어/외부 CLI 실행이 필요한 작업은 반드시 `cli-hub-meta-skill` 스킬(${_skills['cli-hub-meta-skill']!.skillMdPath})을 사용하세요.',
      );
    }
    for (final m in matches) {
      buffer.writeln(
        '- 현재 요청에 대해 `${m.skill.name}` 스킬(${m.skill.skillMdPath})이 자동 라우팅되었습니다 (${m.reason}).',
      );
    }
    return buffer.toString().trim();
  }
}
