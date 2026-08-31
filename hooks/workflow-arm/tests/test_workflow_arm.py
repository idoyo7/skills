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

TestScaleGate — 서브에이전트 규모 게이트(S3):
13. 추정 서브에이전트 수가 임계값 이하면 통과하고 세션 마커도 남기지 않는다
14. 임계값을 넘으면 막는다(사유에 추정 개수가 들어간다)
15. 팬아웃 대상(map/parallel/pipeline 리시버·인자)을 정적으로 못 세면 막는다
16. scriptPath로 준 파일을 읽어 판정하고, 파일이 없으면 통과한다
17. FREEZE_HOOK_AGENT_THRESHOLD로 임계값을 바꿀 수 있다
18. parallel/pipeline은 표준 API라 팬아웃 대상(인라인 배열 리터럴, const/let/var 배열
    식별자)의 크기를 셀 수 있으면 그 크기로만 추정하고, 작으면 통과한다
19. 속성 접근·함수 호출 결과 위의 팬아웃은 크기를 알 수 없어 막는다
20. 배열 원소 수는 중첩 배열/객체·문자열 안 콤마에 흔들리지 않고 깊이 인식으로 정확히
    센다
21. for/for await/while 루프는 무조건 막는다
22. 팬아웃이 중첩되면(팬아웃 안에 또 팬아웃) 곱으로 누적한다(10×10 → 100)
23. parallel(X.map(...)) 같은 pass-through는 곱하지 않고 안쪽 크기 그대로 쓴다
24. 배열 리터럴 안 spread(`...items`, `...Array(100)`)는 크기를 셀 수 없는 것으로 막는다
25. 주석·문자열 리터럴 안의 for(/.map( 패턴은 지우고 판정해 오탐하지 않는다
26. 정규식 리터럴 안의 따옴표(`/['"]/ `, `/don't/`)를 문자열 여는 따옴표로 오인해
    뒤따르는 팬아웃을 통째로 지우면 안 된다(BLOCKER D)
27. 정규식 리터럴 안의 `//`(`/\\/\\//`)를 줄 주석으로 오인해 같은 줄의 팬아웃을
    지우면 안 된다
28. 괄호 짝이 안 맞는 정규식 리터럴(`/[({]/`)이 괄호 깊이 계산을 어긋나게 하면
    안 된다
29. 나눗셈(`total / count`)을 정규식 리터럴로 오인해 지우면 안 된다
30. 정규식 리터럴 안의 `agent(` 문자열은 실제 호출로 세면 안 된다
31. `Array.from(`/`new Array(`/`.fill(`/`.reduce(`/`Promise.all(`/`Promise.allSettled(`
    은 이 파일이 아는 팬아웃 마커 다섯 개(parallel/pipeline/.map/.forEach/.flatMap)
    밖이므로 무조건 셀 수 없음으로 막는다
32. point-free(`specs.map(agent)`처럼 agent 를 함수 참조로만 넘기는 형태)는
    `agent(` 호출 형태로 안 잡히므로 무조건 셀 수 없음으로 막는다
33. 배열 이름이 두 번 이상 선언되거나(다른 스코프의 동명 변수 포함), 선언 뒤
    재대입되거나 push/concat/splice/unshift 로 변형되면 선언 시점 크기를 못
    믿으므로 셀 수 없음으로 막는다 — 재선언·재대입·변형이 없는 배열은 여전히
    통과한다
"""
import importlib.util
import io
import json
import os
import re
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
            "tool_input": {"script": "items.forEach(x => agent(x));", "name": "big-job"},
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
            "tool_input": {"name": "big-job", "script": "items.forEach(x => agent(x));"},
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
            "tool_input": {"name": "big-job", "script": "items.forEach(x => agent(x));"},
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
            "tool_input": {"name": "big-job", "script": "items.forEach(x => agent(x));"},
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
            "tool_input": {"name": "big-job", "script": "items.forEach(x => agent(x));"},
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
            "tool_input": {"name": "big-job", "script": "items.forEach(x => agent(x));"},
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
            "tool_input": {"name": "big-job", "script": "items.forEach(x => agent(x));"},
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
            "tool_input": {"script": "items.forEach(x => agent(x));"},
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
            "tool_input": {"name": "big-job", "script": "items.forEach(x => agent(x));"},
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
                "tool_input": {"name": "big-job", "script": "items.forEach(x => agent(x));"},
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
                    "tool_input": {"name": "big-job", "script": "items.forEach(x => agent(x));"},
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
                "tool_input": {"name": "big-job", "script": "items.forEach(x => agent(x));"},
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
            "tool_input": {"name": "big-job", "script": "items.forEach(x => agent(x));"},
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
            "tool_input": {"name": "big-job", "script": "items.forEach(x => agent(x));"},
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

        # --handoff 가 줄 끝이라고 가정하지 않는다 — 2) 에는 뒤에 --waker 가 더 붙는다.
        # 따옴표로 묶인 경로만 뽑아야 인자 순서가 바뀌어도 이 불변식만 잰다.
        def handoff_of(line):
            m = re.search(r'--handoff ("[^"]*"|\S+)', line)
            assert m, f"--handoff 인자를 못 찾음: {line}"
            return m.group(1).strip('"')

        handoff2 = handoff_of(step2)
        handoff4 = handoff_of(done_line)
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
            # 슬리퍼가 프로브 없이 바로 끝나게 아무것도 안 하는 스텁을 물린다.
            # /bin/true 를 박아두면 맥에서 깨진다 — 맥은 /usr/bin/true 만 있고
            # resolve_claude_bin 이 "실행 불가" 로 즉시 실패한다(맥 실측).
            claude_stub = Path(td) / "claude-stub"
            claude_stub.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            claude_stub.chmod(0o755)
            env["FREEZE_CLAUDE_BIN"] = str(claude_stub)

            # --at auto 추정 입력을 테스트가 소유한다. 이걸 안 주면 freeze.sh 가
            # 실제 $HOME/.claude/hud/cache 를 읽어, 그 머신이 방금 Claude Code 를
            # 썼는지에 따라 통과 여부가 갈린다 — 리눅스에서는 신선한 캐시 덕에
            # 우연히 통과하고 맥에서는 3시간 묵은 캐시라 실패했다(실측).
            hud_cache = Path(td) / "hud-cache"
            hud_cache.mkdir(parents=True, exist_ok=True)
            (hud_cache / "stdin.test.json").write_text(
                json.dumps({"rate_limits": {"five_hour": {"resets_at": int(time.time()) + 3 * 3600}}}),
                encoding="utf-8",
            )
            env["FREEZE_HUD_CACHE"] = str(hud_cache)

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


class TestScaleGate(unittest.TestCase):
    """S3: 서브에이전트 규모 게이트.

    작은 워크플로우(추정 서브에이전트 수가 임계값 이하)는 예약 여부와 무관하게 통과하고
    세션 마커도 남기지 않는다. 규모가 크거나(임계값 초과) 팬아웃이 있어 정적으로 셀 수
    없으면 기존 예약/세션 마커 로직을 그대로 탄다.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.state_root = Path(self._tmp.name)
        self._env_patch = patch.dict(
            os.environ,
            {"FREEZE_STATE_DIR": str(self.state_root)},
            clear=False,
        )
        self._env_patch.start()
        os.environ.pop("DISABLE_OMC", None)
        os.environ.pop("FREEZE_HOOK_OFF", None)
        os.environ.pop("FREEZE_HOOK_AGENT_THRESHOLD", None)

    def tearDown(self):
        self._env_patch.stop()
        self._tmp.cleanup()

    def test_small_workflow_passes_without_session_marker(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": "agent(1); agent(2); agent(3);"},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")
        marker = self.state_root / "workflow-arm-sessions" / "s1"
        self.assertFalse(marker.exists(), "작은 워크플로우는 세션 마커를 남기면 안 된다")

    def test_over_threshold_agent_count_denies(self):
        script = "\n".join(f"agent({i});" for i in range(12))
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": script},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        data = json.loads(stdout.strip())
        reason = data["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("12개로 추정된다", reason)

    def test_fanout_with_few_agent_calls_still_denies(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": "items.map(x => agent(x)); agent(0);"},
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        reason = data["hookSpecificOutput"]["permissionDecisionReason"]
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("정적으로 셀 수 없다", reason)

    # ── parallel/pipeline은 표준 API라 팬아웃 대상을 셀 수 있으면 그 크기로만 추정한다 ──
    def test_countable_named_array_fanout_passes_when_small(self):
        script = (
            "const DIMENSIONS = [{axis: 'a'}, {axis: 'b'}];\n"
            "pipeline(DIMENSIONS, d => agent(d));\n"
        )
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": script},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(
            stdout.strip(), "", "정적으로 셀 수 있는 배열 위의 pipeline은 작으면 통과해야 한다"
        )

    def test_countable_named_array_fanout_denies_when_large(self):
        items = ", ".join(f"{{axis: '{i}'}}" for i in range(12))
        script = f"const DIMENSIONS = [{items}];\npipeline(DIMENSIONS, d => agent(d));\n"
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": script},
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn("12개로 추정된다", data["hookSpecificOutput"]["permissionDecisionReason"])

    def test_property_access_receiver_denies_as_uncountable(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": "parallel(review.findings.map(f => agent(f)));"},
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "정적으로 셀 수 없다", data["hookSpecificOutput"]["permissionDecisionReason"]
        )

    def test_inline_array_literal_fanout_is_counted(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": "parallel([1, 2, 3].map(x => agent(x)));"},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(
            stdout.strip(), "", "인라인 배열 리터럴 위의 팬아웃은 그 크기로 셀 수 있어야 한다"
        )

    def test_nested_array_element_count_is_depth_aware(self):
        script = "const PAIRS = [[1, 2], [3, 4]];\npipeline(PAIRS, p => agent(p));\n"
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": script},
        }
        stdout, stderr, code = _run(payload)
        # PAIRS는 원소 2개(agent 1개 × 2 = 2, 임계값 10 이하) → 통과
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")

    def test_object_array_element_count_is_depth_aware(self):
        script = "const ONE = [{a: 1, b: 2}];\npipeline(ONE, o => agent(o));\n"
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": script},
        }
        stdout, stderr, code = _run(payload)
        # ONE은 원소 1개(콤마가 객체 내부에 있어도 최상위 원소는 하나) → 통과
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")

    def test_comma_inside_string_does_not_inflate_element_count(self):
        script = 'const LABELS = ["a,b", "c"];\npipeline(LABELS, l => agent(l));\n'
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": script},
        }
        stdout, stderr, code = _run(payload)
        # 문자열 안 콤마를 원소 구분자로 잘못 세면 3개(임계값 이하라 어차피 통과하긴
        # 하지만) — 정확히 2개로 세는지는 임계값을 1로 낮춰 확인한다.
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")
        with patch.dict(os.environ, {"FREEZE_HOOK_AGENT_THRESHOLD": "1"}):
            payload2 = dict(payload, session_id="s2")
            stdout2, _, code2 = _run(payload2)
            data2 = json.loads(stdout2.strip())
            self.assertEqual(data2["hookSpecificOutput"]["permissionDecision"], "deny")
            self.assertIn(
                "2개로 추정된다", data2["hookSpecificOutput"]["permissionDecisionReason"]
            )

    def test_for_loop_denies_as_uncountable(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": "for (const x of items) { agent(x); }"},
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "정적으로 셀 수 없다", data["hookSpecificOutput"]["permissionDecisionReason"]
        )

    def test_each_fanout_signal_is_detected(self):
        signals = [
            "items.map(x => agent(x))",
            "parallel(() => agent(1))",
            "pipeline(() => agent(1))",
            "for (const x of items) { agent(x); }",
            "items.forEach(x => agent(x))",
        ]
        for i, script in enumerate(signals):
            with self.subTest(script=script):
                payload = {
                    "session_id": f"sig{i}",
                    "cwd": "/repo",
                    "tool_name": "Workflow",
                    "tool_input": {"script": script},
                }
                stdout, _, code = _run(payload)
                data = json.loads(stdout.strip())
                self.assertEqual(
                    data["hookSpecificOutput"]["permissionDecision"], "deny"
                )

    def test_script_path_file_is_read_and_judged(self):
        with tempfile.TemporaryDirectory() as td:
            script_path = Path(td) / "wf.js"
            script_path.write_text(
                "\n".join(f"agent({i});" for i in range(12)), encoding="utf-8"
            )
            payload = {
                "session_id": "s1",
                "cwd": "/repo",
                "tool_name": "Workflow",
                "tool_input": {"scriptPath": str(script_path)},
            }
            stdout, _, code = _run(payload)
            data = json.loads(stdout.strip())
            self.assertEqual(
                data["hookSpecificOutput"]["permissionDecision"], "deny"
            )

    def test_missing_script_path_passes(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"scriptPath": "/no/such/file-xyz.js"},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "")

    def test_threshold_env_override_changes_verdict(self):
        with patch.dict(os.environ, {"FREEZE_HOOK_AGENT_THRESHOLD": "2"}):
            payload = {
                "session_id": "s1",
                "cwd": "/repo",
                "tool_name": "Workflow",
                "tool_input": {"script": "agent(1); agent(2); agent(3);"},
            }
            stdout, _, code = _run(payload)
            data = json.loads(stdout.strip())
            reason = data["hookSpecificOutput"]["permissionDecisionReason"]
            self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
            self.assertIn("임계값 2", reason)

    # ── Codex 리뷰 BLOCKER: 중첩 팬아웃은 곱해야 한다(max로 접으면 과소평가) ──────
    def test_nested_fanout_multiplies_instead_of_max(self):
        outer = "[" + ",".join(f"{{n:{i}}}" for i in range(10)) + "]"
        inner = "[" + ",".join(f"{{n:{i}}}" for i in range(10)) + "]"
        script = (
            f"const OUTER = {outer};\n"
            f"const INNER = {inner};\n"
            "pipeline(OUTER, o => {\n"
            "  pipeline(INNER, i => agent(i));\n"
            "});\n"
        )
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": script},
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "100개로 추정된다",
            data["hookSpecificOutput"]["permissionDecisionReason"],
            "10×10 중첩 팬아웃을 max()로 접으면 10이 되어 큰 워크플로우를 통과시킨다 — "
            "곱해서 100이어야 한다",
        )

    def test_passthrough_call_uses_inner_size_not_multiplied(self):
        # parallel(X.map(...))는 X 크기 그대로여야 한다(곱하면 3이 아니라 9가 됨).
        small = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {
                "script": "const X = [1, 2, 3]; parallel(X.map(v => agent(v)));"
            },
        }
        stdout, stderr, code = _run(small)
        self.assertEqual(code, 0)
        self.assertEqual(
            stdout.strip(), "", "pass-through는 X 크기(3)만 반영해야 하므로 통과해야 한다"
        )

        twelve = "[" + ",".join(str(i) for i in range(12)) + "]"
        large = {
            "session_id": "s2",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {
                "script": f"const X = {twelve}; parallel(X.map(v => agent(v)));"
            },
        }
        stdout2, _, _ = _run(large)
        data2 = json.loads(stdout2.strip())
        self.assertEqual(data2["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "12개로 추정된다",
            data2["hookSpecificOutput"]["permissionDecisionReason"],
            "pass-through가 곱해지면 12가 아니라 144가 나와야 정상인데, 곱하지 않아야 "
            "하므로 X 크기 그대로 12여야 한다",
        )

    # ── Codex 리뷰 BLOCKER: spread는 배열 크기를 셀 수 없는 것으로 다뤄야 한다 ──
    def test_spread_array_literal_is_uncountable(self):
        for script in (
            "const BIG = [...Array(100)]; pipeline(BIG, x => agent(x));",
            "const BIG = [...items]; pipeline(BIG, x => agent(x));",
        ):
            with self.subTest(script=script):
                payload = {
                    "session_id": f"s-{hash(script)}",
                    "cwd": "/repo",
                    "tool_name": "Workflow",
                    "tool_input": {"script": script},
                }
                stdout, _, code = _run(payload)
                data = json.loads(stdout.strip())
                self.assertEqual(
                    data["hookSpecificOutput"]["permissionDecision"], "deny"
                )
                self.assertIn(
                    "정적으로 셀 수 없다",
                    data["hookSpecificOutput"]["permissionDecisionReason"],
                )

    # ── Codex 리뷰 MINOR: 주석·문자열 속 패턴에 낚이면 안 된다 ────────────────
    def test_loop_inside_comment_does_not_trigger_deny(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {
                "script": "// for (const x of huge) { agent(x); }\nagent(1); agent(2);"
            },
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(
            stdout.strip(), "", "주석 안의 for (는 실제 팬아웃이 아니므로 막으면 안 된다"
        )

    def test_map_inside_string_literal_does_not_trigger_deny(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {
                "script": (
                    'const doc = "call items.map(x => agent(x)) here";\n'
                    "agent(1); agent(2);"
                )
            },
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(
            stdout.strip(),
            "",
            "문자열 리터럴 안의 .map(는 실제 팬아웃이 아니므로 막으면 안 된다",
        )

    # ── BLOCKER D: 정규식 리터럴을 모르면 스트리퍼가 파일 나머지를 통째로 지운다 ──
    def test_regex_with_quote_class_before_fanout_still_denies(self):
        items = "[" + ",".join(str(i) for i in range(20)) + "]"
        script = (
            "const isQuoted = (s) => /['\"]/.test(s);\n"
            f"const ITEMS = {items};\n"
            "parallel(ITEMS.map(x => agent(x)));\n"
        )
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": script},
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "20개로 추정된다",
            data["hookSpecificOutput"]["permissionDecisionReason"],
            "정규식 안의 따옴표를 문자열 여는 따옴표로 오인하면 뒤의 팬아웃이 통째로 "
            "지워져 0개로 통과해버린다",
        )

    def test_regex_with_apostrophe_before_fanout_still_denies(self):
        items = "[" + ",".join(str(i) for i in range(20)) + "]"
        script = (
            "const re = /don't/;\n"
            f"const ITEMS = {items};\n"
            "parallel(ITEMS.map(x => agent(x)));\n"
        )
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": script},
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "20개로 추정된다", data["hookSpecificOutput"]["permissionDecisionReason"]
        )

    def test_regex_containing_double_slash_same_line_as_fanout_still_denies(self):
        items = "[" + ",".join(str(i) for i in range(20)) + "]"
        script = (
            r"const parts = url.split(/\/\//); "
            f"const ITEMS = {items}; "
            "parallel(ITEMS.map(x => agent(x)));\n"
        )
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": script},
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "20개로 추정된다",
            data["hookSpecificOutput"]["permissionDecisionReason"],
            "정규식 안의 // 를 줄 주석으로 오인하면 같은 줄에 이어지는 팬아웃까지 "
            "함께 지워진다",
        )

    def test_unbalanced_bracket_regex_does_not_break_paren_depth(self):
        items = "[" + ",".join(str(i) for i in range(20)) + "]"
        script = (
            "const re = /[({]/;\n"
            f"const ITEMS = {items};\n"
            "parallel(ITEMS.map(x => agent(x)));\n"
        )
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": script},
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "20개로 추정된다", data["hookSpecificOutput"]["permissionDecisionReason"]
        )

    def test_division_is_not_mistaken_for_regex(self):
        script = "const rate = total / count;\nagent(1); agent(2);"
        clean = _mod._strip_comments_and_strings(script)
        self.assertIn(
            "total / count", clean, "나눗셈 / 는 정규식으로 오인해 지우면 안 된다"
        )
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": script},
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(
            stdout.strip(), "", "나눗셈만 있는 작은 스크립트는 통과해야 한다"
        )

    def test_agent_call_inside_regex_literal_is_not_counted(self):
        script = r"const re = /agent\(agent\(agent\(/;" + "\nagent(1); agent(2);"
        clean = _mod._strip_comments_and_strings(script)
        self.assertEqual(
            len(_mod._AGENT_CALL_RE.findall(clean)),
            2,
            "정규식 리터럴 안의 agent( 문자열은 실제 호출로 세면 안 된다",
        )

    # ── MAJOR E: 팬아웃 마커 다섯 개 밖(Array.from/reduce/Promise.all/point-free) ──
    def test_array_from_and_promise_all_denies_as_uncountable(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {
                "script": (
                    "const results = await Promise.all(\n"
                    "  Array.from({length: 50}, (_, i) => agent({prompt: i}))\n"
                    ");\n"
                )
            },
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "정적으로 셀 수 없다",
            data["hookSpecificOutput"]["permissionDecisionReason"],
            "Array.from/Promise.all 은 이 파일이 아는 팬아웃 마커 다섯 개 밖이라 "
            "실제 50개짜리가 배수 1·통과로 새어나가면 안 된다",
        )

    def test_point_free_agent_reference_denies_as_uncountable(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {"script": "parallel(specs.map(agent));"},
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "정적으로 셀 수 없다",
            data["hookSpecificOutput"]["permissionDecisionReason"],
            "point-free(agent 를 함수 참조로만 넘김)라 agent( 호출 형태가 안 걸려 "
            "0개로 통과하면 안 된다",
        )

    def test_reduce_accumulator_denies_as_uncountable(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {
                "script": (
                    "items.reduce(async (acc, x) => "
                    "[...(await acc), await agent(x)], []);"
                )
            },
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "정적으로 셀 수 없다",
            data["hookSpecificOutput"]["permissionDecisionReason"],
            ".reduce( 누산기 형태는 이 파일이 아는 팬아웃 마커가 아니므로 반복 "
            "횟수를 못 세면 무조건 막아야 한다",
        )

    # ── MAJOR F: 배열 크기를 선언 시점 값으로만 믿으면 안 된다 ──────────────────
    def test_reassigned_named_array_denies_as_uncountable(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {
                "script": (
                    "let tasks = [1, 2];\n"
                    "tasks = await buildHundredTasks();\n"
                    "parallel(tasks.map(x => agent(x)));\n"
                )
            },
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "정적으로 셀 수 없다",
            data["hookSpecificOutput"]["permissionDecisionReason"],
            "선언 뒤 재대입된 배열은 선언 시점 크기(2)를 더 이상 못 믿는다",
        )

    def test_mutated_named_array_denies_as_uncountable(self):
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {
                "script": (
                    "const tasks = [1, 2];\n"
                    "tasks.push(3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16);\n"
                    "parallel(tasks.map(x => agent(x)));\n"
                )
            },
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "정적으로 셀 수 없다",
            data["hookSpecificOutput"]["permissionDecisionReason"],
            "push 로 늘어난 배열은 선언 시점 크기(2)를 더 이상 못 믿는다",
        )

    def test_shadowed_named_array_in_other_scope_denies_as_uncountable(self):
        items = "[" + ",".join(str(i) for i in range(20)) + "]"
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {
                "script": (
                    f"const tasks = {items};\n"
                    "parallel(tasks.map(x => agent(x)));\n"
                    "function other() { const tasks = [1, 2]; }\n"
                )
            },
        }
        stdout, stderr, code = _run(payload)
        data = json.loads(stdout.strip())
        self.assertEqual(data["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertIn(
            "정적으로 셀 수 없다",
            data["hookSpecificOutput"]["permissionDecisionReason"],
            "이 스캐너는 스코프를 구분하지 않으므로, 다른 함수 안의 동명 지역 "
            "변수 때문에 진짜 20개짜리를 2개로 잘못 셀 수 있다 — 이름이 두 번 "
            "이상 선언되면 아예 못 믿는 쪽으로 떨어져야 한다",
        )

    def test_named_array_without_mutation_still_passes(self):
        # 과잉 차단 확인: 재선언·재대입·변형이 전혀 없는 평범한 소형 워크플로우는
        # 여전히 통과해야 한다.
        payload = {
            "session_id": "s1",
            "cwd": "/repo",
            "tool_name": "Workflow",
            "tool_input": {
                "script": "const D = [1, 2, 3];\npipeline(D, d => agent(d));\n"
            },
        }
        stdout, stderr, code = _run(payload)
        self.assertEqual(code, 0)
        self.assertEqual(
            stdout.strip(),
            "",
            "재선언·재대입·변형이 없는 배열 위의 소형 팬아웃은 통과해야 한다",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
