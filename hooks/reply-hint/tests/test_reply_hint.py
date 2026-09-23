#!/usr/bin/env python3
"""reply-hint.py 유닛 테스트.

케이스:
1. 신선한(6시간 이내) pending 파일 → additionalContext 출력, 파일 삭제
2. 오래된(6시간 초과) pending 파일 → 출력 없음, 파일은 삭제
3. pending 파일 없음 → 출력 없음
4. 깨진 JSON stdin → exit 0, 출력 없음
5. 깨진 pending 파일 내용 → exit 0, 파일 삭제, 출력 없음
6. 24시간 넘은 다른 세션 파일 → sweep으로 삭제
7. 사유가 800자 넘으면 잘림
"""
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

_HOOK = Path(__file__).resolve().parent.parent / "reply-hint.py"
if not _HOOK.exists():
    _HOOK = Path.home() / ".claude/hooks/reply-hint.py"

spec = importlib.util.spec_from_file_location("reply_hint", str(_HOOK))
assert spec and spec.loader, f"reply-hint.py not found at {_HOOK}"
_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(_mod)  # type: ignore[union-attr]


def _run(payload: dict, config_dir: str) -> tuple[str, str, int]:
    stdout_buf = io.StringIO()
    stderr_buf = io.StringIO()
    exit_code = 0
    with (
        patch("sys.stdin", io.StringIO(json.dumps(payload))),
        patch("sys.stdout", stdout_buf),
        patch("sys.stderr", stderr_buf),
        patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": config_dir}),
    ):
        try:
            _mod.main()
        except SystemExit as e:
            exit_code = int(e.code or 0)
    return stdout_buf.getvalue(), stderr_buf.getvalue(), exit_code


def _pending_path(config_dir: str, session_id: str) -> Path:
    safe = _mod._sanitize_session_id(session_id)
    return Path(config_dir) / "hooks/state/reply-check" / f"{safe}.json"


def _write_pending(config_dir: str, session_id: str, reason: str, ts: float | None = None) -> Path:
    path = _pending_path(config_dir, session_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    rec = {"ts": ts if ts is not None else time.time(), "reason": reason, "chars": len(reason)}
    path.write_text(json.dumps(rec, ensure_ascii=False), encoding="utf-8")
    return path


class TestReplyHint(unittest.TestCase):
    def test_fresh_pending_emits_context_and_deletes(self):
        with tempfile.TemporaryDirectory() as cfg:
            _write_pending(cfg, "sess-1", "결론적으로 반복 구절이 있다")
            stdout, stderr, code = _run({"session_id": "sess-1"}, cfg)
            self.assertEqual(code, 0)
            data = json.loads(stdout.strip())
            hso = data["hookSpecificOutput"]
            self.assertEqual(hso["hookEventName"], "UserPromptSubmit")
            self.assertIn("결론적으로 반복 구절이 있다", hso["additionalContext"])
            self.assertIn("직전 답변이 말투 검사에 걸렸다", hso["additionalContext"])
            self.assertFalse(_pending_path(cfg, "sess-1").exists(), "읽은 뒤 삭제돼야 함")

    def test_stale_pending_no_output_but_deleted(self):
        with tempfile.TemporaryDirectory() as cfg:
            old_ts = time.time() - (7 * 60 * 60)  # 7시간 전
            _write_pending(cfg, "sess-2", "오래된 사유", ts=old_ts)
            stdout, stderr, code = _run({"session_id": "sess-2"}, cfg)
            self.assertEqual(code, 0)
            self.assertEqual(stdout.strip(), "", "6시간 넘은 pending은 출력하지 않아야 함")
            self.assertFalse(_pending_path(cfg, "sess-2").exists(), "읽었으면 삭제돼야 함")

    def test_missing_pending_no_output(self):
        with tempfile.TemporaryDirectory() as cfg:
            stdout, stderr, code = _run({"session_id": "sess-none"}, cfg)
            self.assertEqual(code, 0)
            self.assertEqual(stdout.strip(), "")

    def test_broken_stdin_exit_zero(self):
        stdout_buf = io.StringIO()
        stderr_buf = io.StringIO()
        exit_code = 0
        with (
            patch("sys.stdin", io.StringIO("{ broken :::")),
            patch("sys.stdout", stdout_buf),
            patch("sys.stderr", stderr_buf),
        ):
            try:
                _mod.main()
            except SystemExit as e:
                exit_code = int(e.code or 0)
        self.assertEqual(exit_code, 0)
        self.assertEqual(stdout_buf.getvalue().strip(), "")

    def test_garbage_pending_file_removed_no_crash(self):
        with tempfile.TemporaryDirectory() as cfg:
            path = _pending_path(cfg, "sess-3")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("not json at all", encoding="utf-8")
            stdout, stderr, code = _run({"session_id": "sess-3"}, cfg)
            self.assertEqual(code, 0)
            self.assertEqual(stdout.strip(), "")
            self.assertFalse(path.exists())

    def test_sweep_removes_old_files_in_dir(self):
        with tempfile.TemporaryDirectory() as cfg:
            # 다른 세션의 아주 오래된 pending (25시간 전)
            old_path = _write_pending(
                cfg, "sess-old", "옛날 사유", ts=time.time() - (25 * 60 * 60)
            )
            old_path.touch()
            os.utime(old_path, (time.time() - 25 * 3600, time.time() - 25 * 3600))
            # 이번 세션(sess-4)은 pending 없음
            stdout, stderr, code = _run({"session_id": "sess-4"}, cfg)
            self.assertEqual(code, 0)
            self.assertFalse(old_path.exists(), "24시간 넘은 파일은 sweep으로 지워져야 함")

    def test_reason_truncated_at_800_chars(self):
        with tempfile.TemporaryDirectory() as cfg:
            long_reason = "가" * 1000
            _write_pending(cfg, "sess-5", long_reason)
            stdout, stderr, code = _run({"session_id": "sess-5"}, cfg)
            data = json.loads(stdout.strip())
            ctx = data["hookSpecificOutput"]["additionalContext"]
            # 앞머리 안내문을 뺀 사유 부분만 길이를 확인
            reason_part = ctx.split("\n", 1)[1]
            self.assertLessEqual(len(reason_part), 802)  # truncate + " …"
            self.assertTrue(reason_part.endswith("…"))

    def test_empty_session_id_no_output(self):
        with tempfile.TemporaryDirectory() as cfg:
            stdout, stderr, code = _run({"session_id": ""}, cfg)
            self.assertEqual(code, 0)
            self.assertEqual(stdout.strip(), "")

    def test_sanitize_matches_reply_check(self):
        """reply-hint의 sanitize가 reply-check의 것과 동일해야 같은 파일을 가리킨다."""
        reply_check_path = (
            Path(__file__).resolve().parent.parent.parent / "reply-check" / "reply-check.py"
        )
        spec2 = importlib.util.spec_from_file_location("_reply_check_ref", reply_check_path)
        assert spec2 and spec2.loader
        rc_mod = importlib.util.module_from_spec(spec2)
        spec2.loader.exec_module(rc_mod)  # type: ignore[union-attr]

        for raw in ["../../etc/passwd session", "abc-123_XYZ", "a b/c.d"]:
            self.assertEqual(
                _mod._sanitize_session_id(raw),
                rc_mod._sanitize_session_id(raw),
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
