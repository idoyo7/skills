#!/usr/bin/env python3
"""workflow-arm.py 유닛 테스트.

케이스:
1. tool_name이 Workflow가 아니면 통과 (출력 없음)
2. runId만 있는 조회·제어 호출은 통과
3. 활성 예약(cwd 일치, 종료 상태 아님)이 있으면 통과
4. 예약이 없으면 deny JSON을 정확한 계약대로 출력
5. 같은 세션 두 번째 호출은 통과 (한 세션당 한 번만 deny)
6. 상태 디렉토리가 없으면 통과
7. 잘못된 JSON stdin은 통과 (exit 0, stderr 한 줄)
8. 킬스위치(DISABLE_OMC, FREEZE_HOOK_OFF)면 통과
9. arm이 실패해(UNKNOWN 등) 예약이 안 걸린 채로 두 번째 Workflow 호출이 오면
   여전히 통과하되(세션당 한 번 계약 유지), 마커에 "예약 없이 통과됨"을 남긴다
10. 9번이 남긴 마커가 있으면, 같은 cwd의 새 세션 첫 deny 사유에 경고가 붙는다
11. deny 사유에 --at HH:MM 대안과 FREEZE_HOOK_OFF 킬스위치 안내가 들어있다
12. deny 사유 4)에 완료 신호(freeze.sh done --handoff) 안내가 있고, 그 handoff
    경로가 2)의 --handoff 경로와 동일하다 (안 맞으면 예약을 못 해제한다)
"""
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

_HOOK = Path(__file__).resolve().parent.parent / "workflow-arm.py"

if not _HOOK.exists():
    _HOOK = Path.home() / ".claude/hooks/workflow-arm.py"

spec = importlib.util.spec_from_file_location("workflow_arm", str(_HOOK))
assert spec and spec.loader, f"workflow-arm.py not found at {_HOOK}"
_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(_mod)  # type: ignore[union-attr]


def _run(payload: dict) -> tuple[str, str, int]:
    """workflow_arm.main을 stdin/stdout/stderr 캡처해 실행한다.
    Returns (stdout_text, stderr_text, exit_code).
    """
    stdin_text = json.dumps(payload) if not isinstance(payload, str) else payload
    stdout_buf = io.StringIO()
    stderr_buf = io.StringIO()

    exit_code = 0
    with (
        patch("sys.stdin", io.StringIO(stdin_text)),
        patch("sys.stdout", stdout_buf),
        patch("sys.stderr", stderr_buf),
    ):
        try:
            _mod.main()
        except SystemExit as e:
            exit_code = int(e.code or 0)

    return stdout_buf.getvalue(), stderr_buf.getvalue(), exit_code


def _write_reservation(
    state_root: Path,
    job: str,
    cwd: str,
    status: str,
    *,
    pid=None,
    resume_at=None,
) -> Path:
    """reservation.json(+옵션으로 sleeper.pid)을 만든다.

    pid 를 주면 workflow-arm.py 의 스테일 판정이 보는 <job>/sleeper.pid 도 함께 쓴다.
    pid=None(기본)은 "슬리퍼 파일 자체가 없음" 상태를 나타낸다.
    """
    d = state_root / job
    d.mkdir(parents=True, exist_ok=True)
    data = {"job": job, "cwd": cwd, "status": status}
    if resume_at is not None:
        data["resume_at"] = resume_at
    (d / "reservation.json").write_text(json.dumps(data), encoding="utf-8")
    if pid is not None:
        (d / "sleeper.pid").write_text(str(pid), encoding="utf-8")
    return d


def _dead_pid() -> int:
    """실제로 막 죽은 pid 를 만들어 돌려준다 — 임의의 큰 숫자보다 결정적이다."""
    p = subprocess.Popen(["true"])
    p.wait()
    return p.pid


