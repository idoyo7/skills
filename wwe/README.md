# wwe — 마크다운 윤문과 구조 편집

마크다운 문서의 AI스러운 문장과 표현을 고치고, 요청에 따라 글의 전개도 다시 구성하는 Claude Code 스킬이다.

v1.6.0은 기존 **보존 윤문**과 **구조 재작성**에 **Astra 최종 퇴고 handoff**를 더한다. 문장만 다듬을 때는 humanize-korean과 기존 마스킹·복원 게이트를 사용한다. “글 구조부터 다시 써줘”처럼 구성을 바꾸는 요청은 원문 전체의 주장·근거·독자 질문을 읽고 문단과 절을 다시 배치하는 별도 경로로 처리한다.

“Claude에서 준비하고 마지막에 Astra high로 퇴고해줘”라고 요청하면 Claude가 초안·검사 메모를 준비하고 Astra가 최종 문체를 결정한다. Claude는 이후 내용 보존과 링크를 검증하며, 보정이 필요하면 근거와 함께 Astra에 돌려보낸다. 기본 출발점은 **초안 + 검사 결과 → Astra high**이며 Claude 기본 윤문은 필수 전처리가 아니다. 품질이 검증된 최적 조합이라는 뜻은 아니며, 대표 글에서 준비 범위를 비교하며 조정한다. 실행·재개·검증 계약은 [handoff 가이드](references/engine-swap-astra.md)에 있다.

기존 스킬은 헤딩·불릿 수·표를 고정해 어색한 글 구성까지 남겼다. L13/L14와 초안 관문에서 문제를 발견해도 보고만 했고, 경제 모드의 파일당 1콜로는 여러 글의 중복 전개까지 다루기 어려웠다. 이 한계와 글의 종류별 편집 방법, 보존·링크 검증은 [구조 편집 가이드](references/structure-editing.md)에 정리했다. 레이아웃 점수가 내려갔다고 글의 논리와 근거까지 좋아진 것은 아니다.

## 요구사항

Claude Code에서 스킬을 사용한다. **보존 윤문 파이프라인**에는 humanize-korean 플러그인이 필요하다.

```bash
/plugin install humanize-korean@im-not-ai
```

humanize-korean 콘텐츠는 이 저장소에 포함하지 않는다. 구조 재작성은 현재 에이전트가 별도 가이드에 따라 편집하며 이 플러그인을 요구하지 않는다. 실제 사이트의 렌더링·링크 검증에는 해당 프로젝트의 빌드 도구가 필요하다.

Astra handoff에는 해당 기기의 Codex CLI 설치·인증과 `gpt-6-astra` 접근이 필요하다. 스킬 업데이트로 Codex 인증이나 권한 설정이 다른 기기에 복사되지는 않는다. handoff는 humanize-korean을 요구하지 않는다.

상세 설치 가이드는 INSTALL.md, AI 에이전트에게 설치를 맡길 때는 AGENTS.md 참고.

## 설치

이 스킬은 `idoyo7/skills` 저장소의 `wwe/` 에 있다(예전 표준 저장소 `idoyo7/humanize-docs` 는 여기로 합쳐졌다).

```bash
git clone https://github.com/idoyo7/skills.git ~/src/skills
cd ~/src/skills && bash install.sh
```

`install.sh` 가 `~/.claude/skills/` 에 심링크를 건다. 저장소를 어디에 두든 상관없다 — 스크립트가 자기 위치를 기준으로 경로를 잡는다.

## 사용법

Claude Code에서 자연어로 요청하면 된다.

- "이 디렉토리 문서 윤문해줘"
- "README 티 나는 거 좀 없애줘"
- "정밀 모드로 docs/ 전체 다듬어줘"
- "아까 하던 거 이어서"
- "이 게시글들 문장뿐 아니라 글 구조부터 전부 다시 써줘"
- "코드와 수치는 유지하고 중복 절과 표도 정리해줘"
- "Claude에서 초안과 검사 결과를 준비하고, 글 전체 전개와 문장을 마지막에 Astra high로 퇴고해줘"

주요 옵션은 요청 문구에 섞어서 켠다.

| 문구 | 효과 |
|---|---|
| 마지막에 Astra high로 / Astra handoff | 초안·검사 메모를 Astra에 전달하고 Claude가 결과 검증. 편집 범위·미리보기 제한은 그대로 유지 |
| 글 구조부터 다시 / 전면 재작성 / 구조도 바꿔도 돼 | 구조 편집 가이드 실행. 보존 파이프라인·파일당 1콜·기존 재개 질문을 거치지 않음 |
| (일반 윤문 기본값) | 경제 모드 — 파일당 LLM 1콜 상한, 게이트가 잡은 문제는 보류 목록에 기록 |
| 정밀 모드 / --strict | 보존 윤문의 콜 상한 해제. 구조 변경 허용 옵션은 아님 |
| 이어서 / 재개 | 명시 run·현재 대화·실행 기록의 모드를 이어받음. 구조 작업은 구조 경로로 재개 |
| 보류 재시도 | 완료된 run의 보류 파일만 골라 재시도 |
| 제목도 다듬어줘 | 헤딩 편집 켜기(기본은 헤딩 텍스트 불변) |
| 축약하지 마 | 축약 기능 끄기(별도 보존 요청이 없으면 기본 켜짐) |
| 문장만 / 제목 그대로 / 구조 유지 | 헤딩 편집과 축약을 끄고 절·헤딩·문단 삭제 금지 |
| 이모지 살려줘 | 이모지 제거 규칙(L6) 끄기 |
| 지문만 봐줘 | 윤문 없이 레이아웃 지문 점수만 계산 |
| 슬롭 검사 빼줘 / 초안 관문 꺼줘 | 초안 관문(게이트 S) 끄기(기본은 켜짐) |

