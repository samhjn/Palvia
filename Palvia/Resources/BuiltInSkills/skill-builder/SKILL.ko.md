---
display_name: 스킬 빌더
description: fs.* 브리지로 Palvia 스킬을 직접 작성하고 편집합니다. 스캐폴딩, 도구/스크립트 생성기, 검증, 참고 예제를 포함합니다.
---
# 스킬 빌더(Skill Builder)

사용자가 Palvia 스킬을 만들거나 수정하거나 포크해 달라고 할 때 이 스킬을 사용하세요.
Palvia 스킬은 `/skills/<slug>/` 아래의 디렉터리이며, `fs.*` 브리지로 작성합니다 —
`create_skill`/`edit_skill` 같은 LLM 도구는 없습니다. 표준 구조는
`references/example-tooled.md`에 정리되어 있습니다.

## 작성 플로우(권장 경로)

1. **slug를 정하세요.** 소문자, 하이픈으로 연결, 중복되지 않게. 기존 slug는
   `fs.list('skills')`와 `list_skills`로 확인합니다. slug는 안정 식별자이므로
   바꾸면 해당 스킬을 설치한 에이전트가 깨집니다.
2. **스캐폴딩.** `skill_skill_builder_scaffold(slug, name, description, tags?)`
   을 호출하세요. 최소한의 유효한 `SKILL.md`와 빈 `tools/`, `scripts/`
   디렉터리를 한 번에 만들어 줍니다.
3. **도구 추가(함수 호출 도구).** 각 도구마다
   `skill_skill_builder_add_tool(slug, tool_name, description, parameters?)`
   를 호출하세요. `tools/<tool_name>.js`에 입력값으로 채워진 META 선언과
   `TODO` 본문을 작성합니다. `fs.writeFile`로 본문을 실제 구현으로 교체하세요.
4. **스크립트 추가(선택, `run_snippet`에서 호출되는 헬퍼).**
   `skill_skill_builder_add_script(slug, script_name, description)`을 호출하세요.
   같은 패턴: 템플릿이 생성되고 `fs.writeFile`로 본문을 교체합니다.
5. **검증.** `validate_skill(slug=...)`는 자동 리로드 경로와 같은 Swift 측
   parser를 실행합니다. 설치 전에 error는 모두 해결하세요. warning은 참고용입니다.
6. **설치.** `install_skill(name=<frontmatter 의 name>)`. Palvia가 디스크의
   패키지로부터 `Skill` 행을 만들어 현재 에이전트에 바인딩합니다. 커스텀 도구는
   즉시 `skill_<slug>_<tool>` 이름으로 호출 가능해집니다.

## 기존 스킬 편집

1. **먼저 읽기.** `fs.readFile('skills/<slug>/SKILL.md')`로 관련 없는 내용을
   덮어쓰지 않도록 합니다.
2. **쓰기.** `fs.writeFile('skills/<slug>/...')`. 쓰기에 성공하면 자동 리로드가
   동작합니다. 파싱이 깨졌다면 마지막으로 정상 동작하던 버전이 그대로 유지되며,
   고치기 전까지 그 버전으로 계속 동작합니다.
3. **다시 검증.** 편집 묶음마다 `validate_skill(slug=...)`을 실행하세요.
4. **재설치 불필요.** 캐시된 Skill 행은 자동으로 갱신됩니다. slug 이름 변경만큼은
   언인스톨 후 재설치가 필요합니다.

## 빌트인 스킬 포크

빌트인 스킬(`BuiltInSkills.shippedSlugs`에 포함된 slug)은 읽기 전용입니다.
수정 전에 포크하세요:

    fs.cp('skills/deep-research', 'skills/my-research', { recursive: true });

복사본은 `<Documents>/Skills/` 아래에 생기고, 완전히 쓰기 가능합니다. 이후로는
평소처럼 편집·검증·`install_skill`을 진행합니다.

## 권한 안내

`/skills/<slug>/`에 쓰기를 하려면 동작 자체에 필요한 권한(예: `files.writeFile`)
외에 에이전트 단위의 `fs_skill_write` 권한이 추가로 필요합니다. `fs_skill_write`
가 없는 에이전트는 패키지 읽기와 이미 설치된 스킬 사용은 가능하지만, 새로 작성
하거나 수정할 수는 없습니다.

## 더 보기

- `references/example-simple.md` — 도구/스크립트 없이 설명문만 있는 최소 스킬 예제.
- `references/example-tooled.md` — 도구 1개와 스크립트 1개를 가진 완전한 스킬 예제.