class TestWorkflowArm(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_root = Path(self._tmp.name)
        self._env_patch = patch.dict(
            os.environ,
            {"FREEZE_STATE_DIR": str(self.state_root)},
            clear=False,
        )
        self._env_patch.start()
        # 킬스위치가 실수로 켜져 있으면 테스트가 전부 무의미해지므로 명시적으로 끈다
        os.environ.pop("DISABLE_OMC", None)
        os.environ.pop("FREEZE_HOOK_OFF", None)

    def tearDown(self):
        self._env_patch.stop()
        self._tmp.cleanup()

    # ── 케이스 1: 다른 툴은 통과 ────────────────────────────────────────
    def test_other_tool_passes(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Bash",
            "tool_input": {"command": "ls"},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")

    # ── 케이스 2: runId만 있는 조회 호출은 통과 ────────────────────────
    def test_runid_only_query_passes(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"runId": "wf_abc123"},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")

    # ── 케이스 3: 활성 예약이 있으면 통과 ──────────────────────────────
    def test_active_reservation_passes(self):
        _write_reservation(self.state_root, "job1", "/repo", "frozen", pid=os.getpid())
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": "console.log(1)", "name": "big-job"},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")

    def test_running_status_counts_as_active(self):
        _write_reservation(self.state_root, "job1", "/repo", "running", pid=os.getpid())
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"name": "big-job"},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")

    # ── 스테일 예약: running + 죽은 슬리퍼는 즉시 스테일 ───────────────
    def test_running_status_with_dead_sleeper_is_stale(self):
        # 재개 도중 머신이 재시작되면 reservation.json 은 status=running 으로 굳는다.
        # 슬리퍼(=재개 프로세스 자신)가 죽었으면 running 이 얼마나 됐든 무조건 고아다.
        _write_reservation(
            self.state_root, "job1", "/repo", "running", pid=_dead_pid(), resume_at=time.time()
        )
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"name": "big-job"},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        data = json.loads(stdout.strip())
        self.assertEqual(
            data["hookSpecificOutput"]["permissionDecision"],
            "deny",
            "죽은 슬리퍼의 running 예약이 가드를 영구 무력화하면 안 된다",
        )

    # ── 스테일 예약: frozen + 죽은 슬리퍼 + resume_at 한참 경과 ────────
    def test_frozen_reservation_long_overdue_with_dead_sleeper_is_stale(self):
        _write_reservation(
            self.state_root,
            "job1",
            "/repo",
            "frozen",
            pid=_dead_pid(),
            resume_at=time.time() - (7 * 3600),  # 유예(6h)를 넘김
        )
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"name": "big-job"},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        data = json.loads(stdout.strip())
        self.assertEqual(
            data["hookSpecificOutput"]["permissionDecision"], "deny"
        )

    # ── frozen + 죽은 슬리퍼라도 유예 안이면 아직 스테일 아님(프로브 구간일 수 있음) ──
    def test_frozen_reservation_within_grace_after_dead_sleeper_still_active(self):
        _write_reservation(
            self.state_root,
            "job1",
            "/repo",
            "frozen",
            pid=_dead_pid(),
            resume_at=time.time() - 60,  # 방금 지남 — 프로브 유예 안
        )
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"name": "big-job"},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")

    def test_terminal_status_does_not_count(self):
        _write_reservation(self.state_root, "job1", "/repo", "done")
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"name": "big-job"},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        data = json.loads(stdout.strip())
        self.assertEqual(
            data["hookSpecificOutput"]["permissionDecision"], "deny"
        )

    def test_reservation_for_other_cwd_does_not_count(self):
        _write_reservation(self.state_root, "job1", "/other-repo", "frozen")
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"name": "big-job"},
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(
            data["hookSpecificOutput"]["permissionDecision"], "deny"
        )

    # ── 케이스 4: 예약 없으면 deny JSON 정확히 ─────────────────────────
    def test_no_reservation_denies_with_exact_contract(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"scriptPath": "/tmp/x.js"},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        data = json.loads(stdout.strip())
        hso = data["hookSpecificOutput"]
        self.assertEqual(hso["hookEventName"], "PreToolUse")
        self.assertEqual(hso["permissionDecision"], "deny")
        self.assertIn("freeze.sh arm", hso["permissionDecisionReason"])
        self.assertIn("wfledger.sh init", hso["permissionDecisionReason"])
        self.assertIn("/repo", hso["permissionDecisionReason"])

    # ── 케이스 5: 같은 세션 두 번째 호출은 통과 ────────────────────────
    def test_second_call_same_session_passes(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"name": "big-job"},
        }
        stdout1, _, code1 = _run(payload)
        data1 = json.loads(stdout1.strip())
        self.assertEqual(data1["hookSpecificOutput"]["permissionDecision"], "deny")

        stdout2, _, code2 = _run(payload)
        self.assertEqual(code2, 0)
        self.assertEqual(stdout2.strip(), "", "같은 세션 두 번째 호출은 통과해야 한다")

        # 다른 세션이면 다시 막혀야 한다
        payload3 = dict(payload, session_id="s2")
        stdout3, _, code3 = _run(payload3)
        data3 = json.loads(stdout3.strip())
        self.assertEqual(data3["hookSpecificOutput"]["permissionDecision"], "deny")

    # ── 케이스 6: 상태 디렉토리 부재는 "예약 없음"으로 다뤄 계속 막는다 ──
    # (예전 계약은 부재 시 무조건 통과였다 — freeze 를 한 번도 안 쓴 환경, 즉 이 훅의
    #  실제 대상에서 가드가 영원히 발동하지 않는 구멍이었다. 부재와 읽기 오류는 구분한다.)
    def test_missing_state_dir_denies(self):
        missing = Path(self._tmp.name) / "does-not-exist"
        with patch.dict(os.environ, {"FREEZE_STATE_DIR": str(missing)}):
            payload = {
                "session_id": "s1",
                "cwd": "/repo",
                "tool_name": "Workflow",
                "tool_input": {"name": "big-job"},
            }
            stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        data = json.loads(stdout.strip())
        self.assertEqual(
            data["hookSpecificOutput"]["permissionDecision"],
            "deny",
            "freeze 를 한 번도 안 쓴 환경(상태 디렉토리 없음)이야말로 이 훅의 대상이다",
        )
        # 부재였을 뿐 상태 디렉토리는 훅이 만들어(마커 기록용) 존재하게 된다
        self.assertTrue(missing.exists())

    # ── 상태 디렉토리가 있지만 읽을 수 없으면(권한 오류) 통과 — 부재와 다르다 ──
    def test_unreadable_state_dir_passes(self):
        if os.geteuid() == 0:
            self.skipTest("root 는 권한 비트를 무시해 이 케이스를 재현할 수 없음")
        unreadable = Path(self._tmp.name) / "unreadable"
        unreadable.mkdir()
        os.chmod(unreadable, 0o000)
        try:
            with patch.dict(os.environ, {"FREEZE_STATE_DIR": str(unreadable)}):
                payload = {
                    "session_id": "s1",
                    "cwd": "/repo",
                    "tool_name": "Workflow",
                    "tool_input": {"name": "big-job"},
                }
                stdout, stderr, code = _run(payload)
            self.assertEqual(code, 0)
            self.assertEqual(
                stdout.strip(), "", "읽을 수 없는 상태 디렉토리는 부재가 아니라 오류로 통과해야 한다"
            )
        finally:
            os.chmod(unreadable, 0o755)

    # ── 케이스 7: 잘못된 JSON이면 통과 ─────────────────────────────────
    def test_broken_json_passes(self):
        stdout, stderr, code = _run("{ broken json :::")
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")
        self.assertGreater(len(stderr.strip()), 0)

    # ── 케이스 8: 킬스위치 ──────────────────────────────────────────────
    def test_disable_omc_killswitch(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"name": "big-job"},
        }
        with patch.dict(os.environ, {"DISABLE_OMC": "1"}):
            stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")

    def test_freeze_hook_off_killswitch(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"name": "big-job"},
        }
        with patch.dict(os.environ, {"FREEZE_HOOK_OFF": "1"}):
            stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")

    # ── 케이스 9: tool_input이 딕셔너리가 아니거나 실행 키가 없으면 통과 ──
    def test_no_exec_keys_passes(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"someOtherField": 1},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")

    # ── 마커 기록 실패는 deny 가 아니라 통과여야 한다 ───────────────────
    # (리뷰 blocker: chmod 500 으로 상태 디렉토리 쓰기를 막으면 모든 세션에서
    #  영구히 deny 됐다 — 훅 때문에 작업이 멈추는 최악의 실패)
    def test_marker_write_failure_passes_instead_of_denying(self):
        if os.geteuid() == 0:
            self.skipTest("root 는 권한 비트를 무시해 이 케이스를 재현할 수 없음")
        os.chmod(self.state_root, 0o555)  # 읽기+탐색은 되지만 쓰기(마커 디렉토리 생성)는 안 됨
        try:
            payload = {
                "session_id": "s1",
                "cwd": "/repo",
                "tool_name": "Workflow",
                "tool_input": {"name": "big-job"},
            }
            stdout, stderr, code = _run(payload)
            self.assertEqual(code, 0)
            self.assertEqual(
                stdout.strip(),
                "",
                "마커를 못 남기면 deny 하지 말고 통과시켜야 한다 — "
                "안 그러면 모든 세션에서 Workflow 가 영구히 막힌다",
            )
            # 같은 조건에서 다른 세션이 다시 불러도 계속 통과해야 한다(영구 deny 로 안 굳음)
            stdout2, _, code2 = _run(dict(payload, session_id="s2"))
            self.assertEqual(code2, 0)
            self.assertEqual(stdout2.strip(), "")
        finally:
            os.chmod(self.state_root, 0o755)

    # ── 세션 마커 원자성: 이미 있으면 "already", 새로 만들면 "first" ────
    def test_mark_denied_atomic_contract(self):
        marker_dir = self.state_root / "workflow-arm-sessions"
        self.assertEqual(_mod._mark_denied(marker_dir, "s1", "/repo"), "first")
        # 두 번째 호출(동시 호출이 먼저 만들었거나, 이전 턴의 재확인) — 다시 deny 하면 안 됨
        self.assertEqual(_mod._mark_denied(marker_dir, "s1", "/repo"), "already")
        self.assertTrue((marker_dir / "s1").exists())

    # ── major 재현: arm이 실패해 예약이 안 걸려도 세션당 한 번 계약은 유지하되,
    #    "예약 없이 통과됐다"를 마커에 남겨 다음 세션에 경고를 넘긴다 ──────────
    def test_arm_failure_still_passes_but_records_unarmed_marker(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"name": "big-job"},
        }
        stdout1, _, code1 = _run(payload)
        data1 = json.loads(stdout1.strip())
        self.assertEqual(data1["hookSpecificOutput"]["permissionDecision"], "deny")

        # 재현: 사유가 안내한 arm이 UNKNOWN 추정 실패로 죽어 reservation.json이 하나도
        # 안 생긴 상태 — 즉 이 tmp state_root에는 여전히 활성 예약이 전혀 없다.
        self.assertFalse(
            list(self.state_root.glob("*/reservation.json")),
            "재현 전제: 이 시점엔 reservation.json이 없어야 한다",
        )

        stdout2, _, code2 = _run(payload)
        self.assertEqual(code2, 0)
        self.assertEqual(
            stdout2.strip(), "", "세션당 한 번 계약은 유지 — 두 번째 호출도 통과해야 한다"
        )

        marker = json.loads(
            (self.state_root / "workflow-arm-sessions" / "s1").read_text(encoding="utf-8")
        )
        self.assertTrue(
            marker.get("unarmed"), "예약 없이 통과됐다는 사실이 마커에 남아야 한다"
        )
        self.assertEqual(marker.get("cwd"), os.path.normpath("/repo"))

    def test_prior_unarmed_passthrough_adds_warning_for_new_session(self):
        marker_dir = self.state_root / "workflow-arm-sessions"
        marker_dir.mkdir(parents=True, exist_ok=True)
        (marker_dir / "old-session").write_text(
            json.dumps({"ts": time.time(), "cwd": os.path.normpath("/repo"), "unarmed": True}),
            encoding="utf-8",
        )

        payload = {
            "session_id": "s-new",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"name": "big-job"},
        }
        stdout, _, code = _run(payload)
        reason = json.loads(stdout.strip())["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertIn("예약 없이 Workflow가 통과된 적이 있다", reason)

        # 다른 cwd 의 unarmed 기록은 이 cwd 의 사유에 새지 않는다
        (marker_dir / "other-cwd-session").write_text(
            json.dumps({"ts": time.time(), "cwd": "/elsewhere", "unarmed": True}),
            encoding="utf-8",
        )
        payload2 = dict(payload, session_id="s-new-2", cwd="/another-repo")
        stdout2, _, _ = _run(payload2)
        reason2 = json.loads(stdout2.strip())["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertNotIn("예약 없이 Workflow가 통과된 적이 있다", reason2)

    def test_deny_reason_has_at_fallback_and_killswitch_note(self):
        reason = _mod._build_reason("/repo")
        self.assertIn("--at HH:MM", reason)
        self.assertIn("FREEZE_HOOK_OFF=1", reason)

    # ── 완료 신호 누락 회귀: 1)~3)만 안내하면 예약을 건 세션이 끝나도 해제가
    # 안 남아, 리셋 시각에 이미 끝난 작업이 헤드리스로 다시 열린다. 4)가
    # freeze.sh done을 안내하는지, 그 handoff 경로가 2)의 --handoff와
    # 실제로 같은 문자열인지(다르면 done이 대상을 못 찾는다)를 확인한다.
    def test_deny_reason_mentions_done_with_matching_handoff(self):
        cwd = "/repo"
        reason = _mod._build_reason(cwd)
        self.assertIn("freeze.sh done", reason)
        self.assertIn("--handoff", reason)

        lines = reason.splitlines()
        step2 = next(l for l in lines if l.startswith("2) "))
        step4 = next(l for l in lines if l.startswith("4) "))
        done_line = next(l for l in lines[lines.index(step4) :] if "freeze.sh done" in l)

        handoff2 = step2.split("--handoff ", 1)[1].strip()
        handoff4 = done_line.split("--handoff ", 1)[1].strip()
        self.assertEqual(
            handoff2,
            handoff4,
            "2) 예약과 4) 완료 신호의 --handoff 경로가 달라 done이 예약을 못 찾는다",
        )

    # ── blocker 1 회귀 재현: deny 사유가 안내하는 절차를 문자 그대로 실행 ──
    # 문자열 포함 여부만 보면(예: "wfledger.sh init" 이 들어있는지) --summary 같은
    # 필수 인자 누락을 못 잡는다 — 실제로 실행해서 원장이 생기고 예약이 걸리는지 본다.
    def test_deny_reason_procedure_actually_executes(self):
        repo_root = _HOOK.resolve().parent.parent.parent
        wfledger = repo_root / "freeze/scripts/wfledger.sh"
        freeze_sh = repo_root / "freeze/scripts/freeze.sh"
        if not wfledger.exists() or not freeze_sh.exists():
            self.skipTest(f"freeze 스크립트를 찾을 수 없음: {wfledger} / {freeze_sh}")

        with tempfile.TemporaryDirectory() as td:
            cwd = td
            job = "myjob"
            reason = _mod._build_reason(cwd)
            lines = reason.splitlines()
            step1 = next(l for l in lines if l.startswith("1) "))
            step2 = next(l for l in lines if l.startswith("2) "))
            cmd1 = step1.split("원장 작성: ", 1)[1]
            cmd2 = step2.split("예약: ", 1)[1]

            # 사유 문구는 install.sh 가 심링크해 둔 ~/.claude/skills 경로를 전제한다.
            # 여기서는 그 심링크 없이도 같은 인자 조합이 실제로 통하는지만 검증하므로
            # 스크립트 경로만 리포 안 실제 경로로 바꾸고 <job> 을 채운다 — 그 외 플래그는
            # 훅이 실제로 출력하는 문자열 그대로 실행한다.
            cmd1 = cmd1.replace(
                "~/.claude/skills/freeze/scripts/wfledger.sh", str(wfledger)
            ).replace("<job>", job)
            cmd2 = cmd2.replace(
                "~/.claude/skills/freeze/scripts/freeze.sh", str(freeze_sh)
            ).replace("<job>", job)

            env = dict(os.environ)
            env["FREEZE_STATE_DIR"] = str(Path(td) / ".state")
            env["CLAUDE_PROJECTS_DIR"] = str(Path(td) / ".projects")
            env["FREEZE_CLAUDE_BIN"] = "/bin/true"  # 슬리퍼가 프로브 없이 바로 끝나게

            slug = "".join(c if (c.isalnum() or c == "-") else "-" for c in cwd)
            proj_dir = Path(env["CLAUDE_PROJECTS_DIR"]) / slug
            proj_dir.mkdir(parents=True, exist_ok=True)
            (proj_dir / "sess-fake.jsonl").write_text(
                '{"type":"queue-operation"}\n', encoding="utf-8"
            )

            try:
                r1 = subprocess.run(
                    cmd1, shell=True, capture_output=True, text=True, env=env, timeout=30
                )
                self.assertEqual(
                    r1.returncode,
                    0,
                    f"1단계(원장 작성)가 실패했다 — 사유의 명령 그대로는 원장이 안 생긴다\n"
                    f"cmd: {cmd1}\nstdout: {r1.stdout}\nstderr: {r1.stderr}",
                )
                ledger_path = f"{cwd}/.omc/handoffs/wfledger-{job}.md"
                self.assertTrue(
                    Path(ledger_path).exists(), f"원장 파일이 생성되지 않음: {ledger_path}"
                )

                r2 = subprocess.run(
                    cmd2, shell=True, capture_output=True, text=True, env=env, timeout=30
                )
                self.assertEqual(
                    r2.returncode,
                    0,
                    f"2단계(예약)가 실패했다 — 원장은 생겼는데 예약이 안 걸린다\n"
                    f"cmd: {cmd2}\nstdout: {r2.stdout}\nstderr: {r2.stderr}",
                )

                res_files = list(Path(env["FREEZE_STATE_DIR"]).glob("*/reservation.json"))
                self.assertTrue(res_files, "예약(reservation.json)이 실제로 생성되지 않음")
                data = json.loads(res_files[0].read_text(encoding="utf-8"))
                self.assertEqual(data.get("mode"), "ledger")
            finally:
                # 슬리퍼 정리 — 백그라운드로 뜬 thaw.sh 를 남겨두지 않는다
                for res in Path(env["FREEZE_STATE_DIR"]).glob("*/reservation.json"):
                    try:
                        job_name = json.loads(res.read_text(encoding="utf-8")).get("job")
                        if job_name:
                            subprocess.run(
                                ["bash", str(freeze_sh), "cancel", job_name],
                                env=env,
                                capture_output=True,
                                timeout=10,
                            )
                    except Exception:
                        pass


if __name__ == "__main__":
    unittest.main(verbosity=2)
