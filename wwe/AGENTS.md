# AGENTS

이 파일은 AI 에이전트(Claude Code 등)를 대상으로 쓴다. 사용자가 "이 저장소 받아서 스킬로 설정해줘"라고 요청하면, 아래 절차를 그대로 따라 자율적으로 설치·검증하고 결과를 사용자에게 보고한다. 사람이 읽는 설치 가이드는 INSTALL.md다.

## 이 저장소가 무엇인가

wwe는 실행 파일이 아니라 Claude Code가 읽는 스킬이다. v1.5부터 일반 윤문은 보존 파이프라인, 전개까지 다시 쓰는 요청은 구조 편집 경로로 처리한다. `SKILL.md`에 파이프라인 지시문이, `scripts/`에 그 지시문이 호출하는 결정적 스크립트(마스킹·복원·지문 채점·앵커 재계산·작성자 반복 구절 검출)가 들어 있다. 클론해서 올바른 경로에 두는 것만으로 설치가 끝나고, 별도 빌드나 실행 데몬은 없다.

주요 파일:

- `scripts/md_shield.py` — 마스킹·복원·구조 검증
- `scripts/llm_signature.py` — 레이아웃 지문 스코어러(L1~L14)
- `scripts/heading_anchor.py` — 헤딩 슬러그 재계산·앵커 치환·게이트 D
- `scripts/scan_docs.py` — 문서 분류(한글 비율·산문량·route_hint)
- `scripts/author_repeat.py` — 작성자 반복 구절 검출·gen-block 생성(v1.3)
- `references/docs-profile.md` — 보존 모드 전용 윤문 오버라이드
- `references/structure-editing.md` — 구조 재작성·내용 보존·사이트 링크 검증 가이드(v1.5)
- `references/author-tics.txt` — 장르별 반복 구절 시드 목록(v1.3)
- `references/author-repeat-stop.txt` — 검출 시 걸러낼 불용어 목록(v1.3)
- `tests/test_author_repeat.py` — 작성자 반복 구절 테스트 하네스(v1.3)
- `scripts/slop_scan.py` — 초안 관문(게이트 S) 스캐너(v1.4)
- `references/slop-lexicon.txt` — 초안 관문 결정적 층 사전(v1.4)
- `references/slop-gate.md` — 초안 관문 LLM 층 지침(v1.4)
- `agents/wwe-slop-judge.md` — 정밀 모드 전용 비저자 판정 에이전트(v1.4)

## 설치 절차

먼저 설치 범위를 판단한다. 사용자가 범위를 지정했으면(예: "이 프로젝트에만") 그대로 따르고, 지정하지 않았으면 사용자 레벨(`~/.claude/skills/humanize-docs`)을 기본값으로 삼되 진행 전에 한 번 확인을 받는다 — 모든 프로젝트에서 쓸지, 현재 프로젝트에만 쓸지는 사용자의 작업 습관에 관한 선택이라 임의로 정하지 않는다.

대상 경로에 이미 저장소가 있으면 clone 대신 pull로 갱신한다.

```bash
# 신규 설치 — 클론 위치는 자유, install.sh 가 심링크를 건다
git clone https://github.com/idoyo7/skills.git ~/src/skills
cd ~/src/skills && bash install.sh

# 이미 존재하면 갱신
git -C <저장소> pull && bash <저장소>/install.sh
```

`install.sh`는 스킬 심링크에 이어 `*/agents/*.md`를 `~/.claude/agents/`에 심링크한다. wwe의 `wwe-slop-judge`가 여기에 걸려야 정밀 모드의 초안 관문 판정이 돈다. 같은 이름의 실파일이 있으면 건너뛰고 알리므로, 그 메시지가 보이면 사용자에게 전달한다.

## 의존성 확인

보존 윤문 파이프라인은 humanize-korean 플러그인에 의존한다. 보존 모드를 설치·검증할 때 존재 여부를 확인한다. 구조 재작성 경로는 이 플러그인을 요구하지 않는다.

```bash
ls ~/.claude/plugins/cache/im-not-ai/humanize-korean/*/ 2>/dev/null
```

출력이 없으면 플러그인이 없는 것이다. 플러그인 설치는 사용자 승인이 필요한 영역이므로 직접 설치를 시도하지 말고, 사용자에게 Claude Code 안에서 `/plugin install humanize-korean@im-not-ai`를 실행하도록 안내한다.

## 검증

저장소 루트에서 테스트 하네스를 돌린다.

```bash
bash tests/run.sh
```

md_shield·llm_signature·heading_anchor·author_repeat·slop_scan 다섯 하네스가 순서대로 실행되며 전부 통과해야 한다. 이 테스트는 humanize-korean 플러그인이 없어도 통과한다(LLM 호출 없이 스킬 자체 로직만 검증). 결과(통과/실패 개수, 실패가 있다면 어느 하네스인지)를 사용자에게 그대로 보고한다.

## 사용 시 알아야 할 것

사용자는 “이 디렉토리 문서 윤문해줘”, “정밀 모드로 다듬어줘”, “글 구조부터 다시 써줘”처럼 요청한다. 일반 윤문은 파일당 LLM 1콜의 보존 경제 모드가 기본이고 정밀 모드는 그 상한을 해제한다. 구조 재작성 요청은 SKILL.md의 첫 라우팅에서 별도 가이드로 보내며, 기존 미완료 run 재개 질문과 보존 게이트를 거치지 않는다.

수정 대상과 제자리 편집이 이미 요청됐다면 다시 허가받지 않고 검증한 후보를 적용한다. 검사·미리보기만 요청하면 원본을 유지한다. 보존 모드의 중단은 “이어서”, 완료 run의 보류 항목은 “보류 재시도”로 처리한다. 구조 편집의 완료 여부는 지문 점수 대신 원본·후보 대조와 실제 사이트 검증으로 판단한다.

## 하지 말 것

설치·윤문 작업 중 `SKILL.md`와 `scripts/`를 임의로 고치지 않는다. 사용자가 스킬 자체의 수정·개발을 명시적으로 요청한 경우에는 요청 범위에서 변경하고 검증한다. 일반 배포 업데이트는 `git pull`로 받는다. humanize-korean 플러그인의 콘텐츠(quick-rules, 에이전트 정의 등)를 이 저장소로 복사해 오지 않는다 — 두 저장소는 별도로 유지된다. `_workspace/`는 실행 중 생기는 산출물 디렉토리이므로 커밋 대상이 아니다.
