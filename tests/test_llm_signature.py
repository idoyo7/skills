#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""llm_signature.py 회귀 테스트 (캘리브레이션 라운드 1/2).

unittest + subprocess. 구현을 임포트하지 않고 CLI 계약(스펙)만 근거로 검증한다.
`llm_signature.py` 가 아직 없으면 각 테스트 클래스는 명확한 스킵 메시지를 낸다.

실행:
    python3 tests/test_llm_signature.py
    (또는 run.sh 경유)
"""

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SKILL_DIR = TESTS_DIR.parent
SIG_CORPUS_DIR = TESTS_DIR / "sig_corpus"
SCRIPT = SKILL_DIR / "scripts" / "llm_signature.py"
LABELS_PATH = SIG_CORPUS_DIR / "labels.json"

# labels.json 의 "real": true 항목은 이 리포(humanize-docs 스킬) 밖의, 실제 인간이 쓴
# 문서에서 발췌한 캘리브레이션 표본이다(레포에는 원본을 넣지 않는다 — provenance만
# 상대경로 라벨로 남긴다). 원본 문서 자체는 이 저장소 밖 로컬 환경에만 있을 수 있으므로,
# HUMANIZE_DOCS_REAL_CORPUS_ROOT 환경변수로 그 루트를 가리키면 TestRealDocuments가
# 그 루트 밑에서 같은 상대경로로 파일을 찾아 추가 검증을 켠다. 변수가 없으면(대부분의
# 환경) REAL_ROOT_MAP은 비고, 해당 테스트들은 모두 조용히 스킵된다.
_REAL_CORPUS_ROOT = os.environ.get("HUMANIZE_DOCS_REAL_CORPUS_ROOT")
_REAL_RELATIVE_PATHS = [
    "temp/CPU_Burst_학습노트.md",
    "monitoring/logging-observability-intro.md",
    "karpenter-consolidation-analysis/KARPENTER-FINAL.md",
    "nextra-blog/WRITING_STYLE.md",
    "hotdeal/README.md",
    "jekyll/moonwalk_on_windows.md",
    "homelab/2026-05-08-node1-fan-quiet-and-power-limit.md",
]
REAL_ROOT_MAP = (
    {rel: str(Path(_REAL_CORPUS_ROOT) / rel) for rel in _REAL_RELATIVE_PATHS}
    if _REAL_CORPUS_ROOT
    else {}
)

ACTIONABLE_IDS = {"L1", "L6", "L7", "L8", "L9", "L10"}


def _script_missing_reason():
    if not SCRIPT.exists():
        return (
            f"llm_signature.py 가 아직 존재하지 않습니다: {SCRIPT}\n"
            "  구현 에이전트가 작업 중일 수 있습니다. 이 스킵은 정상입니다."
        )
    return None


def run_sig(args):
    cmd = [sys.executable, str(SCRIPT), *args]
    return subprocess.run(cmd, capture_output=True, text=True)


def score_json(src):
    """score --json 을 실행해 (returncode, dict|None) 을 돌려준다."""
    r = run_sig(["score", "--src", str(src), "--json"])
    if not r.stdout.strip():
        return r.returncode, None
    last_line = r.stdout.strip().splitlines()[-1]
    try:
        return r.returncode, json.loads(last_line)
    except json.JSONDecodeError:
        return r.returncode, None


def compare_json(before, after, min_drop=None):
    args = ["compare", "--before", str(before), "--after", str(after), "--json"]
    if min_drop is not None:
        args += ["--min-drop", str(min_drop)]
    r = run_sig(args)
    if not r.stdout.strip():
        return r.returncode, None
    last_line = r.stdout.strip().splitlines()[-1]
    try:
        return r.returncode, json.loads(last_line)
    except json.JSONDecodeError:
        return r.returncode, None


def load_labels():
    return json.loads(LABELS_PATH.read_text(encoding="utf-8"))["files"]


def resolve_path(entry):
    """labels.json 엔트리를 실제 채점 대상 경로(Path)로 바꾼다."""
    p = entry["path"]
    if entry.get("real"):
        mapped = REAL_ROOT_MAP.get(p)
        return Path(mapped) if mapped else None
    return SIG_CORPUS_DIR / p


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestCliContract(unittest.TestCase):
    """CLI 계약 기본기: exit code, --json 마지막 줄 스키마."""

    def test_score_missing_file_exit3(self):
        rc, data = score_json(SIG_CORPUS_DIR / "__does_not_exist__.md")
        self.assertEqual(rc, 3)

    def test_score_json_schema_top_level_keys(self):
        rc, data = score_json(SIG_CORPUS_DIR / "ai_01_max.md")
        self.assertEqual(rc, 0)
        self.assertIsNotNone(data, "stdout 마지막 줄이 JSON 이어야 한다")
        for key in ("file", "mode", "layout_ai_score", "actionable_score", "grade", "metrics", "triggered_actionable"):
            self.assertIn(key, data)
        self.assertEqual(len(data["metrics"]), 14, "L1~L14 전부 나와야 한다")
        ids = {m["id"] for m in data["metrics"]}
        self.assertEqual(ids, {f"L{i}" for i in range(1, 15)})
        for m in data["metrics"]:
            for key in ("id", "label", "kind", "raw", "value", "triggered", "note"):
                self.assertIn(key, m)
            self.assertIn(m["kind"], ("actionable", "report"))
            self.assertGreaterEqual(m["value"], 0.0)
            self.assertLessEqual(m["value"], 1.0)


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestCorpusSeparation(unittest.TestCase):
    """요구 1) 분리도 검증 — labels.json 전체."""

    @classmethod
    def setUpClass(cls):
        cls.results = {}
        for entry in load_labels():
            path = resolve_path(entry)
            if path is None or not path.exists():
                continue
            rc, data = score_json(path)
            if data is None:
                continue
            cls.results[entry["path"]] = (entry, data)

    def test_all_labeled_files_scored(self):
        """"real": true 항목은 이 저장소 밖의 선택적 실물 파일이라(위 REAL_ROOT_MAP
        주석 참고) 없어도 정상이다 — 필수 채점 대상은 레포에 함께 들어 있는 sig_corpus뿐."""
        labels = load_labels()
        missing = [
            e["path"] for e in labels
            if e["path"] not in self.results and not e.get("real")
        ]
        self.assertEqual(missing, [], f"채점 실패/실물 파일 없음: {missing}")

    def test_heavy_ai_grade_c_or_d(self):
        for path, (entry, data) in self.results.items():
            if entry["label"] != "heavy_ai":
                continue
            with self.subTest(path=path):
                self.assertIn(data["grade"], ("C", "D"), f"{path} grade={data['grade']} (C/D 기대)")

    def test_human_grade_a_or_b(self):
        for path, (entry, data) in self.results.items():
            if entry["label"] != "human":
                continue
            with self.subTest(path=path):
                self.assertIn(data["grade"], ("A", "B"), f"{path} grade={data['grade']} (A/B 기대)")

    def test_edge_files_zero_actionable_triggers(self):
        for path, (entry, data) in self.results.items():
            if not path.startswith("edge_"):
                continue
            with self.subTest(path=path):
                self.assertEqual(
                    data["triggered_actionable"], [],
                    f"{path}: edge 케이스는 표본 부족으로 actionable 지표가 전부 침묵해야 한다 "
                    f"(오탐: {data['triggered_actionable']})",
                )

    def test_separation_margin_heavy_ai_gt_human(self):
        heavy_scores = [data["actionable_score"] for entry, data in self.results.values() if entry["label"] == "heavy_ai"]
        human_scores = [data["actionable_score"] for entry, data in self.results.values() if entry["label"] == "human"]
        self.assertTrue(heavy_scores, "heavy_ai 라벨 파일이 없다")
        self.assertTrue(human_scores, "human 라벨 파일이 없다")
        min_heavy = min(heavy_scores)
        max_human = max(human_scores)
        self.assertGreater(
            min_heavy, max_human,
            f"분리 마진 없음: heavy_ai 최저={min_heavy} <= human 최고={max_human}",
        )

    def test_labeled_actionable_triggers_match_expectation(self):
        """labels.json 의 expect_triggered/expect_not_triggered 중 actionable(L1/L6/L7/L8/L9/L10)만 대조한다.
        report 축(L2/L3/L4/L5/L11/L12/L13/L14)은 스펙상 미검증·가중치가 낮아 이 테스트에서 강제하지 않는다."""
        for path, (entry, data) in self.results.items():
            triggered = set(data["triggered_actionable"])
            expect_trig = set(entry.get("expect_triggered", [])) & ACTIONABLE_IDS
            expect_not = set(entry.get("expect_not_triggered", [])) & ACTIONABLE_IDS
            with self.subTest(path=path):
                missing = expect_trig - triggered
                forbidden = triggered & expect_not
                self.assertEqual(missing, set(), f"{path}: 기대한 actionable 트리거 미발동 {missing}")
                self.assertEqual(forbidden, set(), f"{path}: 금지된 actionable 트리거 발동 {forbidden}")


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestRealDocuments(unittest.TestCase):
    """요구 2) 실물 검증 — 메타데이터 캡션 예외가 실제로 작동하는가."""

    def _score(self, rel_path):
        path = REAL_ROOT_MAP.get(rel_path)
        if path is None:
            self.skipTest(f"실물 파일 없음(이 환경 밖): {rel_path}")
        p = Path(path)
        if not p.exists():
            self.skipTest(f"실물 파일 없음(이 환경 밖): {path}")
        rc, data = score_json(p)
        self.assertEqual(rc, 0, f"score 실행 실패: {path}")
        self.assertIsNotNone(data)
        return data

    def test_karpenter_final_no_l9_l10_grade_ab(self):
        data = self._score("karpenter-consolidation-analysis/KARPENTER-FINAL.md")
        triggered = set(data["triggered_actionable"])
        self.assertNotIn("L9", triggered, "서두 '코드 근거 checkout' 방법론 각주가 TL;DR 로 오탐됨")
        self.assertNotIn("L10", triggered, "'버전 고지'/'조립 정정' 캡션이 강조용 인용으로 오탐됨")
        self.assertIn(data["grade"], ("A", "B"))

    def test_cpu_burst_no_l9_grade_cd_but_l6_l7_fire(self):
        data = self._score("temp/CPU_Burst_학습노트.md")
        triggered = set(data["triggered_actionable"])
        self.assertNotIn("L9", triggered, "서두 '출처'/'원자료' 표기가 TL;DR 로 오탐됨")
        self.assertIn("L6", triggered, "이모지 20개는 실제 지문이므로 L6 발동해야 한다")
        self.assertIn("L7", triggered, "--- 17개는 실제 지문이므로 L7 발동해야 한다")
        self.assertIn(data["grade"], ("C", "D"))

    def test_logging_observability_l1_l10_fire(self):
        data = self._score("monitoring/logging-observability-intro.md")
        triggered = set(data["triggered_actionable"])
        self.assertIn("L1", triggered, "볼드리드 비율 0.78 은 진짜 카탈로그형 불릿 지문이다")
        self.assertIn("L10", triggered, "'> 판단: ...' 11개는 진짜 강조용 인용이다")

    def test_hotdeal_readme_all_actionable_silent(self):
        data = self._score("hotdeal/README.md")
        self.assertEqual(data["triggered_actionable"], [], "강한 negative 기준점 - 전 지표 침묵해야 한다")

    def test_moonwalk_tiny_doc_all_silent(self):
        data = self._score("jekyll/moonwalk_on_windows.md")
        self.assertEqual(data["triggered_actionable"], [], "9줄 초미니 문서 - 표본 부족으로 전 지표 침묵해야 한다")

    def test_all_real_docs_grade_matches_label(self):
        for entry in load_labels():
            if not entry.get("real"):
                continue
            rel_path = entry["path"]
            mapped = REAL_ROOT_MAP.get(rel_path)
            if mapped is None:
                self.skipTest(f"실물 파일 없음(이 환경 밖): {rel_path}")
                continue
            path = Path(mapped)
            if not path.exists():
                self.skipTest(f"실물 파일 없음: {path}")
                continue
            rc, data = score_json(path)
            with self.subTest(path=rel_path):
                self.assertEqual(rc, 0)
                self.assertIn(data["grade"], entry["expect_grade_in"], f"{rel_path}: grade={data['grade']}")


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestCompareGate(unittest.TestCase):
    """요구 3) compare 게이트 검증."""

    BEFORE = SIG_CORPUS_DIR / "ai_01_max.md"
    CLEANED = SIG_CORPUS_DIR / "ai_01_max.cleaned.md"
    WORSE = SIG_CORPUS_DIR / "ai_01_max.worse.md"

    def test_files_exist(self):
        for p in (self.BEFORE, self.CLEANED, self.WORSE):
            self.assertTrue(p.exists(), f"compare 게이트용 픽스처 없음: {p}")

    def test_cleaned_passes_exit0(self):
        rc, data = compare_json(self.BEFORE, self.CLEANED)
        self.assertEqual(rc, 0, f"장식만 제거한 윤문은 pass(exit 0) 여야 한다: {data}")
        self.assertEqual(data["verdict"], "pass")
        self.assertEqual(data["newly_triggered_actionable"], [])

    def test_identical_file_insufficient_exit1(self):
        rc, data = compare_json(self.BEFORE, self.BEFORE)
        self.assertEqual(rc, 1, f"변화 없는 윤문은 insufficient(exit 1) 여야 한다: {data}")
        self.assertEqual(data["verdict"], "insufficient")

    def test_worse_regressed_exit2(self):
        rc, data = compare_json(self.BEFORE, self.WORSE)
        self.assertEqual(rc, 2, f"이모지를 늘린 나쁜 윤문은 regressed(exit 2) 여야 한다: {data}")
        self.assertEqual(data["verdict"], "regressed")

    def test_structure_preserved_in_cleaned(self):
        """'장식만 제거, 구조는 보존' 정책 - cleaned 파일도 불릿/표/헤딩 개수가 유지돼야 한다."""
        before_text = self.BEFORE.read_text(encoding="utf-8")
        cleaned_text = self.CLEANED.read_text(encoding="utf-8")
        # 표 행(헤더 구분선 "|---|" 포함) 개수는 그대로 보존돼야 한다.
        self.assertEqual(before_text.count("|---|"), cleaned_text.count("|---|"))
        # 헤딩(##) 개수는 정리 섹션 삭제로 하나 줄어드는 것이 정상(장식 제거 정책의 일부).
        before_h2 = sum(1 for ln in before_text.splitlines() if ln.startswith("## "))
        cleaned_h2 = sum(1 for ln in cleaned_text.splitlines() if ln.startswith("## "))
        self.assertLessEqual(cleaned_h2, before_h2)
        self.assertGreaterEqual(cleaned_h2, before_h2 - 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
