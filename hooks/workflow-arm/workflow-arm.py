#!/usr/bin/env python3
"""PreToolUse 훅: 큰 Workflow 실행 전에 재개 예약(freeze arm)부터 걸게 강제한다.

배경 — 5시간 한도에 막히는 순간에는 handoff를 쓸 토큰조차 남지 않을 수 있다.
그래서 워크플로우를 실제로 돌리기 전, 미리 예약을 걸어두는 것만이 유일한
안전장치다. 이 훅은 그 순서를 강제한다: 예약 없이 Workflow 실행을 부르면
한 번 막고 예약 절차를 안내한다.

stdin  (JSON): { session_id, cwd, tool_name, tool_input, hook_event_name, ... }
stdout (JSON): { "hookSpecificOutput": {...} }  — deny 할 때만 출력
stderr       : 내부 오류 시 한 줄, exit 0
exit code    : 항상 0  (훅 때문에 작업이 멈추는 사고는 없어야 한다)
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------

# freeze.sh / thaw.sh 가 reservation.json에 실제로 쓰는 status 값 중 종료 상태.
# (freeze/scripts/freeze.sh, thaw.sh 를 읽고 확인함 — 추측 아님)
_TERMINAL_STATUSES = {"cancelled", "completed_early", "probe_failed", "done", "failed"}

# tool_input에 이 중 하나라도 있으면 "실행" 호출로 본다. runId만 있으면 조회·제어 호출.
_EXEC_KEYS = ("script", "scriptPath", "name")

# 세션 마커 정리 기준 — 이보다 오래된 마커는 다음 호출 때 지운다.
_MARKER_MAX_AGE = 7 * 24 * 3600

# 스테일 판정 유예 — thaw.sh 의 프로브 재시도가 기본 900s * 12회 = 3시간까지 걸릴 수
# 있고 그 구간 내내 status 는 "frozen" 그대로다. resume_at 을 넘겼다고 바로 죽었다고
# 보면 정상 프로브 중인 예약을 스테일로 오판한다 — 넉넉히 배로 잡는다.
_STALE_GRACE_SECONDS = 6 * 3600


def _err(msg: str) -> None:
    print(f"[workflow-arm] {msg}", file=sys.stderr)


def _state_root() -> Path:
    root = os.environ.get("FREEZE_STATE_DIR")
    if root:
        return Path(root)
    return Path.home() / ".local/state/freeze"


def _is_execution_call(tool_input: dict) -> bool:
    return any(k in tool_input for k in _EXEC_KEYS)


def _normalize(p: str) -> str:
    try:
        return os.path.normpath(p)
    except Exception:
        return p


def _pid_alive(pid_str: str) -> bool:
    """freeze.sh의 pid_alive와 같은 기준 — ps 상태로 본다(좀비는 죽은 것으로 취급)."""
    if not pid_str:
        return False
    try:
        pid = int(pid_str)
    except (TypeError, ValueError):
        return False
    try:
        out = subprocess.run(
            ["ps", "-o", "state=", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=2,
        )
        state = out.stdout.strip()
        return bool(state) and state[0] != "Z"
    except Exception:
        # ps 를 못 쓰는 환경 — kill(pid, 0) 으로 대체 판정(좀비를 살아있다고 오판할 수 있음)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        except Exception:
            return False
        return True


def _sleeper_pid(res_path: Path) -> str:
    # freeze.sh 는 reservation.json 과 같은 디렉토리에 sleeper.pid 를 둔다.
    try:
        return (res_path.parent / "sleeper.pid").read_text(encoding="utf-8").strip()
    except Exception:
        return ""


def _is_stale(data: dict, res_path: Path, now: float) -> bool:
    """죽은 슬리퍼가 남긴 reservation.json 인지 판정한다.

    status=running: thaw.sh 자신이 재개 세션을 물고 있는 동안엔 슬리퍼 프로세스가
    곧 재개 프로세스이므로 계속 살아있어야 한다. 죽어 있으면 무조건 스테일(재시작 등으로
    고아가 된 경우) — running 은 실행 시간이 임의로 길 수 있어 경과 시간으로는 판단 못한다.
    status=frozen: 슬리퍼가 살아있으면 스테일이 아니다. 죽어 있으면 resume_at + 프로브
    유예(_STALE_GRACE_SECONDS)를 넘겼을 때만 스테일로 본다 — resume_at 전에 슬리퍼가
    죽은 경우(예: 재시작)까지 성급하게 스테일로 잡으면, 아직 정상적으로 살아날 수 있는
    예약을 무예약으로 오판해 이 훅이 엉뚱하게 다시 발동한다. 대가도 있다: 재시작으로
    슬리퍼가 resume_at 전에 죽으면 그 예약은 (resume_at까지 남은 시간 + 유예) 동안
    계속 "활성"으로 남아, 그 cwd에 대한 workflow-arm 가드 자체가 그 구간만큼 잠든다 —
    thaw.sh가 그 예약을 끝내 못 살려도(진짜 고아여도) 스테일 판정이 나기 전까지는
    Workflow 호출이 그냥 통과한다.
    """
    status = data.get("status", "")
    alive = _pid_alive(_sleeper_pid(res_path))
    if alive:
        return False
    if status == "running":
        return True
    if status == "frozen":
        try:
            resume_at = float(data.get("resume_at"))
        except (TypeError, ValueError):
            return True  # resume_at 도 없고 슬리퍼도 죽음 — 스테일
        return (now - resume_at) > _STALE_GRACE_SECONDS
    # 알려지지 않은 상태값 — 보수적으로 활성 취급(스테일 아님)
    return False


def _has_active_reservation(state_root: Path, cwd: str) -> bool:
    """cwd가 일치하고, 종료 상태가 아니며, 스테일도 아닌 reservation.json이 하나라도 있으면 True."""
    target = _normalize(cwd)
    now = time.time()
    for res_path in state_root.glob("*/reservation.json"):
        try:
            data = json.loads(res_path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(data, dict):
            continue
        if _normalize(str(data.get("cwd", ""))) != target:
            continue
        status = data.get("status", "")
        if status in _TERMINAL_STATUSES:
            continue
        if _is_stale(data, res_path, now):
            continue
        return True
    return False


def _session_marker_dir(state_root: Path) -> Path:
    # freeze.sh의 job 디렉토리(<STATE_ROOT>/<job>/reservation.json)와 겹치지 않는
    # 별도 하위 디렉토리. reservation.json이 없으므로 위 glob에도 걸리지 않는다.
    return state_root / "workflow-arm-sessions"


def _cleanup_old_markers(marker_dir: Path) -> None:
    try:
        if not marker_dir.exists():
            return
        now = time.time()
        for f in marker_dir.iterdir():
            try:
                if now - f.stat().st_mtime > _MARKER_MAX_AGE:
                    f.unlink()
            except Exception:
                continue
    except Exception:
        pass


def _mark_denied(marker_dir: Path, session_id: str, cwd: str) -> str:
    """세션 마커를 원자적으로(O_EXCL) 만들어 "이 턴에서 deny할 차례가 누구인지"를 정한다.

    반환값 셋 중 하나:
      "first"   — 이번 호출이 마커를 새로 만들었다 → 이번 호출이 deny한다.
      "already" — 마커가 이미 있었다(이전 호출이 이미 deny했거나, 같은 턴에서 병렬로
                  나간 다른 Workflow 호출이 방금 먼저 만들었다) → 통과.
      "error"   — 상태 디렉토리에 아예 쓸 수 없다(읽기 전용 마운트, 디스크 풀, 권한
                  문제) → 통과. deny하면 이후 어떤 세션도 마커를 남길 수 없어 Workflow가
                  영구히 막힌다 — 훅 때문에 작업이 멈추는 것이 가장 나쁜 실패다.

    O_EXCL로 "마커 부재 확인"과 "마커 생성"을 한 시스템 콜로 합치는 이유: 두 단계로
    나뉘어 있으면(있는지 보고 → 없으면 쓴다) 한 턴에서 병렬로 나간 Workflow 호출 두
    개가 둘 다 부재를 보고 둘 다 deny해버린다("세션당 한 번" 계약 위반).

    마커 내용은 타임스탬프 하나가 아니라 {"ts", "cwd", "unarmed"} JSON이다. cwd를
    같이 심어야 나중에 "이 cwd에서 예약 없이 통과된 적이 있는가"를 다른 세션의 마커까지
    훑어 판정할 수 있다(_has_prior_unarmed_passthrough 참고). "unarmed"는 처음엔
    False로 시작해 _record_unarmed_passthrough가 필요할 때만 True로 덮어쓴다.
    """
    try:
        marker_dir.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        _err(f"세션 마커 디렉토리 생성 실패: {exc}")
        return "error"

    marker_path = marker_dir / session_id
    try:
        fd = os.open(str(marker_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        return "already"
    except Exception as exc:
        _err(f"세션 마커 기록 실패: {exc}")
        return "error"

    payload = json.dumps({"ts": time.time(), "cwd": _normalize(cwd), "unarmed": False})
    try:
        os.write(fd, payload.encode("utf-8"))
    finally:
        os.close(fd)
    return "first"


def _record_unarmed_passthrough(marker_dir: Path, session_id: str) -> None:
    """"이미 한 번 막힌 세션인데도 여전히 활성 예약이 없다"를 마커에 남긴다.

    major 재현: deny 사유의 2번 명령(`freeze.sh arm ... `, --at 기본값 auto)이
    cmd_estimate UNKNOWN(리셋 경계, HUD 캐시 없음)에서 exit 1 하고 reservation.json을
    하나도 안 만든다. 하지만 이 훅은 이미 첫 호출에서 세션 마커를 찍어뒀으므로, 다음
    Workflow 호출은 "already"로 그냥 통과한다 — 훅이 막으려던 무예약 실행이 조건부로
    되살아난다.

    정공법(마커를 deny 시점이 아니라 절차가 실제로 끝난 뒤 찍는 것)은 이 훅의 구조상
    안 된다: 이 훅은 PreToolUse:Workflow에만 걸리고, 그 사이에 에이전트가 실행하는
    `freeze.sh arm` 같은 Bash 호출은 전혀 못 본다. arm이 성공했는지 실패했는지 알 수
    있는 유일한 관측 지점은 "다음 Workflow 호출 시점의 _has_active_reservation() 값"
    뿐이고, 그마저도 그 다음 Workflow 호출이 언제 올지(혹은 영영 안 올지) 훅이 정할 수
    없다. 그래서 정공법 대신 이 차선책을 쓴다: 세션당 한 번만 deny하는 계약은 유지하되
    (그래야 훅 자체 오판으로 Workflow가 영구히 막히는 사고를 피한다), 통과시키는 이
    순간을 마커에 기록해 "다음에 이 cwd를 다시 볼 deny 사유"(대개 다음 세션의 첫
    호출)에 경고를 보탠다 — _has_prior_unarmed_passthrough 참고.

    베스트에포트 — 실패해도 무시한다. 이 훅은 항상 exit 0이어야 한다.
    """
    marker_path = marker_dir / session_id
    try:
        data = json.loads(marker_path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return
        data["unarmed"] = True
        marker_path.write_text(json.dumps(data), encoding="utf-8")
    except Exception:
        pass


def _has_prior_unarmed_passthrough(marker_dir: Path, cwd: str) -> bool:
    """이 cwd에 대해 "예약 없이 통과된" 마커가 하나라도 있으면 True.

    session_id별로 나뉜 마커 파일들을 전부 훑는다 — 이번 호출은 아직 자기 마커를
    만들기 전(첫 deny 시도)이므로 여기서 걸리는 건 전부 다른(대개 이전) 세션의 기록이다.
    """
    target = _normalize(cwd)
    try:
        if not marker_dir.exists():
            return False
        for f in marker_dir.iterdir():
            try:
                data = json.loads(f.read_text(encoding="utf-8"))
            except Exception:
                continue
            if not isinstance(data, dict):
                continue
            if data.get("unarmed") and _normalize(str(data.get("cwd", ""))) == target:
                return True
    except Exception:
        pass
    return False


def _deny(reason: str) -> None:
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    print(json.dumps(payload, ensure_ascii=False))


def _build_reason(cwd: str, marker_dir: Path | None = None) -> str:
    ledger = f"{cwd}/.omc/handoffs/wfledger-<job>.md"
    warn = ""
    if marker_dir is not None and _has_prior_unarmed_passthrough(marker_dir, cwd):
        warn = (
            "[workflow-arm] 주의: 이 작업 디렉토리는 이전 세션에서 2번이 실패해 "
            "예약 없이 Workflow가 통과된 적이 있다. 이번엔 2번 명령이 실제로 성공했는지"
            "(reservation.json 생성)까지 확인한 뒤에 Workflow를 다시 불러라.\n"
        )
    return (
        warn
        + "[workflow-arm] 큰 Workflow를 돌리기 전에 재개 예약부터 걸어라. "
        "<job> 자리에는 이번 작업을 가리킬 이름 하나를 정해 아래 두 명령에 동일하게 써라.\n"
        f"1) 원장 작성: bash ~/.claude/skills/freeze/scripts/wfledger.sh init --cwd \"{cwd}\" "
        "--job <job> --summary \"<이번 작업을 한 줄로 요약>\"\n"
        "2) 예약: bash ~/.claude/skills/freeze/scripts/freeze.sh arm --mode ledger "
        f"--cwd \"{cwd}\" --handoff \"{ledger}\"\n"
        "   2번이 \"땡 시각 추정 실패\"로 exit 1 하면(리셋 경계 등 --at auto가 UNKNOWN을 "
        "내는 경우) 예약이 하나도 안 걸린 채로 끝난다 — --at HH:MM 을 추가해 시각을 "
        "직접 지정해라. 예: --at 18:00\n"
        "3) 예약이 걸린 뒤에 Workflow를 다시 호출해라.\n"
        # 4) 없이 끝내면 Workflow가 정상 종료돼도 예약이 살아있는 채로 남는다 —
        # 완료 신호(done)를 안 남기면 리셋 시각에 이미 끝난 작업을 헤드리스로
        # 다시 열어버린다. 이 훅이 절차를 1~3으로만 안내한 탓에, 훅에 막혀 예약을
        # 건 세션은 해제 방법을 안내받은 적이 아예 없었다(2026-08-28 코드 감사).
        "4) Workflow가 끝나고 작업이 완료되면 반드시 완료 신호를 남겨라 — 안 남기면 예약이 "
        "살아남아 땡 시각에 이미 끝난 작업을 다시 연다:\n"
        f"   bash ~/.claude/skills/freeze/scripts/freeze.sh done --handoff \"{ledger}\"\n"
        "이 가드가 필요 없으면 FREEZE_HOOK_OFF=1 로 꺼라."
    )


def main() -> None:
    # 킬스위치 — 전역 DISABLE_OMC, 이 훅 전용 FREEZE_HOOK_OFF=1
    if os.environ.get("DISABLE_OMC") or os.environ.get("FREEZE_HOOK_OFF") == "1":
        sys.exit(0)

    try:
        raw = sys.stdin.read()
        inp = json.loads(raw)
    except Exception as exc:
        _err(f"stdin parse failed: {exc}")
        sys.exit(0)

    try:
        if not isinstance(inp, dict):
            sys.exit(0)

        if inp.get("tool_name", "") != "Workflow":
            sys.exit(0)

        tool_input = inp.get("tool_input", {})
        if not isinstance(tool_input, dict) or not _is_execution_call(tool_input):
            # runId만 있는 조회·제어 호출이거나 형식을 알 수 없는 입력 — 통과
            sys.exit(0)

        session_id = str(inp.get("session_id", ""))
        cwd = str(inp.get("cwd", "") or tool_input.get("cwd", ""))
        if not cwd or not session_id:
            sys.exit(0)

        state_root = _state_root()
        # 상태 디렉토리 부재는 "예약 없음"으로 다룬다 — freeze 를 한 번도 안 쓴 환경이
        # 바로 이 훅이 막아야 할 대상이므로 여기서 통과시키면 훅이 첫 사용자에게는
        # 영원히 발동하지 않는다. 반대로 디렉토리는 있는데 읽을 수 없는 경우(권한 오류,
        # 읽기 전용 마운트 등)는 부재와 다르게 취급해 통과시킨다 — 부재와 오류를 구분한다.
        if state_root.exists():
            try:
                os.listdir(state_root)
            except OSError as exc:
                _err(f"상태 디렉토리 접근 실패: {exc}")
                sys.exit(0)

        if _has_active_reservation(state_root, cwd):
            sys.exit(0)

        marker_dir = _session_marker_dir(state_root)
        _cleanup_old_markers(marker_dir)

        mark_result = _mark_denied(marker_dir, session_id, cwd)
        if mark_result != "first":
            # "already"(이 세션은 이미 한 번 막혔다 / 병렬 호출 중 다른 쪽이 먼저 막았다)
            # 이거나 "error"(마커를 못 남김) — 어느 쪽이든 이번 호출은 통과시킨다.
            # "already"인 경우 위의 _has_active_reservation() 검사를 이미 통과 못했다는
            # 뜻(그랬으면 여기까지 오지 않고 먼저 return했다) — 즉 지금 이 통과는 여전히
            # 무예약 상태라는 뜻이다. 그 사실을 마커에 남겨 다음에 이 cwd를 볼 deny
            # 사유에 경고를 보탠다.
            if mark_result == "already":
                _record_unarmed_passthrough(marker_dir, session_id)
            sys.exit(0)

        _deny(_build_reason(cwd, marker_dir))
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        _err(f"internal error: {exc}")
        sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    main()
