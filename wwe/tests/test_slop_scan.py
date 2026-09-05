#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""slop_scan.py 회귀 테스트 (게이트 S — 초안 관문).

unittest + subprocess. 구현을 임포트하지 않고 CLI 계약(스펙)만 근거로 검증한다.
`slop_scan.py` 가 아직 없으면 각 테스트 클래스는 명확한 스킵 메시지를 낸다.

실행:
    python3 tests/test_slop_scan.py
    (또는 run.sh 경유)
"""

import json
import subprocess
import sys
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SKILL_DIR = TESTS_DIR.parent
CORPUS_DIR = TESTS_DIR / "slop_corpus"
EXPECTED_DIR = CORPUS_DIR / "expected"
SCRIPT = SKILL_DIR / "scripts" / "slop_scan.py"
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
