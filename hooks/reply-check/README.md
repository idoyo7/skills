# reply-check

Claude Code Stop 훅. 마지막 assistant 메시지가 한국어 산문이면 네 가지 축으로 품질을 확인한다.

## advise 모드가 기본이다

Stop 훅은 답변이 이미 화면에 표시된 뒤에 돈다. 그 자리에서 `decision: block`을 내면 Claude가 같은 내용을 다시 써서 사용자가 답을 두 번 보게 된다(2026-09 기준 최근 30일 응답의 약 32%가 이 경로로 중복 출력됐고, 그중 대다수는 `author-tics.txt` 시드 한 개 매치였다). 그래서 기본 동작(`REPLY_CHECK_MODE=advise`)은 그 자리에서 막지 않는다. 검사에 걸리면 사유를 세션별 pending 파일(`$CLAUDE_CONFIG_DIR/hooks/state/reply-check/<session_id>.json`)에 적어두기만 하고, 다음 사용자 턴이 시작될 때 [`reply-hint`](../reply-hint/README.md) 훅(UserPromptSubmit)이 그 파일을 읽어 모델에게만 보이는 컨텍스트로 끼워 넣는다. 사용자는 중복 응답을 보지 않고, Claude는 다음 답변에서 같은 실수를 피할 단서를 받는다.

`REPLY_CHECK_MODE=block`으로 설정하면 예전처럼 그 자리에서 `decision: block`을 낸다.

pending 파일이 남아 있어도 다음 답변이 검사를 통과하면 지운다 — 오래된 힌트가 무관한 턴까지 따라붙지 않게.

## 세 가지 검사 축

**1축 — 무생물·추상 주어**

`효과성이 생산성을 좌우했다` 류의 문장을 잡는다. `metrics_v2.py`(im-not-ai 플러그인)가 있으면 `inanimate_subject_rate`를 호출해 비율 ≥ 0.25일 때 차단한다. 플러그인이 없으면 내장 정규식이 패턴 2회 이상 검출 시 차단한다.

**2축 — 반복 구절**

`결론적으로`, `이에 따라`, `요약하면` 등 AI 서명구와 작성자 고유 반복구(author-tics.txt)를 시드로 1회 이상 등장하면 차단한다. `author_repeat.py`가 있으면 해당 모듈의 `check_repeats()`를 사용한다.

**3축 — 읽기 난도**

문장 평균 길이 ≥ 45자, 또는 60자 초과 문장 비율 ≥ 30%, 또는 90자 초과 문장이 하나라도 있으면 차단한다.

**4축 — 구조 패턴**

다섯 가지 패턴을 차단 사유로 잡고, 네 가지를 참고 보고로만 기록한다.

*차단(block) 기여:*

- **수사 의문 종결**: 산문 문장이 `(?:는가|것인가|인가|일까|을까|ㄹ까)[.?]?$`로 끝나면 히트. 인용부호로 시작하는 문장과 `주세요|주시|할까요|필요하신`이 포함된 사용자 대상 질문은 제외한다. 1회부터 차단.
- **designed-to 직역**: `도록\s+(?:구성|설계|만들|배치|정의|작성)` 패턴 1회부터 차단.
- **it-cleft 강조**: `내린 건 비용이었습니다` 형태의 분열문 1회부터 차단.
- **한계 프레임**: `하나로는|만으로는|만으론` 뒤에 `안/않/못/부족/불가/어렵/없`이 오는 패턴 1회부터 차단.
- **열거 예고(숫자형)**: `[0-9]+\s*가지` 패턴 1회부터 차단.

*참고(report) 전용:*

- **관형격 사슬**: 한 문장 안에서 `[가-힣]+의\s+[가-힣]+의` (의 2연쇄) 히트. 차단에는 넣지 않고 reason 끝에 `참고:` 줄로만 표시.
- **강조부사 밀도**: `실제로·사실상·분명히·확실히·명확히` 합산이 1,000자당 3회 이상이면 참고 보고.
- **단정 단문**: 공백 제외 14자 이하 문장이 `(?:분명|명확|확실|자명|간단)합니다[.]?$`로 끝나면 참고 보고.
- **삼항 나열**: `A와/과 B, C로/를/이...` 형태의 나열 구문은 참고 보고. 블록에 넣지 않는다.

네 축 중 하나라도 차단 조건에 해당하면 `decision: block`과 사유를 stdout에 출력한다. 훅은 항상 exit 0을 반환해 세션을 죽이지 않는다.

한글 비율 30% 미만이거나 정제 후 120자 미만인 응답은 검사를 건너뛴다.

## 임계값 요약

