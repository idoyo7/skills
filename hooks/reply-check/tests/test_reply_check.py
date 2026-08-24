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
_check_axis4 = _mod._check_axis4
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
        hits = _mod._RE_CAUSATIVE.findall("가격은 검토를 시작하게 만들 뿐입니다.")
        self.assertTrue(hits)

    def test_human_subject_not_flagged(self):
        self.assertFalse(_mod._RE_INANI.findall("저는 아침에 커피를 마셨다."))
        self.assertFalse(_mod._RE_CAUSATIVE.findall("저는 아침에 커피를 마셨다."))
        self.assertFalse(_mod._RE_INANI.findall("사용자가 버튼을 눌렀다."))


class TestAxis4Structural(unittest.TestCase):
    """axis4 구조 패턴 검사 (수사 의문, designed-to, 관형격 사슬, 강조부사)."""

    # 패딩: 120자 이상 한국어를 채우기 위한 중립 문장
    _PAD = (
        "파일은 직접 확인하면 된다. "
        "설정은 오른쪽 위에 있다. "
        "버전을 먼저 맞춰야 한다. "
        "로그를 확인해야 한다. "
        "디렉터리 구조를 살펴야 한다. "
        "터미널에서 실행해라. "
    )

    # ── 수사 의문 종결: block ─────────────────────────────────────────────
    def test_rhetorical_question_block(self):
        """'것인가.' 종결 수사 의문문이 포함된 산문은 block이고 reason에 문장이 있다."""
        text = self._PAD + "그걸 무슨 근거로 결정할 것인가. " + self._PAD
        path = _make_transcript(text)
        try:
            stdout, stderr, code = _run(path)
        finally:
            os.unlink(path)

        self.assertEqual(code, 0)
        self.assertTrue(stdout.strip(), "block 시 stdout이 있어야 한다")
        data = json.loads(stdout.strip())
        self.assertEqual(data.get("decision"), "block", f"decision=block 아님: {data}")
        self.assertIn("것인가", data.get("reason", ""), "reason에 수사 의문 문장 포함 필요")

    # ── designed-to 직역: block ───────────────────────────────────────────
    def test_designed_to_block(self):
        """'갖도록 구성' 패턴이 포함된 산문은 block이다."""
        text = self._PAD + "재현성을 갖도록 구성한 케이스 셋입니다. " + self._PAD
        path = _make_transcript(text)
        try:
            stdout, stderr, code = _run(path)
        finally:
            os.unlink(path)

        self.assertEqual(code, 0)
        self.assertTrue(stdout.strip(), "block 시 stdout이 있어야 한다")
        data = json.loads(stdout.strip())
        self.assertEqual(data.get("decision"), "block", f"decision=block 아님: {data}")
        self.assertIn("도록", data.get("reason", ""), "reason에 designed-to 패턴 포함 필요")

    # ── 사용자 실제 질문: 수사 의문으로 안 잡힘 ─────────────────────────
    def test_user_question_not_flagged_as_rhetorical(self):
        """'주세요'가 포함된 사용자 질문 문장은 수사 의문 히트가 없다."""
        text = "이 값이 맞을까요? 확인해 주세요."
        sents = _split_sentences(text)
        block_lines, report_lines, struct_hits = _check_axis4(text, sents)
        rhet_hits = [l for l in block_lines if "수사" in l]
        self.assertEqual(rhet_hits, [], f"수사 의문 히트 없어야 함: {rhet_hits}")

    # ── 관형격 사슬: block 아님, report에만 ──────────────────────────────
    def test_genitive_chain_report_only(self):
        """'의 ... 의' 관형격 사슬은 차단 사유가 아니라 report 항목에만 들어간다."""
        text = "시스템의 성능의 한계가 드러났다."
        sents = _split_sentences(text)
        block_lines, report_lines, struct_hits = _check_axis4(text, sents)
        self.assertEqual(block_lines, [], f"block_lines 없어야 함: {block_lines}")
        self.assertTrue(
            any("관형격" in r for r in report_lines),
            f"관형격 사슬이 report에 있어야 함: {report_lines}",
        )

    # ── 강조부사 밀도: block 아님, report에만 ────────────────────────────
    def test_emphasis_density_report_only(self):
        """강조부사 밀도 ≥ 3/1000자여도 block 사유가 아니라 report 항목이다."""
        # 짧은 텍스트에 실제로 3회 → 밀도 충분
        text = "실제로 이것이다. 실제로 저것이다. 실제로 그것이다. " * 2
        sents = _split_sentences(text)
        block_lines, report_lines, struct_hits = _check_axis4(text, sents)
        self.assertEqual(block_lines, [], f"block_lines 없어야 함: {block_lines}")
        self.assertTrue(
            any("강조부사" in r for r in report_lines),
            f"강조부사 밀도가 report에 있어야 함: {report_lines}",
        )


