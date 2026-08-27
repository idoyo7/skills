# workflow-arm

Claude Code PreToolUse 훅. `Workflow` 툴을 실제로 실행하려는 호출을 가로채, 이 cwd에 대한 재개 예약(freeze arm)이 걸려 있는지 확인하고 없으면 먼저 예약부터 걸라고 한 번 막는다.

## 왜 필요한가

큰 워크플로우는 수십만 토큰을 태울 수 있고, 도중에 5시간 사용량 한도에 걸리면 handoff를 남길 토큰조차 없이 그냥 끊길 수 있다. freeze 스킬의 `arm` 모드는 작업을 시작하기 전에 미리 예약을 걸어두고, 한도에 막히는 순간 예약이 이어받게 한다. 이 훅은 그 순서를 강제한다 — 예약 없이 Workflow를 부르면 일단 막는다.

## 판별 로직

**대상 호출만 본다.** `tool_name`이 `Workflow`가 아니면 통과. `tool_input`에 `script`, `scriptPath`, `name` 중 아무것도 없으면(즉 `runId`만 있는 조회·제어 호출이면) 통과한다.

**활성 예약이 있으면 통과.** `$FREEZE_STATE_DIR`(기본 `~/.local/state/freeze`) 아래 각 잡의 `reservation.json`을 읽어 `cwd`가 이번 호출의 cwd와 일치하고 `status`가 종료 상태(`cancelled`, `completed_early`, `probe_failed`, `done`, `failed`)가 아닌 것이 하나라도 있으면 막지 않는다. 상태값은 freeze.sh/thaw.sh가 실제로 쓰는 값을 그대로 따른다.

**세션당 한 번만 막는다.** 예약이 없으면 막되, 같은 세션에서 이미 한 번 막은 적이 있으면 두 번째부터는 통과시킨다. 세션 마커는 `$FREEZE_STATE_DIR/workflow-arm-sessions/<session_id>` 파일로 남기고, 7일 지난 마커는 다음 호출 때 정리한다.

**상태 디렉토리가 없으면 "예약 없음"으로 다뤄 막는다.** freeze를 한 번도 안 쓴 환경이 바로 이 훅이 막아야 할 대상이므로, 부재를 통과로 처리하면 첫 사용자에게는 이 가드가 영원히 발동하지 않는다. 부재 시 훅이 마커 디렉토리를 만드는 과정(`marker_dir.mkdir(parents=True, ...)`)에서 상태 디렉토리 자체도 함께 생성된다.

**그 외 예상 밖 상황에서는 절대 막지 않는다.** 상태 디렉토리는 있는데 읽을 수 없거나(권한, 읽기 전용 마운트), stdin JSON이 깨졌거나, 세션 마커를 쓸 수 없는 등 부재가 아닌 오류 상황에서는 조용히 통과한다. 훅 때문에 작업이 영구히 멈추는 것이 가장 나쁜 실패다.

## deny 출력 계약

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "..."
  }
}
```

`permissionDecisionReason`에는 원장 작성(`wfledger.sh init`) → 예약(`freeze.sh arm --mode ledger`) → Workflow 재호출 순서를 실제 cwd를 채운 명령줄과 함께 담는다. 2번 명령은 `--at`을 안 주면 기본값 `auto`로 땡 시각을 추정하는데, 리셋 경계 등에서 추정이 실패(`UNKNOWN`)하면 exit 1 하고 예약이 하나도 안 걸린다 — 사유에는 이때 `--at HH:MM`으로 직접 지정하라는 안내를 함께 담는다. 이 가드를 아예 끄는 법(`FREEZE_HOOK_OFF=1`)도 사유 끝에 적는다.

**세션당 한 번만 막는 계약과 arm 실패가 겹치는 경우.** 2번이 실패해 예약이 안 걸린 채로 Workflow를 다시 부르면, 이 세션은 이미 마커를 찍어놨으므로 두 번째 호출은(위 "세션당 한 번만 막는다") 그대로 통과한다 — 훅은 그 사이의 `freeze.sh arm` 실행 결과를 볼 수 없어 절차가 끝난 뒤에 마커를 찍을 방법이 없기 때문이다. 대신 통과시키는 그 순간 마커에 "이 cwd는 예약 없이 통과됐다"는 사실을 남겨두고, 다음에 같은 cwd가 새 세션에서 처음 막힐 때 사유 맨 앞에 경고 한 줄을 보탠다.

## 끄는 법

전역 킬스위치 `DISABLE_OMC`나 이 훅 전용 `FREEZE_HOOK_OFF=1` 환경변수를 세팅하면 즉시 통과한다. `install.sh --no-hooks`로 설치하면 애초에 등록되지 않는다.

## 설치

저장소 루트에서 `install.sh`를 실행하면 다른 훅들과 함께 심링크와 `settings.json` 등록을 자동으로 처리한다.

```bash
cd <저장소 루트>
bash install.sh
```
