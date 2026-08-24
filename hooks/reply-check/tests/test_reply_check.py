#!/usr/bin/env python3
"""reply-check.py 유닛 테스트.

케이스:
1. 번역투 문장 3개 든 답변 → block, reason에 해당 문장 포함
2. 평이한 답변 → 출력 없음
3. stop_hook_active: true → 출력 없음
4. 코드블록만 있는 답변 → 스킵 (출력 없음)
5. 깨진 JSON stdin → exit 0, stderr 한 줄
"""
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

# ── reply-check.py 를 모듈로 로드 ──────────────────────────────────────────
# 저장소 기준: 이 파일은 tests/ 아래, reply-check.py는 한 단계 위
_HOOK = Path(__file__).resolve().parent.parent / "reply-check.py"

# 심링크 경유로 실행하는 경우에도 저장소 실체 경로를 먼저 시도한다.
# 저장소 경로가 없으면 기존 ~/.claude/hooks/ 경로로 폴백
if not _HOOK.exists():
    _HOOK = Path.home() / ".claude/hooks/reply-check.py"

spec = importlib.util.spec_from_file_location("reply_check", str(_HOOK))
assert spec and spec.loader, f"reply-check.py not found at {_HOOK}"
_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(_mod)  # type: ignore[union-attr]

# 공개 helper 가져오기
_clean = _mod._clean
_korean_ratio = _mod._korean_ratio
_split_sentences = _mod._split_sentences
_check_axis1 = _mod._check_axis1
_check_axis2 = _mod._check_axis2
_check_axis3 = _mod._check_axis3
_load_last_assistant = _mod._load_last_assistant


# ── 공통 유틸 ──────────────────────────────────────────────────────────────

def _make_transcript(text: str) -> str:
    """assistant 메시지 하나를 담은 JSONL 임시 파일 경로를 반환한다."""
    record = {
        "type": "assistant",
        "message": {
            "content": [{"type": "text", "text": text}]
        },
        "session_id": "test-session",
    }
    fd, path = tempfile.mkstemp(suffix=".jsonl")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    return path


def _run(transcript_path: str, stop_hook_active: bool = False) -> tuple[str, str, int]:
    """reply-check main을 stdin/stdout/stderr를 캡처해 실행한다.
    Returns (stdout_text, stderr_text, exit_code).
    """
    payload = json.dumps({
        "session_id": "test-session",
        "transcript_path": transcript_path,
        "stop_hook_active": stop_hook_active,
        "hook_event_name": "Stop",
    })

    # 로그 파일을 임시 파일로 교체해 실제 로그 오염을 막는다
    fd, tmp_log = tempfile.mkstemp(suffix=".jsonl")
    os.close(fd)

    stdout_buf = io.StringIO()
    stderr_buf = io.StringIO()

    exit_code = 0
    try:
        with (
            patch("sys.stdin", io.StringIO(payload)),
            patch("sys.stdout", stdout_buf),
            patch("sys.stderr", stderr_buf),
            patch.object(_mod, "_LOG_PATH", Path(tmp_log)),
        ):
            try:
                _mod.main()
            except SystemExit as e:
                exit_code = int(e.code or 0)
    finally:
        os.unlink(tmp_log)

    return stdout_buf.getvalue(), stderr_buf.getvalue(), exit_code


# ── 테스트 케이스 ──────────────────────────────────────────────────────────