class TestAxis4Extended(unittest.TestCase):
    """axis4 확장 패턴 (it-cleft, 한계 프레임, 열거 예고, 단정 단문, 삼항 나열)."""

    # ── it-cleft 강조: block ─────────────────────────────────────────────
    def test_it_cleft_block(self):
        """'내린 건 비용이었습니다' 구문은 block 사유다."""
        text = "결국 마지막 결정을 내린 건 비용이었습니다."
        sents = _split_sentences(text)
        block_lines, report_lines, struct_hits = _mod._check_axis4(text, sents)
        cleft_hits = [l for l in block_lines if "cleft" in l or "it-cleft" in l]
        self.assertTrue(cleft_hits, f"it-cleft 히트가 block_lines에 있어야 함: {block_lines}")

    # ── it-cleft 오탐: 확인했습니다 → 잡히지 않음 ─────────────────────
    def test_it_cleft_false_positive(self):
        """'그것이 사실인지 확인했습니다'는 it-cleft에 걸리지 않는다."""
        text = "그것이 사실인지 확인했습니다."
        sents = _split_sentences(text)
        block_lines, report_lines, struct_hits = _mod._check_axis4(text, sents)
        cleft_hits = [l for l in block_lines if "cleft" in l or "it-cleft" in l]
        self.assertEqual(cleft_hits, [], f"오탐 없어야 함: {cleft_hits}")

    # ── 한계 프레임: block ────────────────────────────────────────────────
    def test_limit_frame_block(self):
        """'하나로는 결정이 안 됩니다' 패턴은 block 사유다."""
        text = "이 지표 하나로는 결정이 안 됩니다."
        sents = _split_sentences(text)
        block_lines, report_lines, struct_hits = _mod._check_axis4(text, sents)
        lf_hits = [l for l in block_lines if "한계" in l]
        self.assertTrue(lf_hits, f"한계 프레임 히트가 block_lines에 있어야 함: {block_lines}")

    # ── 열거 예고(숫자형): block ──────────────────────────────────────────
    def test_enum_num_block(self):
        """'5가지 지표' 같은 숫자형 열거 예고는 block 사유다."""
        text = "위 5가지 지표에서 이미 흔들렸던 모델입니다."
        sents = _split_sentences(text)
        block_lines, report_lines, struct_hits = _mod._check_axis4(text, sents)
        enum_hits = [l for l in block_lines if "열거" in l]
        self.assertTrue(enum_hits, f"열거 예고 히트가 block_lines에 있어야 함: {block_lines}")

    # ── 단정 단문: report에만 ─────────────────────────────────────────────
    def test_assertive_short_report_only(self):
        """14자 이하 단정 단문('아래쪽은 분명합니다.')은 report 항목에만 들어간다."""
        text = "아래쪽은 분명합니다."
        sents = _split_sentences(text)
        block_lines, report_lines, struct_hits = _mod._check_axis4(text, sents)
        self.assertEqual(block_lines, [], f"block_lines 없어야 함: {block_lines}")
        assertive_reports = [r for r in report_lines if "단정" in r]
        self.assertTrue(assertive_reports, f"단정 단문이 report에 있어야 함: {report_lines}")


if __name__ == "__main__":
    unittest.main(verbosity=2)