전체 옵션은 `SKILL.md`의 §옵션 절에 정리되어 있다. 수정 대상과 적용 방식이 이미 요청에 포함됐다면 다시 승인을 묻지 않는다. 검사·미리보기 요청은 원본을 유지한다. “구조를 다시 쓰되 미리보기만”도 원본을 바꾸지 않는다. 재개·적용 전에는 최초 원본과 현재 파일을 대조해 사용자 변경을 낡은 후보로 덮어쓰지 않는다.

구조 재작성은 원본과 후보를 별도로 대조해 코드·수치·출처·frontmatter를 보존하고, 실제 렌더러로 변경한 헤딩과 저장소 전체 링크를 확인한다. `md_shield.py verify`나 GitHub slug용 `heading_anchor.py`만으로 구조 재작성과 Hugo 링크 검증을 마쳤다고 보고하지 않는다.

## 테스트

```bash
bash wwe/tests/run.sh
```

위 명령은 `skills` 저장소 루트에서 실행한다. md_shield·llm_signature·heading_anchor·author_repeat·slop_scan 다섯 하네스를 순서대로 돌리고, 처음 만난 실패 코드를 넘긴다(전부 통과하면 0). 이 하네스는 기존 스크립트 회귀를 검사하며 구조 재작성이나 Astra handoff의 문장·논증 품질은 검증하지 않는다.

## 구조

- `SKILL.md` — 요청별 경로 선택과 보존 모드 Phase 0~9
- `references/structure-editing.md` — 구조 재작성과 원본·후보·사이트 검증 가이드
- `references/engine-swap-astra.md` — Claude 준비·Astra high 최종 퇴고·Claude 검증, 실행·실패·재개와 비교 기준
- `scripts/md_shield.py` — 마스킹·복원·구조 검증
- `scripts/llm_signature.py` — 레이아웃 지문 스코어러(L1~L14)
- `scripts/heading_anchor.py` — 헤딩 슬러그 재계산·앵커 치환·게이트 D
- `scripts/scan_docs.py` — 문서 분류(한글 비율·산문량·route_hint)
- `references/docs-profile.md` — 보존 윤문에만 사용하는 문서 오버라이드
- `tests/` — 적대적 코퍼스와 회귀 테스트 하네스 다섯 개
- `scripts/author_repeat.py` — 작성자 반복 구절 검출·gen-block 생성
- `references/author-tics.txt` — 장르별 반복 구절 시드 목록
- `references/author-repeat-stop.txt` — 검출 시 걸러낼 불용어 목록
- `scripts/slop_scan.py` — 초안 관문(게이트 S) 스캐너. scan·extract-llm·compare
- `references/slop-lexicon.txt` — 확신 표지·필러·주장/근거 표지 사전
- `references/slop-gate.md` — 초안 관문 LLM 층 지침(monolith 입력에 주입)
- `agents/wwe-slop-judge.md` — 정밀 모드 전용 비저자 판정 에이전트
- `INSTALL.md` — 사람용 설치·구성 가이드
- `AGENTS.md` — AI 에이전트용 설치·사용 지침

## 작성자 반복 구절

특정 작성자(Claude 등)가 여러 문서에 걸쳐 습관처럼 쓰는 표현은 문장 단위 윤문으로는 잘 안 잡힌다. 같은 단어가 한 문서에 한 번만 나와도 코퍼스 전체에서 유난히 몰려 있으면 워터마크처럼 작동하기 때문이다.

`scripts/author_repeat.py`는 이 문제를 두 가지 방식으로 다룬다. 하나는 코퍼스 교차 빈도 — `build`로 여러 문서에서 프로필을 뽑고, `scan`으로 대상 문서와 대조해 반복 표현을 찾는다. 다른 하나는 시드 파일 — `references/author-tics.txt`에 미리 적어둔 표현을 프로필 없이도 바로 검출한다.

보존 윤문 파이프라인 안에서 이 스크립트는 두 번 쓰인다. Phase 4에서 `gen-block`이 시드 파일을 읽어 윤문 지침 블록을 만들고 `02_diagnosis.md`에 붙인다. 이 블록이 monolith 에이전트에게 "이 표현들은 바꿔라"고 알려준다. Phase 7 게이트 C 옆에서는 `scan`이 윤문 결과물에 시드 표현이 남아 있는지 검사하고 `author_repeat_seed.txt`에 기록한다. 게이트 exit에는 영향을 주지 않으므로 검사 결과는 보고용이다.

시드 파일을 직접 편집하면 검출 대상을 늘리거나 바꿀 수 있다. 형식은 `표현 => 대체 지시문`이고, `##` 줄이 장르 섹션 이름이 된다. `=> 대체 지시문` 부분을 생략하면 "평이한 말로 바꾼다"가 기본으로 쓰인다.

프로필을 새로 갱신하려면:

```bash
python3 scripts/author_repeat.py build --corpus <코퍼스 md 목록> --out _workspace/author-profile.json
```

시드 표현은 제거 대상이고, 코퍼스 프로필 결과는 scan 보고에만 쓰인다. 프로필 없이 시드만 쓰면 `scan --seed references/author-tics.txt`로 바로 실행할 수 있다.