| 축 | 조건 | 임계값 |
|---|---|---|
| 무생물 주어 (metrics_v2) | inanimate_subject_rate | ≥ 0.25 |
| 무생물 주어 (정규식) | 패턴 매치 횟수 | ≥ 2 |
| 반복 구절 | 시드 패턴 등장 | ≥ 1 |
| 반복 어간 | 동일 어간 반복 | ≥ 4 |
| 긴 문장 비율 | 60자 초과 문장 | ≥ 30% |
| 평균 문장 길이 | 문장 평균 | ≥ 45자 |
| 매우 긴 문장 | 90자 초과 1개 이상 | 즉시 차단 |
| 수사 의문 종결 | `는가/것인가/인가/일까/을까/ㄹ까` 종결 | ≥ 1회 (차단) |
| designed-to 직역 | `도록 구성/설계/만들...` | ≥ 1회 (차단) |
| it-cleft 강조 | `~한/린/인 건 X였습니다` | ≥ 1회 (차단) |
| 한계 프레임 | `하나로는/만으로는 ... 안/않/못...` | ≥ 1회 (차단) |
| 열거 예고(숫자형) | `[0-9]+가지` | ≥ 1회 (차단) |
| 관형격 사슬 | `의 ... 의` 2연쇄 | 참고 보고만 |
| 강조부사 밀도 | 실제로·사실상·분명히·확실히·명확히 | ≥ 3/1000자 (참고) |
| 단정 단문 | ≤14자 + 분명/명확/확실/자명/간단합니다 | 참고 보고만 |
| 삼항 나열 | `A와/과 B, C로/를/이...` | 참고 보고만 |

## 로그 위치

`~/.claude/hooks/logs/reply-check.jsonl`

각 줄은 `ts`, `session`, `mode`, `chars`, `inanimate_rate`, `seed_hits`, `avg_len`, `struct_hits`, `struct_report`, `blocked` 필드를 담은 JSON이다. `mode`는 `advise`/`block` 중 그 호출 때 실제로 쓰인 값이다. `blocked`는 모드와 무관하게 "검사에 걸렸는가"를 뜻하므로(advise 모드에서도 걸리면 `true`) 과거 통계와 그대로 비교할 수 있다. `struct_hits`는 axis4 차단·보고 히트 목록, `struct_report`는 "참고:" 로만 표시되는 보고 문자열 배열이다.

## pending 파일 위치

`$CLAUDE_CONFIG_DIR/hooks/state/reply-check/<session_id>.json` (`CLAUDE_CONFIG_DIR` 미설정이면 `~/.claude`). advise 모드에서 검사에 걸리면 `{"ts": <epoch>, "reason": "...", "chars": N}` 형태로 이 파일에 덮어쓴다 — 최신 답변 하나만 의미가 있어서다. `reply-hint` 훅이 다음 턴에 읽고 지운다. session_id는 파일명으로 쓸 수 없는 문자를 `_`로 바꿔 저장한다.

## 시드 파일 경로

훅은 아래 순서로 시드 파일을 찾는다.

1. 환경변수 `REPLY_CHECK_AUTHOR_TICS` 가 가리키는 경로
2. `hooks/reply-check/../../wwe/references/author-tics.txt` (저장소 내)
3. `$CLAUDE_CONFIG_DIR/skills/wwe/references/author-tics.txt` (미설정이면 `~/.claude`)

2번이 기준선이다. `__file__` 을 `resolve()` 한 값으로 잡으므로 `~/.claude/hooks/` 에 심링크로 설치돼 있어도 저장소 실제 위치를 찾는다 — 저장소를 어디에 클론해도 맞는다.

`author_repeat.py` 도 같은 방식이고 환경변수는 `REPLY_CHECK_AUTHOR_REPEAT` 다. `metrics_v2.py` 는 `REPLY_CHECK_METRICS_V2` 로 지정할 수 있고, 미지정이면 플러그인의 `marketplaces/` 와 `cache/<버전>/` 양쪽을 훑는다.

## 끄는 법

`~/.claude/settings.json`의 `hooks.Stop` 배열에서 이 훅 항목을 제거하거나 주석 처리한다(JSON은 주석 미지원이므로 항목 자체를 삭제한다). `--no-hooks` 플래그로 `install.sh`를 실행하면 훅 설치 단계를 건너뛸 수 있다. 검사 자체는 유지하되 advise 대신 예전 block 동작만 되돌리려면 환경변수 `REPLY_CHECK_MODE=block`을 설정한다(이때는 `reply-hint` 훅이 pending 파일을 찾을 일이 없다).

## 설치

저장소 루트에서 `install.sh`를 실행하면 심링크와 settings.json 등록을 자동으로 처리한다.

```bash
cd <저장소 루트>
bash install.sh
```

훅 설치만 건너뛰려면:

```bash
bash install.sh --no-hooks
```