class TestReplyCheck(unittest.TestCase):

    # ── 케이스 1: 번역투 문장 3개 든 답변 → block ──────────────────────────
    def test_translationese_block(self):
        """번역투+긴 문장이 있는 한국어 답변은 block 결정을 낸다."""
        # 이에 따라, 결론적으로 같은 시드 패턴 포함, 긴 문장, 반복
        bad_text = (
            "이에 따라 우리는 결론을 내려야 한다. "
            "결론적으로 이 접근 방식이 가장 좋은 방법이라는 점을 확인했으며 앞으로도 지속적으로 적용해야 할 것이다. "
            "결론적으로 이 방식은 모든 팀에 적합하다고 볼 수 있는 것이며 반드시 도입해야 한다. "
            "요약하면 이 방법은 효율적이고 실용적이며 지속 가능한 접근법으로 평가된다. "
            "이에 따라 모든 구성원이 이 방침을 따라야 하며 예외는 없다는 것이다. "
            "이 접근법의 효과성이라는 것이 팀 생산성을 좌우했다는 점은 명확하다. "
            "이 접근법의 효과성이라는 것이 팀 생산성을 좌우했다는 점은 명확하다. "
        )
        path = _make_transcript(bad_text)
        try:
            stdout, stderr, code = _run(path)
        finally:
            os.unlink(path)

        self.assertEqual(code, 0, "exit code는 항상 0이어야 한다")
        self.assertTrue(stdout.strip(), "block 시 stdout이 있어야 한다")
        data = json.loads(stdout.strip())
        self.assertEqual(data.get("decision"), "block", f"decision=block 아님: {data}")
        # reason에 문제 패턴이 포함돼야 한다
        reason = data.get("reason", "")
        self.assertIn("reply-check", reason, "reason에 reply-check 포함")

    # ── 케이스 2: 평이한 답변 → 출력 없음 ──────────────────────────────────
    def test_plain_answer_pass(self):
        """짧고 구체적인 한국어 답변은 통과한다."""
        # 200자 이상, 한글 30% 이상, 문제 패턴 없음
        good_text = (
            "파일을 저장하려면 Ctrl+S를 누르면 된다. "
            "설정 메뉴는 오른쪽 위 톱니바퀴 아이콘에 있다. "
            "검색창에 원하는 키워드를 입력하면 결과가 나온다. "
            "목록에서 항목을 클릭하면 상세 페이지로 이동한다. "
            "변경 사항은 자동으로 저장된다. "
            "문제가 생기면 로그 파일을 확인해라. "
            "설치는 터미널에서 npm install 명령어로 한다. "
            "버전 확인은 node --version 으로 한다. "
            "디렉터리 구조는 src 폴더 아래에 있다. "
            "테스트를 돌리려면 npm test를 입력해라. "
        )
        path = _make_transcript(good_text)
        try:
            stdout, stderr, code = _run(path)
        finally:
            os.unlink(path)

        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "", f"통과 시 stdout 없어야 함: {stdout!r}")

    # ── 케이스 3: stop_hook_active: true → 출력 없음 ───────────────────────
    def test_stop_hook_active_skip(self):
        """stop_hook_active가 true면 다시 막지 않는다."""
        bad_text = (
            "결론적으로 이 접근 방식이 최선이다. " * 5
            + "이 방식의 효율성이 팀의 생산성을 좌우했다." * 3
        )
        path = _make_transcript(bad_text)
        try:
            stdout, stderr, code = _run(path, stop_hook_active=True)
        finally:
            os.unlink(path)

        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "", "stop_hook_active=True면 아무 출력 없어야 함")

    # ── 케이스 4: 코드블록만 있는 답변 → 스킵 ──────────────────────────────
    def test_code_only_skip(self):
        """코드블록만 있어 한글 120자 미만이면 스킵한다."""
        code_only = (
            "```python\n"
            "def hello():\n"
            "    print('Hello, world!')\n"
            "\n"
            "hello()\n"
            "```\n"
        )
        path = _make_transcript(code_only)
        try:
            stdout, stderr, code = _run(path)
        finally:
            os.unlink(path)

        self.assertEqual(code, 0)
        self.assertEqual(stdout.strip(), "", "코드블록만 있으면 스킵 (출력 없음)")

    # ── 케이스 5: 깨진 JSON stdin → exit 0, stderr 한 줄 ───────────────────
    def test_broken_stdin(self):
        """JSON이 깨진 stdin은 exit 0으로 안전하게 처리한다."""
        stdout_buf = io.StringIO()
        stderr_buf = io.StringIO()
        exit_code = 0

        with (
            patch("sys.stdin", io.StringIO("{ broken json :::")),
            patch("sys.stdout", stdout_buf),
            patch("sys.stderr", stderr_buf),
        ):
            try:
                _mod.main()
            except SystemExit as e:
                exit_code = int(e.code or 0)

        self.assertEqual(exit_code, 0, "깨진 JSON도 exit 0이어야 한다")
        self.assertEqual(stdout_buf.getvalue().strip(), "", "stdout 없어야 함")
        # stderr에 에러 메시지가 찍혀야 한다
        self.assertGreater(
            len(stderr_buf.getvalue().strip()), 0,
            "stderr에 오류 한 줄이 있어야 한다"
        )

    # ── 내부 helper 검증 ────────────────────────────────────────────────────
    def test_clean_removes_code_fence(self):
        text = "설명\n```python\ncode\n```\n나머지"
        cleaned = _clean(text)
        self.assertNotIn("```", cleaned)
        self.assertIn("설명", cleaned)

    def test_korean_ratio(self):
        self.assertGreater(_korean_ratio("안녕하세요 반갑습니다"), 0.7)
        self.assertLess(_korean_ratio("hello world this is english"), 0.1)

    def test_split_sentences_basic(self):
        sents = _split_sentences("첫째 문장이다. 둘째 문장이다.")
        self.assertEqual(len(sents), 2)

    def test_axis3_long_sentences(self):
        # 60자 넘는 문장이 많으면 fail
        long_s = "가" * 65 + "."
        avg, pct, examples = _check_axis3(long_s + " " + long_s)
        self.assertGreater(pct, 0.0)




class TestCausativeInanimate(unittest.TestCase):
    """무생물 주어 사동(~하게 만들다)과 은/는 주어 확장 회귀."""

    def test_causative_and_topic_subject(self):
        hits = _mod._RE_INANI.findall("가격은 검토를 시작하게 만들 뿐입니다.")
        self.assertTrue(hits)

    def test_human_subject_not_flagged(self):
        self.assertFalse(_mod._RE_INANI.findall("저는 아침에 커피를 마셨다."))
        self.assertFalse(_mod._RE_INANI.findall("사용자가 버튼을 눌렀다."))


if __name__ == "__main__":
    unittest.main(verbosity=2)

