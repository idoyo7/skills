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

    FIXTURES: list[str] = [
        "s1_certainty", "clean", "s2_filler",
        "s3_unsourced", "s3_sourced", "s3_fence_adjacent", "s3_number_in_table",
    ]

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


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestExtractLlm(unittest.TestCase):
    """extract-llm 의 present / absent / broken 세 갈래."""

    def _extract(self, fixture: str) -> tuple[int, dict]:
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "11_slop.json"
            r = run_slop([
                "extract-llm",
                "--final", str(CORPUS_DIR / fixture),
                "--out", str(out),
            ])
            self.assertTrue(out.exists(), f"산출물이 없다: {r.stdout}\n{r.stderr}")
            return r.returncode, json.loads(out.read_text(encoding="utf-8"))

    def test_present_parses_two_findings(self):
        rc, data = self._extract("summary_present.md")
        self.assertEqual(rc, 0)
        self.assertEqual(data["source"]["final"].endswith("summary_present.md"), True)
        self.assertIsNone(data["source"]["before"])
        self.assertIsNone(data["source"]["after"])
        llm = data["llm_monolith"]
        self.assertEqual(llm["provider"], "monolith")
        self.assertEqual(llm["truncated"], False)
        self.assertEqual(len(llm["findings"]), 2)
        first = llm["findings"][0]
        self.assertEqual(first["item"], "확신")
        self.assertEqual(first["quote"], "이 방식은 어떤 경우에도 안전하다")
        self.assertEqual(first["why"], "보편양화, 근거 없음")
        self.assertEqual(first["after"], "유지")
        self.assertEqual(first["origin"], "원문", "monolith 판정은 전부 원문 유래다")
        self.assertEqual(llm["findings"][1]["item"], "미검증")
        self.assertEqual(llm["findings"][1]["origin"], "원문")

    def test_absent_yields_null_with_note(self):
        rc, data = self._extract("summary_absent.md")
        self.assertEqual(rc, 0)
        self.assertIsNone(data["llm_monolith"])
        self.assertEqual(data.get("note"), "slop_findings 키 없음")

    def test_broken_yields_error_object(self):
        rc, data = self._extract("summary_broken.md")
        self.assertEqual(rc, 0)
        self.assertIsInstance(data["llm_monolith"], dict)
        self.assertIn("error", data["llm_monolith"])

    def test_no_block_at_all_yields_null(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            final = Path(td) / "final.md"
            final.write_text("블록이 없는 평범한 본문이다.\n", encoding="utf-8")
            out = Path(td) / "11_slop.json"
            r = run_slop(["extract-llm", "--final", str(final), "--out", str(out)])
            self.assertEqual(r.returncode, 0)
            data = json.loads(out.read_text(encoding="utf-8"))
            self.assertIsNone(data["llm_monolith"])
            self.assertEqual(data.get("note"), "HUMANIZE-SUMMARY 블록 없음")

    def _extract_content(self, content: str) -> tuple[int, dict]:
        """임의 final.md 본문으로 extract-llm 을 실행한다(코퍼스 고정 픽스처 밖의 경우용)."""
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            final = Path(td) / "final.md"
            final.write_text(content, encoding="utf-8")
            out = Path(td) / "11_slop.json"
            r = run_slop(["extract-llm", "--final", str(final), "--out", str(out)])
            self.assertTrue(out.exists(), f"산출물이 없다: {r.stdout}\n{r.stderr}")
            return r.returncode, json.loads(out.read_text(encoding="utf-8"))

    def test_arrow_inside_quote_does_not_truncate_block(self):
        """quote 값 안의 "-->" 로 블록이 잘리면 뒤 finding 이 통째로 사라진다 —
        종결자는 첫 "-->" 가 아니라 블록 맨 끝의 마지막 "-->" 여야 한다."""
        content = (
            "윤문된 본문이 여기 온다.\n\n"
            "<!-- HUMANIZE-SUMMARY v1.6.1\n"
            "slop_findings:\n"
            "  - item: 확신\n"
            '    quote: "이 방식은 어떤 경우에도 안전하다"\n'
            '    why: "보편양화, 근거 없음"\n'
            "    after: 유지\n"
            "  - item: 변환\n"
            '    quote: "A --> B 로 바뀐다"\n'
            '    why: "예시"\n'
            "    after: 유지\n"
            "  - item: 미검증\n"
            '    quote: "대부분의 팀이 30% 이상 절감했다"\n'
            '    why: "출처 없음"\n'
            "    after: 수정\n"
            "slop_findings_truncated: false\n"
            "-->\n"
        )
        rc, data = self._extract_content(content)
        self.assertEqual(rc, 0)
        llm = data["llm_monolith"]
        self.assertIsNotNone(llm, f"블록이 잘려 findings 가 통째로 사라졌다: {data}")
        self.assertNotIn("error", llm)
        self.assertEqual(len(llm["findings"]), 3, "-->  뒤의 finding 까지 다 남아야 한다")
        self.assertEqual(llm["findings"][1]["item"], "변환")
        self.assertEqual(
            llm["findings"][1]["quote"], "A --> B 로 바뀐다",
            "quote 안의 --> 가 종결자로 오인되어 잘리면 안 된다",
        )
        self.assertEqual(llm["findings"][2]["item"], "미검증")

    def test_no_terminator_yields_error(self):
        """HUMANIZE-SUMMARY 시작 마커는 있는데 "-->" 종결자가 아예 없으면 malformed 다."""
        content = (
            "윤문된 본문이 여기 온다.\n\n"
            "<!-- HUMANIZE-SUMMARY v1.6.1\n"
            "slop_findings:\n"
            "  - item: 확신\n"
            '    quote: "종결자가 없다"\n'
        )
        rc, data = self._extract_content(content)
        self.assertEqual(rc, 0)
        self.assertIsInstance(data["llm_monolith"], dict)
        self.assertEqual(data["llm_monolith"].get("error"), "HUMANIZE-SUMMARY 종결자 없음")

    def test_escaped_inner_quotes_unescaped(self):
        content = (
            "본문.\n\n"
            "<!-- HUMANIZE-SUMMARY v1.6.1\n"
            "slop_findings:\n"
            "  - item: 인용\n"
            '    quote: "그는 \\"정말\\" 좋다"\n'
            "-->\n"
        )
        rc, data = self._extract_content(content)
        self.assertEqual(rc, 0)
        llm = data["llm_monolith"]
        self.assertNotIn("error", llm, f"이스케이프된 중첩 인용부호가 파싱 실패로 처리됐다: {llm}")
        self.assertEqual(llm["findings"][0]["quote"], '그는 "정말" 좋다')

    def test_unescaped_inner_quotes_still_parsed(self):
        content = (
            "본문.\n\n"
            "<!-- HUMANIZE-SUMMARY v1.6.1\n"
            "slop_findings:\n"
            "  - item: 인용\n"
            '    quote: "그는 "정말" 좋다"\n'
            "-->\n"
        )
        rc, data = self._extract_content(content)
        self.assertEqual(rc, 0)
        llm = data["llm_monolith"]
        self.assertNotIn("error", llm, f"이스케이프 안 된 중첩 인용부호가 파싱 실패로 처리됐다: {llm}")
        self.assertEqual(llm["findings"][0]["quote"], '그는 "정말" 좋다')

    def test_unterminated_quote_yields_error(self):
        content = (
            "본문.\n\n"
            "<!-- HUMANIZE-SUMMARY v1.6.1\n"
            "slop_findings:\n"
            "  - item: 인용\n"
            '    quote: "열린 채로\n'
            "-->\n"
        )
        rc, data = self._extract_content(content)
        self.assertEqual(rc, 0)
        self.assertIsInstance(data["llm_monolith"], dict)
        self.assertIn("error", data["llm_monolith"])


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestCompare(unittest.TestCase):
    """compare 의 유래 판정·llm 병합·pending 줄·exit 0."""

    def _compare(self, extra: list[str] | None = None) -> tuple[subprocess.CompletedProcess, dict, Path]:
        import tempfile
        self._td = tempfile.TemporaryDirectory()
        td = Path(self._td.name)
        out = td / "11_slop.json"
        args = [
            "compare",
            "--before", str(CORPUS_DIR / "before.md"),
            "--after", str(CORPUS_DIR / "after_introduced.md"),
            "--out", str(out),
        ] + (extra or [])
        r = run_slop(args)
        return r, json.loads(out.read_text(encoding="utf-8")), td

    def test_introduced_terms_counted(self):
        r, data, _ = self._compare()
        self.assertEqual(r.returncode, 0)
        exp = load_expected("before_after.json")
        grouped: dict[tuple[str, str], int] = {}
        for it in data["scan"]["introduced"]:
            self.assertEqual(it["origin"], "윤문")
            key = (it["id"], it["term"])
            grouped[key] = grouped.get(key, 0) + 1
        for want in exp["introduced"]:
            self.assertEqual(grouped.get((want["id"], want["term"]), 0), want["count"])
        self.assertEqual(data["scan"]["resolved"], exp["resolved"])

    def test_top_level_key_order(self):
        _, data, _ = self._compare()
        self.assertEqual(
            list(data.keys()),
            ["version", "source", "scan", "llm", "llm_monolith", "summary"],
        )

    def test_summary_counts(self):
        _, data, _ = self._compare()
        s = data["summary"]
        for key in ("S1", "S2", "S3", "introduced", "llm_findings"):
            self.assertIn(key, s)
        self.assertEqual(s["introduced"], 2)
        self.assertEqual(s["llm_findings"], 0)

    def test_llm_null_without_inputs(self):
        _, data, _ = self._compare()
        self.assertIsNone(data["llm"])
        self.assertIsNone(data["llm_monolith"])

    def test_judge_wins_and_monolith_kept(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            tdp = Path(td)
            mono = tdp / "11_slop.json"
            run_slop([
                "extract-llm",
                "--final", str(CORPUS_DIR / "summary_present.md"),
                "--out", str(mono),
            ])
            judge = tdp / "11_slop_judge.json"
            judge.write_text(json.dumps({
                "provider": "wwe-slop-judge",
                "findings": [{"item": "필러", "quote": "이 점은 중요하다", "why": "지워도 손실 없음",
                              "after": "유지", "origin": "윤문"}],
                "truncated": False,
            }, ensure_ascii=False), encoding="utf-8")
            out = tdp / "final_slop.json"
            r = run_slop([
                "compare",
                "--before", str(CORPUS_DIR / "before.md"),
                "--after", str(CORPUS_DIR / "after_introduced.md"),
                "--llm", str(mono), "--judge", str(judge), "--out", str(out),
            ])
            self.assertEqual(r.returncode, 0)
            data = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(data["llm"]["provider"], "wwe-slop-judge")
            self.assertEqual(data["llm"]["findings"][0]["origin"], "윤문")
            self.assertEqual(data["llm_monolith"]["provider"], "monolith")
            self.assertEqual(len(data["llm_monolith"]["findings"]), 2)
            self.assertTrue(all(f["origin"] == "원문" for f in data["llm_monolith"]["findings"]))
            self.assertEqual(data["summary"]["llm_findings"], 1)
            self.assertTrue(data["source"]["final"].endswith("summary_present.md"),
                            "extract-llm 이 적어 둔 source.final 이 살아 있어야 한다")

    def test_judge_origin_rederived_from_before(self):
        """judge 의 origin 은 모델 값이 아니라 원문 대조로 다시 매긴다.

        모델이 규칙을 문자열이 아니라 문제의 출처로 읽는 일이 실측에서 관측됐다(1.4.0).
        아래 두 검출은 모델이 준 origin 이 둘 다 뒤집혀 있는데, compare 를 거치면
        발췌가 실제로 원문에 있는지로 바로잡혀야 한다.
        """
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            tdp = Path(td)
            judge = tdp / "11_slop_judge.json"
            judge.write_text(json.dumps({
                "provider": "wwe-slop-judge",
                "findings": [
                    # before.md 에 그대로 있는 발췌인데 모델은 윤문이라고 했다 → 원문으로 정정
                    {"item": "확신", "quote": "반드시 만료 시각을 함께 확인한다.",
                     "why": "근거 없는 당위", "after": "유지", "origin": "윤문"},
                    # after 에만 있는 발췌인데 모델은 원문이라고 했다 → 윤문으로 정정
                    {"item": "확신", "quote": "분명히 이 순서가 맞다.",
                     "why": "윤문이 심은 단정", "after": "제거", "origin": "원문"},
                ],
                "truncated": False,
            }, ensure_ascii=False), encoding="utf-8")
            out = tdp / "11_slop.json"
            pending = tdp / "pending.txt"
            r = run_slop([
                "compare",
                "--before", str(CORPUS_DIR / "before.md"),
                "--after", str(CORPUS_DIR / "after_introduced.md"),
                "--judge", str(judge), "--out", str(out), "--pending", str(pending),
            ])
            self.assertEqual(r.returncode, 0)
            data = json.loads(out.read_text(encoding="utf-8"))
            found = data["llm"]["findings"]
            self.assertEqual(found[0]["origin"], "원문", "원문에 그대로 있는 발췌")
            self.assertEqual(found[1]["origin"], "윤문", "원문에 없는 발췌")
            self.assertTrue(all(f["origin_verified"] is True for f in found),
                            "기계 판정을 거쳤다는 표시가 있어야 한다")
            # 이 정정은 pending 줄과 summary 를 건드리지 않는다.
            self.assertEqual(data["summary"]["llm_findings"], 2)
            self.assertEqual(data["summary"]["introduced"], 2)
            line = pending.read_text(encoding="utf-8").strip()
            self.assertTrue(line.startswith("gate=S exit=1 action=none reason=초안 관문: "), line)

    def test_judge_origin_kept_when_quote_missing(self):
        """quote 가 비어 있으면 대조할 것이 없으므로 모델 값을 그대로 둔다."""
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            tdp = Path(td)
            judge = tdp / "11_slop_judge.json"
            judge.write_text(json.dumps({
                "provider": "wwe-slop-judge",
                "findings": [{"item": "필러", "quote": "", "why": "발췌 없음",
                              "after": "유지", "origin": "원문"}],
                "truncated": False,
            }, ensure_ascii=False), encoding="utf-8")
            out = tdp / "11_slop.json"
            r = run_slop([
                "compare",
                "--before", str(CORPUS_DIR / "before.md"),
                "--after", str(CORPUS_DIR / "after_introduced.md"),
                "--judge", str(judge), "--out", str(out),
            ])
            self.assertEqual(r.returncode, 0)
            f = json.loads(out.read_text(encoding="utf-8"))["llm"]["findings"][0]
            self.assertEqual(f["origin"], "원문")
            self.assertNotIn("origin_verified", f)

    def test_pending_line_appended(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            pending = Path(td) / "pending.txt"
            out = Path(td) / "11_slop.json"
            r = run_slop([
                "compare",
                "--before", str(CORPUS_DIR / "clean.md"),
                "--after", str(CORPUS_DIR / "s1_certainty.md"),
                "--out", str(out), "--pending", str(pending),
            ])
            self.assertEqual(r.returncode, 0)
            line = pending.read_text(encoding="utf-8").strip()
            self.assertTrue(line.startswith("gate=S exit=1 action=none reason=초안 관문: "), line)
            self.assertIn("윤문 유입", line)

    def test_no_pending_when_nothing_triggers(self):
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            pending = Path(td) / "pending.txt"
            out = Path(td) / "11_slop.json"
            r = run_slop([
                "compare",
                "--before", str(CORPUS_DIR / "clean.md"),
                "--after", str(CORPUS_DIR / "clean.md"),
                "--out", str(out), "--pending", str(pending),
            ])
            self.assertEqual(r.returncode, 0)
            self.assertFalse(pending.exists(), "발동이 없으면 pending 줄을 남기지 않는다")

    def test_pending_write_failure_degrades_gracefully(self):
        """--pending 의 부모 디렉터리가 없으면 traceback 대신 안내 후 정상 진행한다."""
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            pending = Path(td) / "nosuchdir" / "pending.txt"
            out = Path(td) / "11_slop.json"
            r = run_slop([
                "compare",
                "--before", str(CORPUS_DIR / "before.md"),
                "--after", str(CORPUS_DIR / "after_introduced.md"),
                "--out", str(out), "--pending", str(pending),
            ])
            self.assertEqual(r.returncode, 0)
            self.assertIn("pending 기록 실패", r.stderr)
            data = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(data["summary"]["introduced"], 2)
            self.assertIn("초안 관문:", r.stdout)


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestS3SentenceScopedEvidence(unittest.TestCase):
    """S3 근거 표지의 판정 범위(문장 vs 문단)를 직접 검증한다.

    인라인 코드·마크다운 링크·URL·HZ 토큰은 "같은 문장"에 있을 때만 근거로 본다
    (설계 스펙 §2-1). 옆 문장에 백틱이 있다고 이 문장의 주장까지 면제되면 안 된다.
    """

    def test_inline_code_in_other_sentence_does_not_waive_claim(self):
        slop_scan = _import_slop_scan()
        text = "대부분의 팀이 40% 이상 비용을 절감했다. 배포 방식은 `docker compose up` 명령을 쓴다.\n"
        lex = slop_scan.load_lexicon(str(LEXICON))
        self.assertIsNotNone(lex)
        result = slop_scan.scan_text(text, lex)
        self.assertEqual(
            len(result["hits"]), 1,
            f"인라인 코드는 같은 문장에 없으면 근거가 아니다: {result['hits']}",
        )
        self.assertEqual(result["hits"][0]["quote"], "대부분의 팀이 40% 이상 비용을 절감했다.")


if __name__ == "__main__":
    unittest.main(verbosity=2)
