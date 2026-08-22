# reply-check

Claude Code Stop 훅. 마지막 assistant 메시지가 한국어 산문이면 세 가지 축으로 품질을 확인하고, 기준을 넘으면 재작성을 요청한다.

## 세 가지 검사 축

**1축 — 무생물·추상 주어**

`효과성이 생산성을 좌우했다` 류의 문장을 잡는다. `metrics_v2.py`(im-not-ai 플러그인)가 있으면 `inanimate_subject_rate`를 호출해 비율 ≥ 0.25일 때 차단한다. 플러그인이 없으면 내장 정규식이 패턴 2회 이상 검출 시 차단한다.

**2축 — 반복 구절**

`결론적으로`, `이에 따라`, `요약하면` 등 AI 서명구와 작성자 고유 반복구(author-tics.txt)를 시드로 1회 이상 등장하면 차단한다. `author_repeat.py`가 있으면 해당 모듈의 `check_repeats()`를 사용한다.

**3축 — 읽기 난도**

문장 평균 길이 ≥ 45자, 또는 60자 초과 문장 비율 ≥ 30%, 또는 90자 초과 문장이 하나라도 있으면 차단한다.

세 축 중 하나라도 차단 조건에 해당하면 `decision: block`과 사유를 stdout에 출력한다. 훅은 항상 exit 0을 반환해 세션을 죽이지 않는다.

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

## 로그 위치

`~/.claude/hooks/logs/reply-check.jsonl`

각 줄은 `ts`, `session`, `chars`, `inanimate_rate`, `seed_hits`, `avg_len`, `blocked` 필드를 담은 JSON이다.

## 시드 파일 경로

훅은 아래 순서로 시드 파일을 찾는다(심링크 resolve 기준).

1. `hooks/reply-check/../../wwe/references/author-tics.txt` (저장소 내)
2. `~/evejuni/skills/wwe/references/author-tics.txt`
3. `~/.claude/skills/wwe/references/author-tics.txt`

`author_repeat.py`도 같은 방식으로 `wwe/scripts/` 아래를 먼저 찾는다.

## 끄는 법

`~/.claude/settings.json`의 `hooks.Stop` 배열에서 이 훅 항목을 제거하거나 주석 처리한다(JSON은 주석 미지원이므로 항목 자체를 삭제한다). `--no-hooks` 플래그로 `install.sh`를 실행하면 훅 설치 단계를 건너뛸 수 있다.

## 설치

저장소 루트에서 `install.sh`를 실행하면 심링크와 settings.json 등록을 자동으로 처리한다.

```bash
cd ~/evejuni/skills
bash install.sh
```

훅 설치만 건너뛰려면:

```bash
bash install.sh --no-hooks
```
