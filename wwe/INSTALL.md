# INSTALL

이 문서는 humanize-docs를 처음부터 설치·구성하는 절차를 다룬다. 스킬 자체의 개념과 사용법은 README.md를, 옵션 전체 목록은 `SKILL.md`의 §옵션 절을 참고한다.

## 준비물

Claude Code가 설치되어 있어야 한다. Skill을 지원하는 버전이면 특정 버전에 매이지 않는다. 저장소를 받을 git과 검사 스크립트를 실행할 Python 3도 필요하다. Astra 최종 퇴고를 선택할 기기에는 Codex CLI 설치·인증과 `gpt-6-astra` 접근이 추가로 필요하다. `codex --version`, `codex login status`, `codex exec --help`로 확인한다.

## 1. 스킬 설치

이 스킬은 `idoyo7/skills` 저장소의 `wwe/` 에 있다(예전 표준 저장소 `idoyo7/humanize-docs` 는 여기로 합쳐졌다). 저장소를 원하는 곳에 클론하고 `install.sh` 를 돌린다.

```bash
git clone https://github.com/idoyo7/skills.git ~/src/skills
cd ~/src/skills && bash install.sh
```

`install.sh` 가 `~/.claude/skills/` 에 심링크를 건다. 저장소를 어디에 두든 상관없다 — 스크립트가 자기 위치를 기준으로 경로를 잡는다.

## 2. 보존 윤문 의존성 설치

Claude Code 안에서 다음을 실행한다.

```
/plugin install humanize-korean@im-not-ai
```

문장 축 윤문 엔진과 monolith·diagnostician·finalizer 에이전트가 이 플러그인에 들어 있고, humanize-docs 저장소 자체에는 포함돼 있지 않다. 이 단계를 건너뛰면 보존 윤문(Phase 5 이후)이 동작하지 않는다. 구조 재작성 경로는 humanize-korean 없이 실행한다.

## 3. 설치 확인

두 단계로 확인한다.

첫째, 스킬 자체 스크립트 검증이다. 저장소 루트에서:

```bash
bash wwe/tests/run.sh
```

md_shield·llm_signature·heading_anchor·author_repeat·slop_scan 다섯 하네스가 순서대로 돌며 전부 통과해야 한다(`OK`가 다섯 번). 이 테스트는 humanize-korean 플러그인 없이도 통과한다 — LLM 호출 없이 마스킹·복원·지문 채점·앵커 재계산·반복 구절 검출 로직만 검증하기 때문이다.

v1.3에서 추가된 파일은 저장소 클론 시 함께 받아진다: `scripts/author_repeat.py`(반복 구절 검출), `references/author-tics.txt`(장르별 시드 목록), `references/author-repeat-stop.txt`(불용어 목록), `tests/test_author_repeat.py`(테스트 하네스). 별도 설치 단계는 없다.

연동: `~/.claude/hooks/reply-check.py`가 `references/author-tics.txt`를 읽어 답변 단위 시드 검사를 수행한다.

둘째, Claude Code 안에서의 스모크 테스트다. .md 파일 한두 개가 있는 디렉토리에서 "지문만 봐줘"라고 요청한다. 이 옵션은 윤문 없이 `llm_signature.py score`만 돌려 레이아웃 지문 등급을 보여주므로 LLM 콜이 들지 않는다. humanize-korean이 아직 없어도 이 요청 자체는 실행되지만, 보존 윤문을 요청하면 Phase 0에서 플러그인 미설치를 감지해 에러와 함께 설치 명령을 안내한다.

## 4. 업데이트

```bash
git -C ~/src/skills switch main
git -C ~/src/skills pull --ff-only origin main
bash ~/src/skills/install.sh
bash ~/src/skills/wwe/tests/run.sh
```

`~/src/skills`는 실제 클론 경로로 바꾼다. 최신 배포 브랜치는 `main`이며, wwe 버전은 `wwe/SKILL.md`의 `version`에서 확인한다. 현재 배포 버전은 1.7.1이다. 심링크 설치는 저장소 업데이트가 그대로 반영되며, `install.sh`는 누락된 링크를 보완한다. 로컬 수정 때문에 전환이나 fast-forward가 실패하면 변경을 보존하고 원인을 확인한다. `reset --hard`로 덮어쓰지 않는다.

다른 기기도 각자의 클론에서 같은 절차로 업데이트한다. 스킬 내용은 git으로 갱신되지만 Codex 로그인·모델 접근·권한은 기기별 설정이다. 업데이트 과정에서 full access나 승인 정책을 자동 변경하지 않는다. 이미 열린 Claude 대화가 이전 스킬을 읽었다면 새 대화에서 `/wwe`를 호출해 새 버전을 사용한다.

## 자주 걸리는 것

humanize-korean 미설치 상태로 보존 윤문을 요청하면 `ERROR: humanize-korean 미설치 — /plugin install humanize-korean@im-not-ai` 메시지와 함께 중단된다. 안내된 명령을 그대로 실행하면 된다.

여러 머신에서 쓰려면 머신마다 1~2단계를 반복해야 한다. 스킬 저장소를 클론하는 것과 플러그인을 설치하는 것은 별개 작업이라, 보존 윤문은 둘 다 필요하다.

`tests/`의 일부 테스트는 실물 문서 코퍼스가 있을 때만 켜지는 선택 항목이다. `HUMANIZE_DOCS_REAL_CORPUS_ROOT` 환경변수로 그 루트를 지정해야 실행되며, 지정하지 않으면 skip 처리될 뿐 실패로 잡히지 않는다. 일반 사용에는 필요 없다.
