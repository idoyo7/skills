---
name: freeze
version: "1.0.0"
description: "얼음! — 5시간 사용량 한도(또는 자리 비움) 때문에 작업을 멈춰야 할 때, 진행 상태를 handoff 로 남기고 리셋 시각(땡)에 같은 세션을 헤드리스로 자동 재개하는 세션 예약 스킬. 호출 즉시 실행 중이던 백그라운드 태스크·워크플로우를 세우고, LLM 이 하는 일은 handoff 한 장 작성뿐 — 예약·대기·프로브·재개는 전부 결정적 스크립트가 처리해 남은 쿼터를 태우지 않는다. 땡 시각은 transcript 타임스탬프로 5시간 윈도우를 역산해 자동 추정하고, 추정이 안 서면 사용자에게 묻는다. 리셋 시각엔 haiku 프로브(몇 토큰)로 한도 해제를 확인한 뒤 `claude -p --resume` 로 이어서 작업한다. 트리거 — \"얼음\", \"freeze\", \"한도 걸렸다\", \"usage limit\", \"세션 예약\", \"리셋되면 이어서\", \"5시간 제한\", \"쿼터 초과, 나중에 마저\". 예약 확인·해제 — \"땡\", \"freeze 상태\", \"예약 취소\". 맥으로 작업을 넘기는 건 mac-run, 주기 반복 실행은 /loop 이 맞다."
argument-hint: "[땡 시각 — 예: 15:00, +2h, auto(기본)] [--job <이름>]"
---

# /freeze — 얼음! 세션 예약, 땡에 자동 재개

한도에 걸렸거나 걸리기 직전일 때 부른다. 지금 세션의 작업 상태를 얼려두고, 땡(리셋 시각)에 스크립트가 같은 세션을 `claude -p --resume` 로 이어서 돌린다.

```
얼음 ─▶ 백그라운드 중지 ─▶ handoff 작성(유일한 LLM 작업) ─▶ reserve.sh(슬리퍼 기동) ─▶ 세션 종료
땡  ─▶ 슬리퍼 기상 ─▶ haiku 프로브(한도 확인) ─▶ claude -p --resume ─▶ 결과를 handoff 에 기록
```

경로 변수:

```bash
FZ=~/.claude/skills/freeze/scripts
```

## 얼음 절차 (토큰 최소 — 딱 4단계, 추가 탐색 금지)

**1. 하던 일 세우기.** 실행 중인 백그라운드 태스크·워크플로우가 있으면 중지(TaskStop)하고, 각각 어디까지 갔는지만 짧게 파악한다. 새 작업을 시작하지 않는다.

**2. handoff 작성.** `.omc/handoffs/freeze-{YYYYMMDD-HHMM}.md` 한 장. 형식:

```markdown
# freeze handoff — {한 줄 요약}
## 하던 일
{원래 요청과 전체 목표}
## 완료 지점
{끝난 것들 — 파일 경로·커밋 해시 포함}
## 다음 단계
{재개 후 바로 실행할 순서. 구체적으로 — 재개 세션은 이 목록만 보고 움직인다}
## 검증
{끝났다고 판단하는 기준 — 실행할 테스트·확인 명령}
```

**3. 땡 시각 결정.**
- 사용자가 시각을 줬거나 한도 에러 메시지에 리셋 시각이 보이면 그걸 쓴다 (`HH:MM` 또는 `+2h` 형태).
- 없으면 `auto` — reserve 가 OMC HUD 캐시(statusline payload 의 `rate_limits.five_hour.resets_at`, 정확값)에서 읽고, 캐시가 없으면 transcript 로 5시간 윈도우를 역산한다.
- reserve 가 `땡 시각 추정 실패` 로 죽으면 그때 사용자에게 리셋 시각을 묻는다 (AskUserQuestion).

**4. 예약 + 종료 보고.**

```bash
bash $FZ/freeze.sh reserve --at auto --cwd "$(pwd)" --handoff .omc/handoffs/freeze-....md
```

출력의 `얼음 — job=... 땡=...` 한 줄을 사용자에게 그대로 전하고 **작업을 멈춘다.** 이후 이 세션에서 토큰을 더 쓰지 않는다.

## 땡 (자동)

슬리퍼(`thaw.sh`)가 알아서 한다: 땡 시각까지 대기 → `claude -p --model haiku "ok"` 프로브로 한도 해제 확인(실패 시 15분 간격 최대 12회) → `claude -p --resume <세션> --permission-mode acceptEdits` 로 재개. 재개 세션은 handoff 를 읽고 이어서 작업한 뒤 결과를 handoff 하단 `## 재개 결과` 에 남긴다.

## 수동 조작

| 상황 | 명령 |
|---|---|
| 예약 확인 | `bash $FZ/freeze.sh status` |
| 사용자가 먼저 돌아와 직접 이어서 하겠다 | `bash $FZ/freeze.sh cancel <job>` 후 handoff 읽고 인라인 진행 |
| 컨테이너 재시작으로 슬리퍼가 죽었다 | `bash $FZ/freeze.sh check` — 시각 지난 예약을 즉시 실행 |
| 땡 시각만 미리 알고 싶다 | `bash $FZ/freeze.sh estimate` |

## 한계

- 슬리퍼는 detached 프로세스라 **머신·컨테이너가 재시작되면 죽는다.** 예약 자체는 상태 파일(`~/.local/state/freeze/<job>/`)에 남으니 `check` 로 캐치업한다.
- 헤드리스 재개는 앱 세션 목록에 안 뜬다. 결과는 handoff 의 `## 재개 결과` 와 `~/.local/state/freeze/<job>/resume-output.txt` 로 확인.
- 땡 자동 결정은 HUD 캐시(`~/.claude/hud/cache/stdin.*.json`)가 있으면 정확하다. 캐시가 없을 때만 ccusage 식 근사(첫 활동 정시 내림 + 5h)로 폴백하는데 이건 수 시간 어긋날 수 있다 — 프로브 재시도(15분 × 12회)가 이르게 잡힌 오차는 흡수하지만, 늦게 잡히면 그만큼 재개가 늦어진다.
