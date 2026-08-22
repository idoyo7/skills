# humanize-docs

작업 디렉토리의 마크다운 문서에서 Claude·GPT가 남긴 티를 걷어내는 Claude Code 스킬이다. 문장 축은 humanize-korean 파이프라인(번역투·피동 남용·명사화 누적 등 70패턴)을 그대로 재사용하고, 이 스킬만의 축으로 문서 레이아웃 지문 — 볼드리드 불릿, 상태 이모지, 서두 TL;DR 박스, 섹션마다 붙는 구분선, 마무리 정리 섹션 같은 것들 — 을 L1~L14 지표로 결정적으로 측정한다. 정책은 "장식만 제거, 구조는 보존"이라 코드블록·표·링크·불릿 개수는 바이트 단위로 지킨다.

v1.2는 파일당 LLM 1콜 상한을 두는 경제 모드가 기본값이고, 중단된 실행은 이어서/재개로 이미 낸 콜을 다시 지불하지 않는다. 헤딩(제목) 편집과 축약은 자연어 옵션으로 켜고 끌 수 있다.

v1.3은 작성자 반복 구절 검출을 더했다. `scripts/author_repeat.py`가 코퍼스 교차 빈도와 시드 파일 두 경로로 반복 표현을 잡고, Phase 4에서 gen-block으로 윤문 지침에 자동 주입해 같은 구절이 다시 나오지 않도록 막는다. Phase 7 게이트 C 옆에서는 시드 표현 잔존 여부를 스캔해 보고한다(exit에는 영향 없음).

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
- `scripts/author_repeat.py` — 작성자 반복 구절 검출·gen-block 생성
- `references/author-tics.txt` — 장르별 반복 구절 시드 목록
- `references/author-repeat-stop.txt` — 검출 시 걸러낼 불용어 목록
- `INSTALL.md` — 사람용 설치·구성 가이드
- `AGENTS.md` — AI 에이전트용 설치·사용 지침

## 작성자 반복 구절

특정 작성자(Claude 등)가 여러 문서에 걸쳐 습관처럼 쓰는 표현은 문장 단위 윤문으로는 잘 안 잡힌다. 같은 단어가 한 문서에 한 번만 나와도 코퍼스 전체에서 유난히 몰려 있으면 워터마크처럼 작동하기 때문이다.

`scripts/author_repeat.py`는 이 문제를 두 가지 방식으로 다룬다. 하나는 코퍼스 교차 빈도 — `build`로 여러 문서에서 프로필을 뽑고, `scan`으로 대상 문서와 대조해 반복 표현을 찾는다. 다른 하나는 시드 파일 — `references/author-tics.txt`에 미리 적어둔 표현을 프로필 없이도 바로 검출한다.

파이프라인 안에서 이 스크립트는 두 번 쓰인다. Phase 4에서 `gen-block`이 시드 파일을 읽어 윤문 지침 블록을 만들고 `02_diagnosis.md`에 붙인다. 이 블록이 monolith 에이전트에게 "이 표현들은 바꿔라"고 알려준다. Phase 7 게이트 C 옆에서는 `scan`이 윤문 결과물에 시드 표현이 남아 있는지 검사하고 `author_repeat_seed.txt`에 기록한다. 게이트 exit에는 영향을 주지 않으므로 검사 결과는 보고용이다.

시드 파일을 직접 편집하면 검출 대상을 늘리거나 바꿀 수 있다. 형식은 `표현 => 대체 지시문`이고, `##` 줄이 장르 섹션 이름이 된다. `=> 대체 지시문` 부분을 생략하면 "평이한 말로 바꾼다"가 기본으로 쓰인다.

프로필을 새로 갱신하려면:

```bash
python3 scripts/author_repeat.py build --corpus <코퍼스 md 목록> --out _workspace/author-profile.json
```

시드 표현은 제거 대상이고, 코퍼스 프로필 결과는 scan 보고에만 쓰인다. 프로필 없이 시드만 쓰면 `scan --seed references/author-tics.txt`로 바로 실행할 수 있다.
