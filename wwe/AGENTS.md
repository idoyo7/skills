# AGENTS

이 파일은 AI 에이전트(Claude Code 등)를 대상으로 쓴다. 사용자가 "이 저장소 받아서 스킬로 설정해줘"라고 요청하면, 아래 절차를 그대로 따라 자율적으로 설치·검증하고 결과를 사용자에게 보고한다. 사람이 읽는 설치 가이드는 INSTALL.md다.

## 이 저장소가 무엇인가

humanize-docs는 실행 파일이 아니라 Claude Code가 읽는 스킬이다. `SKILL.md`에 파이프라인 지시문이, `scripts/`에 그 지시문이 호출하는 결정적 스크립트(마스킹·복원·지문 채점·앵커 재계산·작성자 반복 구절 검출)가 들어 있다. 클론해서 올바른 경로에 두는 것만으로 설치가 끝나고, 별도 빌드나 실행 데몬은 없다.

주요 파일:

- `scripts/md_shield.py` — 마스킹·복원·구조 검증
- `scripts/llm_signature.py` — 레이아웃 지문 스코어러(L1~L14)
- `scripts/heading_anchor.py` — 헤딩 슬러그 재계산·앵커 치환·게이트 D
- `scripts/scan_docs.py` — 문서 분류(한글 비율·산문량·route_hint)
- `scripts/author_repeat.py` — 작성자 반복 구절 검출·gen-block 생성(v1.3)
- `references/docs-profile.md` — 문서 전용 윤문 오버라이드
- `references/author-tics.txt` — 장르별 반복 구절 시드 목록(v1.3)
- `references/author-repeat-stop.txt` — 검출 시 걸러낼 불용어 목록(v1.3)
- `tests/test_author_repeat.py` — 작성자 반복 구절 테스트 하네스(v1.3)

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

## 의존성 확인

이 스킬은 humanize-korean 플러그인의 문장 축 윤문 엔진에 의존한다. 존재 여부를 먼저 확인한다.

```bash
ls ~/.claude/plugins/cache/im-not-ai/humanize-korean/*/ 2>/dev/null
```

출력이 없으면 플러그인이 없는 것이다. 플러그인 설치는 사용자 승인이 필요한 영역이므로 직접 설치를 시도하지 말고, 사용자에게 Claude Code 안에서 `/plugin install humanize-korean@im-not-ai`를 실행하도록 안내한다.

## 검증

저장소 루트에서 테스트 하네스를 돌린다.

```bash
bash tests/run.sh
```

md_shield·llm_signature·heading_anchor·author_repeat 네 하네스가 순서대로 실행되며 전부 통과해야 한다. 이 테스트는 humanize-korean 플러그인이 없어도 통과한다(LLM 호출 없이 스킬 자체 로직만 검증). 결과(통과/실패 개수, 실패가 있다면 어느 하네스인지)를 사용자에게 그대로 보고한다.

## 사용 시 알아야 할 것

설치가 끝나면 사용자는 자연어로 요청한다 — "이 디렉토리 문서 윤문해줘", "README 티 나는 거 좀 없애줘", "정밀 모드로 docs/ 전체 다듬어줘", "지문만 봐줘" 같은 문구가 트리거다. 기본은 경제 모드라 파일당 LLM 콜이 1회로 제한되고, 게이트가 문제를 잡으면 추가 콜 대신 보류 목록에 기록한다(정밀 모드가 이 상한을 해제한다). 중단된 실행은 "이어서"로, 완료된 run의 보류 파일만 다시 처리하고 싶을 때는 "보류 재시도"로 재개한다. 원본 파일은 기본적으로 비파괴다 — diff를 미리 보여주고 승인을 받은 뒤에만 적용한다.

## 하지 말 것

`SKILL.md`와 `scripts/`는 이 저장소의 배포 산출물이다 — 로컬에서 임의로 고치지 않는다. 업데이트가 필요하면 `git pull`로 받는다. humanize-korean 플러그인의 콘텐츠(quick-rules, 에이전트 정의 등)를 이 저장소로 복사해 오지 않는다 — 두 저장소는 별도로 유지된다. `_workspace/`는 실행 중 생기는 산출물 디렉토리이므로 커밋 대상이 아니다.
