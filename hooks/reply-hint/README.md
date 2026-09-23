# reply-hint

Claude Code UserPromptSubmit 훅. `reply-check`(Stop 훅)가 advise 모드에서 남긴
pending 힌트를 다음 사용자 턴이 시작될 때 읽어, 모델에게만 보이는
`additionalContext`로 끼워 넣는다.

## 왜 이렇게 나눴나

`reply-check`는 Stop 이벤트에서 돈다 — 즉 답변이 이미 화면에 표시된 뒤다. 그
시점에 `decision: block`을 내면 Claude가 같은 내용을 다시 써서 사용자가 답을
두 번 보게 된다(2026-09 기준 최근 30일 응답의 약 32%가 이 경로로 중복
출력됐다). 검사 자체는 유용하니 버리지 않고, 대신 "그 자리에서 막기"만
그만뒀다.

advise 모드의 `reply-check`는 검사에 걸려도 막지 않고 사유를 세션별 pending
파일에 적어두기만 한다. 이 훅은 다음 프롬프트가 제출되는 순간(사용자가 다음
질문을 입력한 직후) 그 파일을 읽어 컨텍스트에 얹는다 — 사용자는 아무것도 못
보고, Claude만 "직전 답변이 이런 이유로 걸렸다"는 걸 알고 이번 답변에서
피한다.

## 동작

1. stdin으로 받은 `session_id`를 정리해 `$CLAUDE_CONFIG_DIR/hooks/state/reply-check/<session_id>.json` 을 찾는다.
2. 파일이 없으면 아무 출력 없이 종료한다.
3. 파일이 있으면 읽은 즉시 지운다(신선하든 아니든) — 최신 답변 하나만 의미가 있고, 지우지 않으면 다음 턴에도 같은 힌트가 반복된다.
4. 기록 시각(`ts`)이 6시간 이내면 `additionalContext`로 사유를 얹는다. 6시간을 넘겼으면 이미 지운 상태로 조용히 종료한다(너무 오래된 힌트는 지금 답변과 무관할 가능성이 높다).
5. 사유가 800자를 넘으면 잘라낸다.
6. 곁다리로, pending 디렉터리에서 24시간 넘은 파일을 발견하면 세션과 무관하게 청소한다(다음 턴이 영영 안 오는 세션이 있을 수 있어서).

파일 형식은 `reply-check`가 쓰는 것과 같다: `{"ts": <epoch>, "reason": "...", "chars": N}`.

## 출력 예시

```json
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"직전 답변이 말투 검사에 걸렸다. 이번 답변에서는 다음을 피한다:\n[reply-check] 다시 써라 — 짧은 문장, 구체 주어, 비유 없이.\n- 반복 구절: 결론적으로 ×2"}}
```

## 끄는 법

`~/.claude/settings.json`의 `hooks.UserPromptSubmit` 배열에서 이 훅 항목을
제거한다. `--no-hooks` 플래그로 `install.sh`를 실행하면 훅 설치 단계를
건너뛸 수 있다. `reply-check`만 advise 모드에서 block 모드로 되돌리려면(`REPLY_CHECK_MODE=block`)
이 훅은 그냥 아무 pending 파일도 못 찾아 항상 조용히 종료한다 — 같이 끌
필요는 없다.

## 설치

저장소 루트에서 `install.sh`를 실행하면 심링크와 `settings.json` 등록을
자동으로 처리한다. `reply-check`와 같은 절차다.

```bash
cd <저장소 루트>
bash install.sh
```
