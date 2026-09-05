#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""slop_scan.py 회귀 테스트 (게이트 S — 초안 관문).

unittest + subprocess. 구현을 임포트하지 않고 CLI 계약(스펙)만 근거로 검증한다.
`slop_scan.py` 가 아직 없으면 각 테스트 클래스는 명확한 스킵 메시지를 낸다.

실행:
    python3 tests/test_slop_scan.py
    (또는 run.sh 경유)
"""

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SKILL_DIR = TESTS_DIR.parent
CORPUS_DIR = TESTS_DIR / "slop_corpus"
EXPECTED_DIR = CORPUS_DIR / "expected"
SCRIPTS_DIR = SKILL_DIR / "scripts"
SCRIPT = SCRIPTS_DIR / "slop_scan.py"
LEXICON = SKILL_DIR / "references" / "slop-lexicon.txt"


def _script_missing_reason() -> str | None:
    if not SCRIPT.exists():
        return (
            f"slop_scan.py 가 아직 존재하지 않습니다: {SCRIPT}\n"
            "  구현 에이전트가 작업 중일 수 있습니다. 이 스킵은 정상입니다."
        )
    return None


def run_slop(args: list[str]) -> subprocess.CompletedProcess:
    cmd = [sys.executable, str(SCRIPT), *args]
    return subprocess.run(cmd, capture_output=True, text=True)


def scan_json(src) -> tuple[int, dict | None]:
    """scan --json 을 실행해 (returncode, dict|None) 을 돌려준다."""
    r = run_slop(["scan", "--src", str(src), "--json"])
    if not r.stdout.strip():
        return r.returncode, None
    last_line = r.stdout.strip().splitlines()[-1]
    try:
        return r.returncode, json.loads(last_line)
    except json.JSONDecodeError:
        return r.returncode, None


def hit_counts(data: dict) -> dict[str, int]:
    out = {"S1": 0, "S2": 0, "S3": 0}
    for h in data.get("hits", []):
        out[h["id"]] = out.get(h["id"], 0) + 1
    return out


def load_expected(name: str) -> dict:
    return json.loads((EXPECTED_DIR / name).read_text(encoding="utf-8"))


def _import_slop_scan():
    """slop_scan 모듈을 직접 임포트한다(내부 함수 단위 테스트용).

    `scripts/` 를 sys.path 에 얹는 방식 — test_llm_signature.py 계열 하네스가
    스크립트를 로드하는 방식과 같다. CLI 계약 테스트(TestCliContract)는
    subprocess 로만 검증하고, 이 임포트는 순수 함수 단위 테스트에만 쓴다.
    """
    if str(SCRIPTS_DIR) not in sys.path:
        sys.path.insert(0, str(SCRIPTS_DIR))
    import slop_scan

    return slop_scan


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestCliContract(unittest.TestCase):
    """CLI 계약 기본기: 서브커맨드 존재, exit code, scan 의 JSON 출력."""

    def test_lexicon_file_exists(self):
        self.assertTrue(LEXICON.exists(), f"lexicon 파일이 있어야 한다: {LEXICON}")

    def test_help_lists_three_subcommands(self):
        r = run_slop(["--help"])
        self.assertEqual(r.returncode, 0)
        for sub in ("scan", "extract-llm", "compare"):
            self.assertIn(sub, r.stdout, f"서브커맨드 {sub} 가 --help 에 보여야 한다")

    def test_scan_missing_file_exit0(self):
        """게이트 exit 에 기여하지 않는다 — 입력이 없어도 exit 0."""
        rc, _ = scan_json(CORPUS_DIR / "__does_not_exist__.md")
        self.assertEqual(rc, 0)

    def test_scan_json_has_metrics_key(self):
        """scan --json 은 파이프라인을 실제로 돌려 JSON 한 줄을 낸다.

        지표가 아직 하나도 없어도 metrics 키는 있어야 한다 — 이 테스트가
        "미구현" 문구만 찍는 스텁을 통과시키지 않는 유일한 장치다.
        """
        rc, data = scan_json(CORPUS_DIR / "clean.md")
        self.assertEqual(rc, 0)
        self.assertIsNotNone(data, "stdout 마지막 줄이 JSON 이어야 한다")
        self.assertIn("metrics", data)
        self.assertIsInstance(data["metrics"], list)


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestLoadLexiconUnit(unittest.TestCase):
    """load_lexicon 직접 호출 — 정상/라벨 항목은 살리고 깨진 정규식은 버리며 로그를 남긴다."""

    def test_parses_plain_and_labeled_entries_skips_broken_regex(self):
        slop_scan = _import_slop_scan()
        content = (
            "[S1_certainty]\n"
            "필터단어\n"
            "re:테스트\\d+ => 테스트라벨\n"
            "re:(unclosed\n"
        )
        with tempfile.NamedTemporaryFile(
            "w", suffix=".txt", delete=False, encoding="utf-8"
        ) as f:
            f.write(content)
            path = f.name
        try:
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                lex = slop_scan.load_lexicon(path)
            self.assertIsNotNone(lex)
            terms = {e["term"] for e in lex["S1_certainty"]}
            self.assertIn("필터단어", terms, "일반 항목은 그대로 남아야 한다")
            self.assertIn("테스트라벨", terms, "=> 라벨이 붙은 정규식 항목은 라벨로 남아야 한다")
            self.assertEqual(
                len(lex["S1_certainty"]), 2, "깨진 정규식(re:(unclosed) 항목은 빠져야 한다"
            )
            self.assertIn(
                "정규식 오류",
                stderr.getvalue(),
                "깨진 정규식은 조용히 버려지지 않고 stderr 에 한 줄 남아야 한다",
            )
        finally:
            Path(path).unlink(missing_ok=True)


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestProseUnitsUnit(unittest.TestCase):
    """prose_units 직접 호출 — 보호 구간(헤딩·코드펜스·표)은 빼고 산문만 남긴다."""

    def test_skips_protected_regions_keeps_prose(self):
        slop_scan = _import_slop_scan()
        text = (
            "# 제목\n"
            "```\n"
            "코드 안 내용\n"
            "```\n"
            "| 표 | 행 |\n"
            "- 불릿 항목\n"
            "문단 텍스트다.\n"
        )
        units, evidence, fence_lines = slop_scan.prose_units(text)
        self.assertEqual(fence_lines, {2, 3, 4}, "코드펜스 여닫는 줄과 내부 줄이 모두 잡혀야 한다")
        self.assertIn("코드 안 내용", evidence, "펜스 안 내용은 근거 코퍼스에 들어가야 한다")
        self.assertIn("| 표 | 행 |", evidence, "표 행은 근거 코퍼스에 들어가야 한다")
        lines_map = {ln: t for ln, t in units}
        self.assertNotIn(1, lines_map, "헤딩 줄은 산문에 없어야 한다")
        self.assertNotIn(5, lines_map, "표 행은 산문에 없어야 한다")
        self.assertEqual(lines_map.get(6, "").strip(), "불릿 항목", "불릿 마커는 벗겨지고 본문만 남아야 한다")
        self.assertEqual(lines_map.get(7, "").strip(), "문단 텍스트다.")


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestSentencesUnit(unittest.TestCase):
    """sentences 직접 호출 — 문장 분리와 원본 줄번호 귀속을 확인한다."""

    def test_splits_sentences_and_attributes_source_line(self):
        slop_scan = _import_slop_scan()
        units = [(1, "첫 문장이다. 둘째 문장이다."), (2, "셋째 문장이다.")]
        sents = slop_scan.sentences(units)
        self.assertEqual(
            [s["text"] for s in sents],
            ["첫 문장이다.", "둘째 문장이다.", "셋째 문장이다."],
        )
        self.assertEqual([s["line"] for s in sents], [1, 1, 2])


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestFixtureExpectations(unittest.TestCase):
    """픽스처마다 expected/*.json 의 발동 목록·히트 하한·히트 상한을 검증한다."""

    FIXTURES: list[str] = ["s1_certainty", "clean", "s2_filler", "s3_unsourced", "s3_sourced"]

    def test_fixtures_match_expected(self):
        for name in self.FIXTURES:
            with self.subTest(fixture=name):
                src = CORPUS_DIR / f"{name}.md"
                self.assertTrue(src.exists(), f"픽스처 없음: {src}")
                rc, data = scan_json(src)
                self.assertEqual(rc, 0)
                self.assertIsNotNone(data, "stdout 마지막 줄이 JSON 이어야 한다")
                exp = load_expected(f"{name}.json")
                self.assertEqual(
                    sorted(data["triggered"]), sorted(exp["triggered"]),
                    f"{name}: 발동 목록 불일치 (metrics={data['metrics']})",
                )
                counts = hit_counts(data)
                for mid, low in exp.get("hits_min", {}).items():
                    self.assertGreaterEqual(counts.get(mid, 0), low, f"{name}: {mid} 히트 하한 미달")
                for mid, high in exp.get("hits_max", {}).items():
                    self.assertLessEqual(counts.get(mid, 0), high, f"{name}: {mid} 히트 상한 초과")

    def test_scan_json_metric_schema(self):
        rc, data = scan_json(CORPUS_DIR / "s1_certainty.md")
        self.assertEqual(rc, 0)
        for m in data["metrics"]:
            for key in ("id", "label", "kind", "raw", "value", "triggered", "note"):
                self.assertIn(key, m)
            self.assertEqual(m["kind"], "report", "게이트 S 지표는 전부 report 종류다")
            self.assertGreaterEqual(m["value"], 0.0)
            self.assertLessEqual(m["value"], 1.0)

    def test_hits_carry_line_and_quote(self):
        rc, data = scan_json(CORPUS_DIR / "s1_certainty.md")
        self.assertEqual(rc, 0)
        self.assertTrue(data["hits"], "S1 픽스처는 히트가 있어야 한다")
        for h in data["hits"]:
            for key in ("id", "term", "line", "quote"):
                self.assertIn(key, h)
            self.assertGreater(h["line"], 0)
            self.assertLessEqual(len(h["quote"]), 80)


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestScanContract(unittest.TestCase):
    """scan 서브커맨드의 출력 계약."""

    def test_metrics_are_s1_s2_s3_in_order(self):
        rc, data = scan_json(CORPUS_DIR / "s1_certainty.md")
        self.assertEqual(rc, 0)
        self.assertEqual([m["id"] for m in data["metrics"]], ["S1", "S2", "S3"])

    def test_json_top_level_key_order(self):
        rc, data = scan_json(CORPUS_DIR / "clean.md")
        self.assertEqual(rc, 0)
        self.assertEqual(list(data.keys()), ["file", "metrics", "hits", "triggered"])

    def test_human_table_without_json_flag(self):
        r = run_slop(["scan", "--src", str(CORPUS_DIR / "s1_certainty.md")])
        self.assertEqual(r.returncode, 0)
        self.assertIn("초안 관문", r.stdout)
        self.assertIn("발동된 초안 관문 항목", r.stdout)
        self.assertNotIn('"metrics"', r.stdout, "--json 없이는 JSON 줄이 없어야 한다")

    def test_missing_lexicon_skips_quietly(self):
        r = run_slop([
            "scan", "--src", str(CORPUS_DIR / "clean.md"),
            "--lexicon", str(CORPUS_DIR / "__no_lexicon__.txt"),
        ])
        self.assertEqual(r.returncode, 0)
        self.assertIn("lexicon 파일 없음", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
