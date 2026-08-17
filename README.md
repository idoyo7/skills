# humanize-docs

작업 디렉토리의 마크다운 문서에서 Claude·GPT가 남긴 티를 걷어내는 Claude Code 스킬이다. 문장 축은 humanize-korean 파이프라인(번역투·피동 남용·명사화 누적 등 70패턴)을 그대로 재사용하고, 이 스킬만의 축으로 문서 레이아웃 지문 — 볼드리드 불릿, 상태 이모지, 서두 TL;DR 박스, 섹션마다 붙는 구분선, 마무리 정리 섹션 같은 것들 — 을 L1~L14 지표로 결정적으로 측정한다. 정책은 "장식만 제거, 구조는 보존"이라 코드블록·표·링크·불릿 개수는 바이트 단위로 지킨다.

v1.2는 파일당 LLM 1콜 상한을 두는 경제 모드가 기본값이고, 중단된 실행은 이어서/재개로 이미 낸 콜을 다시 지불하지 않는다. 헤딩(제목) 편집과 축약은 자연어 옵션으로 켜고 끌 수 있다.

## 요구사항

Claude Code와 humanize-korean 플러그인이 필요하다.

```bash
/plugin install humanize-korean@im-not-ai
```

이 저장소에는 humanize-korean 본진 콘텐츠가 들어 있지 않다. 별도 플러그인으로 설치해야 이 스킬이 동작한다.

상세 설치 가이드는 INSTALL.md, AI 에이전트에게 설치를 맡길 때는 AGENTS.md 참고.

## 설치

사용자 레벨(모든 프로젝트에서 쓸 때):

```bash
git clone https://github.com/idoyo7/humanize-docs ~/.claude/skills/humanize-docs
```

프로젝트 레벨(이 프로젝트에서만 쓸 때):

```bash
git clone https://github.com/idoyo7/humanize-docs <project>/.claude/skills/humanize-docs
```

## 사용법

Claude Code에서 자연어로 요청하면 된다.

- "이 디렉토리 문서 윤문해줘"
- "README 티 나는 거 좀 없애줘"
- "정밀 모드로 docs/ 전체 다듬어줘"
- "아까 하던 거 이어서"

주요 옵션은 요청 문구에 섞어서 켠다.

| 문구 | 효과 |
|---|---|
| (기본값) | 경제 모드 — 파일당 LLM 1콜 상한, 게이트가 잡은 문제는 보류 목록에 기록 |
| 정밀 모드 / --strict | 콜 상한 해제. 자동 재윤문·finalize 승급까지 |
| 이어서 / 재개 | 중단된 실행을 이어서 진행 |
| 보류 재시도 | 완료된 run의 보류 파일만 골라 재시도 |
| 제목도 다듬어줘 | 헤딩 편집 켜기(기본은 헤딩 텍스트 불변) |
| 축약하지 마 | 축약 기능 끄기(기본은 켜짐) |
| 이모지 살려줘 | 이모지 제거 규칙(L6) 끄기 |
| 지문만 봐줘 | 윤문 없이 레이아웃 지문 점수만 계산 |

전체 옵션은 `SKILL.md`의 §옵션 절에 정리되어 있다.

## 테스트

```bash
bash tests/run.sh
```

md_shield·llm_signature·heading_anchor 세 하네스를 순서대로 돌리고, 처음 만난 실패 코드를 넘긴다(전부 통과하면 0).

## 구조

- `SKILL.md` — 스킬 본체. Phase 0~9 파이프라인 정의
- `scripts/md_shield.py` — 마스킹·복원·구조 검증
- `scripts/llm_signature.py` — 레이아웃 지문 스코어러(L1~L14)
- `scripts/heading_anchor.py` — 헤딩 슬러그 재계산·앵커 치환·게이트 D
- `scripts/scan_docs.py` — 문서 분류(한글 비율·산문량·route_hint)
- `references/docs-profile.md` — quick-rules 위에 얹는 문서 전용 오버라이드
- `tests/` — 적대적 코퍼스와 회귀 테스트 하네스 세 개
- `INSTALL.md` — 사람용 설치·구성 가이드
- `AGENTS.md` — AI 에이전트용 설치·사용 지침
