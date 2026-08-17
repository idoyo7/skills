# INSTALL

이 문서는 humanize-docs를 처음부터 설치·구성하는 절차를 다룬다. 스킬 자체의 개념과 사용법은 README.md를, 옵션 전체 목록은 `SKILL.md`의 §옵션 절을 참고한다.

## 준비물

Claude Code가 설치되어 있어야 한다. Skill을 지원하는 버전이면 특정 버전에 매이지 않는다. 그 외에는 이 저장소를 받을 git만 있으면 된다.

## 1. 스킬 설치

두 경로 중 하나를 고른다. 모든 프로젝트에서 쓰고 싶으면 사용자 레벨로, 특정 프로젝트에서만 쓰려면 프로젝트 레벨로 클론한다.

사용자 레벨:

```bash
git clone https://github.com/idoyo7/humanize-docs.git ~/.claude/skills/humanize-docs
```

프로젝트 레벨:

```bash
git clone https://github.com/idoyo7/humanize-docs.git <프로젝트>/.claude/skills/humanize-docs
```

## 2. 의존성 설치

Claude Code 안에서 다음을 실행한다.

```
/plugin install humanize-korean@im-not-ai
```

문장 축 윤문 엔진과 monolith·diagnostician·finalizer 에이전트가 이 플러그인에 들어 있고, humanize-docs 저장소 자체에는 포함돼 있지 않다. 이 단계를 건너뛰면 실제 윤문(Phase 5 이후)이 동작하지 않는다.

## 3. 설치 확인

두 단계로 확인한다.

첫째, 스킬 자체 스크립트 검증이다. 저장소 루트에서:

```bash
bash tests/run.sh
```

md_shield·llm_signature·heading_anchor 세 하네스가 순서대로 돌며 총 42개 테스트가 전부 통과해야 한다(`OK`가 세 번). 이 테스트는 humanize-korean 플러그인 없이도 통과한다 — LLM 호출 없이 마스킹·복원·지문 채점·앵커 재계산 로직만 검증하기 때문이다.

둘째, Claude Code 안에서의 스모크 테스트다. .md 파일 한두 개가 있는 디렉토리에서 "지문만 봐줘"라고 요청한다. 이 옵션은 윤문 없이 `llm_signature.py score`만 돌려 레이아웃 지문 등급을 보여주므로 LLM 콜이 들지 않는다. humanize-korean이 아직 없어도 이 요청 자체는 실행되지만, 실제 윤문을 요청하면 Phase 0에서 플러그인 미설치를 감지해 에러와 함께 설치 명령을 안내한다.

## 4. 업데이트

```bash
git -C ~/.claude/skills/humanize-docs pull
```

프로젝트 레벨로 설치했다면 경로만 해당 프로젝트의 `.claude/skills/humanize-docs`로 바꾼다.

## 자주 걸리는 것

humanize-korean 미설치 상태로 윤문을 요청하면 `ERROR: humanize-korean 미설치 — /plugin install humanize-korean@im-not-ai` 메시지와 함께 중단된다. 안내된 명령을 그대로 실행하면 된다.

여러 머신에서 쓰려면 머신마다 1~2단계를 반복해야 한다. 스킬 저장소를 클론하는 것과 플러그인을 설치하는 것은 별개 작업이라, 한쪽만 해서는 동작하지 않는다.

`tests/`의 일부 테스트는 실물 문서 코퍼스가 있을 때만 켜지는 선택 항목이다. `HUMANIZE_DOCS_REAL_CORPUS_ROOT` 환경변수로 그 루트를 지정해야 실행되며, 지정하지 않으면 skip 처리될 뿐 실패로 잡히지 않는다. 일반 사용에는 필요 없다.
