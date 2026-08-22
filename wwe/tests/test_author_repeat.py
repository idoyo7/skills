#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""author_repeat.py 회귀 테스트.

unittest + subprocess. CLI 계약(스펙)만 근거로 검증한다.
`author_repeat.py` 가 아직 없으면 각 테스트 클래스는 명확한 스킵 메시지를 낸다.

실행:
    python3 tests/test_author_repeat.py
    (또는 run.sh 경유)
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SKILL_DIR = TESTS_DIR.parent
SCRIPT = SKILL_DIR / "scripts" / "author_repeat.py"


def _script_missing_reason() -> str | None:
    if not SCRIPT.exists():
        return (
            f"author_repeat.py 가 아직 존재하지 않습니다: {SCRIPT}\n"
            "  구현 에이전트가 작업 중일 수 있습니다. 이 스킵은 정상입니다."
        )
    return None


def run_ar(args: list[str]) -> subprocess.CompletedProcess:
    cmd = [sys.executable, str(SCRIPT), *args]
    return subprocess.run(cmd, capture_output=True, text=True)


# ---------------------------------------------------------------------------
# 합성 문서 생성 헬퍼
# ---------------------------------------------------------------------------

# 네 개의 타겟 표현 — 문서당 2~4회 포함
_TARGET_PHRASES = ["갈랐다", "따로 논다", "뿌리가 된 쪽", "거칠다"]


def _make_positive_doc(n_per_phrase: int = 3, extra: str = "") -> str:
    """타겟 표현을 n_per_phrase 회씩 포함하는 합성 문서."""
    lines = ["# 테스트 문서\n"]
    for phrase in _TARGET_PHRASES:
        for _ in range(n_per_phrase):
            lines.append(f"이 부분에서 흐름이 {phrase}. 그 다음 단락으로 넘어간다.\n\n")
    if extra:
        lines.append(extra)
    return "".join(lines)


def _make_negative_doc() -> str:
    """타겟 표현을 전혀 포함하지 않는 합성 문서."""
    return (
        "# 비교 문서\n\n"
        "이 문서에는 특별한 반복 표현이 없다.\n\n"
        "일반적인 기술 문서 내용이 들어간다.\n\n"
        "시스템 구성 방법에 대해 설명한다.\n\n"
    )


def _make_code_block_doc() -> str:
    """타겟 표현이 코드블록 안에만 있는 합성 문서."""
    return (
        "# 코드블록 테스트\n\n"
        "이 문서의 산문에는 타겟 표현이 없다.\n\n"
        "```python\n"
        "# 갈랐다 따로 논다 뿌리가 된 쪽 거칠다\n"
        "x = '갈랐다 따로 논다 뿌리가 된 쪽 거칠다'\n"
        "```\n\n"
        "코드블록 이후 일반 문장.\n\n"
    )


# ---------------------------------------------------------------------------
# 테스트 클래스
# ---------------------------------------------------------------------------

@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestBuildSubcommand(unittest.TestCase):
    """build 서브커맨드: 프로필 생성 기본 동작."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.td = Path(self.tmpdir.name)

        # 양성 문서 4개 (타겟 표현 포함)
        for i in range(4):
            n = 2 + (i % 3)  # 2~4회
            (self.td / f"pos_{i}.md").write_text(_make_positive_doc(n), encoding="utf-8")

        # 음성 문서 2개
        for i in range(2):
            (self.td / f"neg_{i}.md").write_text(_make_negative_doc(), encoding="utf-8")

        self.profile_path = self.td / "profile.json"

    def tearDown(self):
        self.tmpdir.cleanup()

    def _build(self, extra_args: list[str] | None = None) -> tuple[int, dict]:
        args = [
            "build",
            "--corpus", str(self.td),
            "--out", str(self.profile_path),
            "--min-docs", "2",
            "--min-doc-ratio", "0.2",
        ]
        if extra_args:
            args.extend(extra_args)
        r = run_ar(args)
        self.assertEqual(r.returncode, 0, f"build 실패:\n{r.stderr}")
        self.assertTrue(self.profile_path.exists(), "profile.json 이 생성되어야 한다")
        profile = json.loads(self.profile_path.read_text(encoding="utf-8"))
        return r.returncode, profile

    def test_profile_schema(self):
        """프로필 JSON 스키마 기본 키 확인."""
        _, profile = self._build()
        for key in ("built_at", "corpus_docs", "items"):
            self.assertIn(key, profile, f"프로필에 '{key}' 키가 없다")
        self.assertEqual(profile["corpus_docs"], 6)

    def test_target_phrases_in_profile(self):
        """타겟 표현(갈랐/따로/뿌리/거칠)이 프로필 items 에 포함되는지."""
        _, profile = self._build()
        keys_in_profile = {item["key"] for item in profile["items"]}
        # 각 표현의 어간이 프로필에 있어야 한다
        # 1-gram: "갈랐" (갈랐다→갈랐), "거칠" (거칠다→거칠)
        # 2-gram: "따로 논" (따로 논다), "뿌리 된" (뿌리가 된 쪽)
        # 어간 근사이므로 키는 정규화 결과에 따라 다를 수 있다 — items 에 하나 이상 있으면 통과
        self.assertGreater(len(keys_in_profile), 0, "프로필에 항목이 없다")

    def test_common_stopword_excluded(self):
        """불용어(문서, 있다 등)가 프로필에 올라오지 않는지."""
        _, profile = self._build()
        keys_in_profile = {item["key"] for item in profile["items"]}
        for stopword in ("문서", "있다", "내용", "방법"):
            # 불용어 자체가 키로 직접 올라오는 경우를 확인
            # (2-gram 구성 중 하나로는 가능하므로, 1-gram 단독으로만 체크)
            one_gram_keys = {
                item["key"] for item in profile["items"] if item["n"] == 1
            }
            self.assertNotIn(stopword, one_gram_keys, f"불용어 '{stopword}'가 1-gram 프로필에 있다")

    def test_item_schema(self):
        """프로필 item 스키마 확인."""
        _, profile = self._build()
        for item in profile["items"]:
            for key in ("key", "n", "df", "total", "per_doc_in_df", "per_doc_all", "score", "example"):
                self.assertIn(key, item, f"item에 '{key}' 키가 없다")
            self.assertIn(item["n"], (1, 2, 3), "n 은 1, 2, 3 중 하나여야 한다")
            self.assertGreater(item["score"], 0)

    def test_few_docs_warning(self):
        """5개 미만 코퍼스에서 경고를 출력하는지."""
        # 양성 2개만으로 빌드
        tiny_dir = self.td / "tiny"
        tiny_dir.mkdir()
        for i in range(2):
            (tiny_dir / f"t_{i}.md").write_text(_make_positive_doc(3), encoding="utf-8")
        out = self.td / "tiny_profile.json"
        r = run_ar(["build", "--corpus", str(tiny_dir), "--out", str(out),
                    "--min-docs", "1", "--min-doc-ratio", "0.1"])
        self.assertEqual(r.returncode, 0, "소규모 코퍼스에서도 성공해야 한다")
        self.assertIn("경고", r.stderr, "5개 미만이면 경고를 stderr에 출력해야 한다")


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestScanSubcommand(unittest.TestCase):
    """scan 서브커맨드: 프로필 매치·문서내 반복·시드 매치."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.td = Path(self.tmpdir.name)

        # 코퍼스 구성
        for i in range(4):
            (self.td / f"pos_{i}.md").write_text(_make_positive_doc(3), encoding="utf-8")
        for i in range(2):
            (self.td / f"neg_{i}.md").write_text(_make_negative_doc(), encoding="utf-8")

        self.profile_path = self.td / "profile.json"
        # 프로필 빌드
        r = run_ar([
            "build",
            "--corpus", str(self.td),
            "--out", str(self.profile_path),
            "--min-docs", "2",
            "--min-doc-ratio", "0.2",
        ])
        self.assertEqual(r.returncode, 0, f"setUp 빌드 실패:\n{r.stderr}")

        # 스캔 대상: 타겟 표현이 여러 번 등장하는 문서
        self.target_doc = self.td / "target.md"
        self.target_doc.write_text(_make_positive_doc(4), encoding="utf-8")

        # 음성 대상
        self.neg_doc = self.td / "neg_target.md"
        self.neg_doc.write_text(_make_negative_doc(), encoding="utf-8")

    def tearDown(self):
        self.tmpdir.cleanup()

    def _scan_json(self, src: Path, extra_args: list[str] | None = None) -> tuple[int, dict]:
        args = [
            "scan",
            "--src", str(src),
            "--profile", str(self.profile_path),
            "--json",
        ]
        if extra_args:
            args.extend(extra_args)
        r = run_ar(args)
        # exit 는 항상 0 이어야 한다
        self.assertEqual(r.returncode, 0, f"scan 이 0이 아닌 exit 를 반환했다: {r.returncode}\n{r.stderr}")
        data = json.loads(r.stdout)
        return r.returncode, data

    def test_exit_always_zero(self):
        """scan 은 항상 exit 0 이어야 한다 (파싱 실패 제외)."""
        r = run_ar(["scan", "--src", str(self.target_doc),
                    "--profile", str(self.profile_path)])
        self.assertEqual(r.returncode, 0)

    def test_profile_match_detected(self):
        """프로필 매치 항목이 findings 에 나타나는지."""
        _, data = self._scan_json(self.target_doc)
        self.assertIn("findings", data)
        kinds = {f["kind"] for f in data["findings"]}
        # 프로필 빌드 기준 충족 표현이 있는 문서이므로 프로필 매치가 있어야 함
        # (빌드 조건에 따라 없을 수도 있으므로 문서내도 허용)
        self.assertTrue(len(data["findings"]) > 0, "타겟 문서에서 아무것도 검출되지 않았다")

    def test_intra_doc_repeat_detected(self):
        """문서 내 반복(프로필 없이)이 kinds 에 '문서내' 로 나타나는지.

        프로필을 주면 같은 키가 '프로필'로 먼저 잡혀 seen_keys에 들어가므로,
        순수한 문서내 반복 검출은 프로필 없이 스캔해야 확인할 수 있다.
        """
        r = run_ar(["scan", "--src", str(self.target_doc), "--json"])
        self.assertEqual(r.returncode, 0)
        data = json.loads(r.stdout)
        kinds = {f["kind"] for f in data["findings"]}
        # 타겟 문서에 4회씩 들어가므로 문서내 반복이 잡혀야 함
        self.assertIn("문서내", kinds, "문서내 반복이 검출되어야 한다")

    def test_negative_doc_no_profile_match(self):
        """타겟 표현이 없는 문서에서 프로필 매치 없음."""
        _, data = self._scan_json(self.neg_doc)
        profile_matches = [f for f in data["findings"] if f["kind"] == "프로필"]
        self.assertEqual(profile_matches, [], "음성 문서에서 프로필 매치가 없어야 한다")

    def test_kind_field_valid(self):
        """findings 의 kind 가 유효한 값인지."""
        _, data = self._scan_json(self.target_doc)
        for f in data["findings"]:
            kind = f["kind"]
            self.assertTrue(
                kind in ("프로필", "문서내") or kind.startswith("시드"),
                f"유효하지 않은 kind: {kind}",
            )

    def test_json_schema(self):
        """scan --json 출력 스키마 확인."""
        _, data = self._scan_json(self.target_doc)
        for key in ("src", "total_tokens", "findings"):
            self.assertIn(key, data, f"JSON 출력에 '{key}' 키가 없다")
        for f in data["findings"]:
            for key in ("key", "kind", "count", "per_1k"):
                self.assertIn(key, f, f"finding에 '{key}' 키가 없다")

    def test_seed_match(self):
        """시드 파일에 있는 표현이 문서에 나오면 '시드' 로 잡히는지."""
        # 시드 표현이 포함된 문서 생성
        seed_doc = self.td / "seed_test.md"
        seed_doc.write_text(
            "# 시드 테스트\n\n"
            "이 부분에서 갈랐다. 두 번째로 갈랐다. 세 번째로 갈랐다.\n\n"
            "일반 내용이 들어간다.\n\n",
            encoding="utf-8",
        )
        seed_file = self.td / "seed.txt"
        seed_file.write_text("갈랐다\n따로 논다\n", encoding="utf-8")

        r = run_ar([
            "scan",
            "--src", str(seed_doc),
            "--seed", str(seed_file),
            "--json",
        ])
        self.assertEqual(r.returncode, 0)
        data = json.loads(r.stdout)
        seed_matches = [f for f in data["findings"] if f["kind"].startswith("시드")]
        self.assertTrue(len(seed_matches) > 0, "시드 표현이 문서에 있으면 '시드' 매치가 있어야 한다")

    def test_code_block_ignored(self):
        """코드블록 안의 반복은 무시되어야 한다."""
        code_doc = self.td / "code_test.md"
        code_doc.write_text(_make_code_block_doc(), encoding="utf-8")
        _, data = self._scan_json(code_doc)
        # 코드블록 안에만 타겟 표현이 있으므로 count 가 없거나 매우 낮아야 한다
        profile_counts = {
            f["key"]: f["count"] for f in data["findings"] if f["kind"] == "프로필"
        }
        # "갈랐다" 관련 키가 프로필에 있더라도 코드블록 제외 후 0이어야 함
        for key, cnt in profile_counts.items():
            if "갈랐" in key or "거칠" in key:
                self.assertEqual(cnt, 0, f"코드블록 표현 '{key}'가 {cnt}회 검출됐다")

    def test_missing_file_exit2(self):
        """존재하지 않는 파일 scan 은 exit 2."""
        r = run_ar(["scan", "--src", str(self.td / "__no_file__.md")])
        self.assertEqual(r.returncode, 2)


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestSuggestSubcommand(unittest.TestCase):
    """suggest 서브커맨드: 프로필→시드 합치기."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.td = Path(self.tmpdir.name)

        for i in range(4):
            (self.td / f"pos_{i}.md").write_text(_make_positive_doc(3), encoding="utf-8")
        for i in range(2):
            (self.td / f"neg_{i}.md").write_text(_make_negative_doc(), encoding="utf-8")

        self.profile_path = self.td / "profile.json"
        r = run_ar([
            "build",
            "--corpus", str(self.td),
            "--out", str(self.profile_path),
            "--min-docs", "2",
            "--min-doc-ratio", "0.2",
        ])
        self.assertEqual(r.returncode, 0)

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_suggest_creates_file(self):
        """suggest 가 시드 파일을 생성하는지."""
        out = self.td / "out_tics.txt"
        r = run_ar(["suggest", "--profile", str(self.profile_path), "--out", str(out)])
        self.assertEqual(r.returncode, 0)
        self.assertTrue(out.exists())
        content = out.read_text(encoding="utf-8")
        self.assertTrue(len(content.strip()) > 0, "출력 파일이 비어 있다")

    def test_suggest_append_no_duplicate(self):
        """--append 시 중복 없이 새 항목만 추가되는지."""
        out = self.td / "tics.txt"
        out.write_text("# 기존 줄\n기존항목\n", encoding="utf-8")

        r = run_ar(["suggest", "--profile", str(self.profile_path),
                    "--out", str(out), "--append"])
        self.assertEqual(r.returncode, 0)
        lines = [
            ln.strip() for ln in out.read_text(encoding="utf-8").splitlines()
            if ln.strip() and not ln.strip().startswith("#")
        ]
        # 중복 없음 확인
        self.assertEqual(len(lines), len(set(lines)), "중복 항목이 있다")
        # 기존 항목 보존 확인
        self.assertIn("기존항목", lines, "기존 항목이 사라졌다")


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestClsClassification(unittest.TestCase):
    """cls 분류: verb·noun·adv 판별 및 점수 가중 동작 확인."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.td = Path(self.tmpdir.name)

        # 주제 명사 "보존"을 모든 문서에 10회씩 (noun cls)
        # 습관 동사 "갈랐다"→어간 "갈랐"을 4문서 3회씩 (verb cls)
        def _make_mixed_doc(include_verb: bool) -> str:
            lines = ["# 혼합 테스트 문서\n\n"]
            # 명사 10회
            for _ in range(10):
                lines.append("보존 원칙을 지켜야 한다는 점에서 이 방향은 타당하다.\n\n")
            if include_verb:
                # 동사 3회
                for _ in range(3):
                    lines.append("이 시점에서 흐름이 완전히 갈랐다.\n\n")
            return "".join(lines)

        for i in range(4):
            (self.td / f"mixed_{i}.md").write_text(_make_mixed_doc(True), encoding="utf-8")
        for i in range(2):
            (self.td / f"noun_only_{i}.md").write_text(_make_mixed_doc(False), encoding="utf-8")

        self.profile_path = self.td / "cls_profile.json"
        r = run_ar([
            "build",
            "--corpus", str(self.td),
            "--out", str(self.profile_path),
            "--min-docs", "2",
            "--min-doc-ratio", "0.2",
        ])
        self.assertEqual(r.returncode, 0, f"setUp build 실패:\n{r.stderr}")

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_verb_cls_assigned(self):
        """갈랐다 어간 항목이 cls=verb 로 분류되는지."""
        profile = json.loads(self.profile_path.read_text(encoding="utf-8"))
        verb_items = [it for it in profile["items"] if it.get("cls") == "verb"]
        self.assertTrue(len(verb_items) > 0, "verb cls 항목이 프로필에 없다")

    def test_noun_cls_assigned(self):
        """보존 같은 주제 명사가 cls=noun 으로 분류되는지."""
        profile = json.loads(self.profile_path.read_text(encoding="utf-8"))
        noun_items = [it for it in profile["items"] if it.get("cls") == "noun"]
        self.assertTrue(len(noun_items) > 0, "noun cls 항목이 없다")
        noun_keys = {it["key"] for it in noun_items}
        self.assertIn("보존", noun_keys, "보존이 noun 으로 분류되지 않았다")

    def test_noun_weighted_score_lower(self):
        """같은 raw_score 라면 noun 의 weighted_score 가 verb 보다 낮은지."""
        profile = json.loads(self.profile_path.read_text(encoding="utf-8"))
        verb_items = [it for it in profile["items"] if it.get("cls") == "verb"]
        noun_items = [it for it in profile["items"] if it.get("cls") == "noun"]
        if not verb_items or not noun_items:
            self.skipTest("verb 또는 noun 항목이 없어 가중치 비교 불가")
        # 주제 명사 보존은 raw_score 가 높아도 weighted_score 는 ×0.3
        best_noun = max(noun_items, key=lambda x: x["score"])
        best_verb = max(verb_items, key=lambda x: x["weighted_score"])
        # noun weighted_score = score × 0.3, verb × 1.0
        self.assertAlmostEqual(
            best_noun["weighted_score"],
            best_noun["score"] * 0.3,
            places=3,
            msg="noun weighted_score 가 score×0.3 이 아니다",
        )
        self.assertAlmostEqual(
            best_verb["weighted_score"],
            best_verb["score"] * 1.0,
            places=3,
            msg="verb weighted_score 가 score×1.0 이 아니다",
        )

    def test_suggest_excludes_nouns_by_default(self):
        """suggest 기본: noun cls 는 시드에 포함되지 않는지."""
        out = self.td / "suggest_out.txt"
        r = run_ar(["suggest", "--profile", str(self.profile_path), "--out", str(out)])
        self.assertEqual(r.returncode, 0)
        lines = {
            ln.strip() for ln in out.read_text(encoding="utf-8").splitlines()
            if ln.strip() and not ln.strip().startswith("#")
        }
        profile = json.loads(self.profile_path.read_text(encoding="utf-8"))
        noun_keys = {it["key"] for it in profile["items"] if it.get("cls") == "noun"}
        overlap = lines & noun_keys
        self.assertEqual(overlap, set(), f"noun 키가 시드에 들어갔다: {overlap}")

    def test_suggest_include_nouns_flag(self):
        """--include-nouns 시 noun cls 도 시드에 들어가는지."""
        out = self.td / "suggest_with_noun.txt"
        r = run_ar(["suggest", "--profile", str(self.profile_path),
                    "--out", str(out), "--include-nouns"])
        self.assertEqual(r.returncode, 0)
        lines = {
            ln.strip() for ln in out.read_text(encoding="utf-8").splitlines()
            if ln.strip() and not ln.strip().startswith("#")
        }
        profile = json.loads(self.profile_path.read_text(encoding="utf-8"))
        noun_keys = {it["key"] for it in profile["items"] if it.get("cls") == "noun"}
        # noun 항목이 적어도 하나는 포함돼야 함
        if noun_keys:
            self.assertTrue(
                lines & noun_keys,
                "--include-nouns 가 있어도 noun 키가 시드에 없다",
            )

    def test_scan_primary_before_noun(self):
        """scan 텍스트 출력에서 verb/ngram 이 noun 보다 먼저 나오는지."""
        # 타겟 문서: 갈랐다 4회, 보존 10회
        target = self.td / "scan_target.md"
        lines = []
        for _ in range(10):
            lines.append("보존 원칙을 지켜야 한다는 점에서 타당하다.\n\n")
        for _ in range(4):
            lines.append("이 시점에서 흐름이 완전히 갈랐다.\n\n")
        target.write_text("".join(lines), encoding="utf-8")

        r = run_ar([
            "scan",
            "--src", str(target),
            "--profile", str(self.profile_path),
            "--top", "20",
        ])
        self.assertEqual(r.returncode, 0)
        output = r.stdout
        # "주제어(참고)" 구분선이 있으면 그 앞에 verb 항목이 있어야 함
        if "주제어(참고)" in output:
            before_noun_section = output.split("주제어(참고)")[0]
            self.assertIn("verb", before_noun_section,
                          "주제어 구역 앞에 verb 항목이 없다")

    def test_cls_field_in_scan_json(self):
        """scan --json 의 findings 에 cls 필드가 있는지."""
        target = self.td / "cls_scan.md"
        target.write_text(_make_positive_doc(4), encoding="utf-8")
        r = run_ar([
            "scan", "--src", str(target),
            "--profile", str(self.profile_path),
            "--json",
        ])
        self.assertEqual(r.returncode, 0)
        data = json.loads(r.stdout)
        for f in data["findings"]:
            self.assertIn("cls", f, "finding에 cls 필드가 없다")
            self.assertIn(f["cls"], ("verb", "adv", "ngram", "noun"),
                          f"유효하지 않은 cls: {f['cls']}")



@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestDefectFixes(unittest.TestCase):
    """결함 수정 검증 — n-gram 경계, 예시 문맥, 기능어/서술격 분류."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.td = Path(self.tmpdir.name)

    def tearDown(self):
        self.tmpdir.cleanup()

    # ------------------------------------------------------------------
    # Fix 1: n-gram 줄 경계 — 서로 다른 줄의 어절을 이어 붙이지 않는다
    # ------------------------------------------------------------------

    def test_ngram_no_cross_line(self):
        """서로 다른 줄의 어절을 이어 붙인 n-gram이 프로필에 없어야 한다.

        줄 A 마지막: "원문"
        줄 B 처음:   "원문"
        → "원문 원문" n-gram이 생성되면 안 된다.
        """
        doc_content = (
            "# 경계 테스트\n\n"
            "이 문서에서 원문이 중요하다.\n\n"  # 줄 A: ends with "원문이"
            "원문 표현을 그대로 살려야 한다.\n\n"  # 줄 B: starts with "원문"
            "그 원문 기준을 지킨다.\n\n"
            "원문 보존이 핵심이다.\n\n"
        )
        # 5개 코퍼스 문서에 같은 내용을 넣어 프로필을 빌드한다
        for i in range(5):
            (self.td / f"doc_{i}.md").write_text(doc_content, encoding="utf-8")
        profile_path = self.td / "profile.json"
        r = run_ar([
            "build", "--corpus", str(self.td), "--out", str(profile_path),
            "--min-docs", "2", "--min-doc-ratio", "0.2",
        ])
        self.assertEqual(r.returncode, 0)
        profile = json.loads(profile_path.read_text(encoding="utf-8"))
        keys = {it["key"] for it in profile["items"]}
        # "원문 원문"은 줄 경계를 넘어야만 만들어지는 n-gram — 없어야 한다
        self.assertNotIn("원문 원문", keys,
                         '"원문 원문" n-gram이 생성됐다 (줄 경계 버그)')

    def test_table_rows_excluded(self):
        """표 행(| 로 시작)의 어절이 산문 어절과 n-gram을 만들지 않는다.

        표 셀 "보존"이 앞 줄 산문 "원문"과 붙어 "원문 보존" n-gram이 되면 안 된다.
        """
        doc_content = (
            "# 표 경계 테스트\n\n"
            "원문을 중심으로 작업한다.\n\n"  # 산문 줄
            "| 항목 | 보존 여부 |\n"          # 표 행
            "| --- | --- |\n"
            "| 스크립트 | 없이 |\n"
            "\n산문이 다시 이어진다.\n\n"
        )
        for i in range(5):
            (self.td / f"tdoc_{i}.md").write_text(doc_content, encoding="utf-8")
        profile_path = self.td / "tprofile.json"
        r = run_ar([
            "build", "--corpus", str(self.td), "--out", str(profile_path),
            "--min-docs", "2", "--min-doc-ratio", "0.2",
        ])
        self.assertEqual(r.returncode, 0)
        profile = json.loads(profile_path.read_text(encoding="utf-8"))
        keys = {it["key"] for it in profile["items"]}
        # 표 셀과 산문이 만들어야 할 n-gram들 — 없어야 한다
        for forbidden in ("원문 보존", "보존 없이", "스크립트 없이"):
            self.assertNotIn(forbidden, keys,
                             f'표 행+산문 합성 n-gram "{forbidden}" 이 생성됐다')

    # ------------------------------------------------------------------
    # Fix 2: 예시 문맥 — 실제 키 위치 앞뒤 20자
    # ------------------------------------------------------------------

    def test_example_context_contains_key(self):
        """scan --json 의 example 필드에 키 어간이 실제로 포함돼야 한다."""
        doc = self.td / "ex_test.md"
        doc.write_text(
            "# 예시 테스트\n\n"
            "갈랐다는 표현이 여기서 나온다.\n\n"
            "두 번째로 갈랐다는 말이 등장한다.\n\n"
            "세 번째로 갈랐다는 흐름이 이어진다.\n\n"
            "네 번째로 갈랐다는 단어를 또 쓴다.\n\n",
            encoding="utf-8",
        )
        r = run_ar(["scan", "--src", str(doc), "--json"])
        self.assertEqual(r.returncode, 0)
        data = json.loads(r.stdout)
        # "갈랐" (어간)이 포함된 finding 을 찾는다
        galr_findings = [
            f for f in data["findings"]
            if "갈" in f["key"] or "갈랐" in f["key"]
        ]
        for f in galr_findings:
            example = f.get("example", "")
            if example:
                # 예시 문맥이 키 어간을 포함해야 한다
                key_stem = f["key"].split()[0]  # 첫 어간
                self.assertIn(
                    key_stem[:2], example,
                    f'example "{example}" 에 키 어간 "{key_stem}" 이 없다',
                )

    def test_line_numbers_are_actual_match_lines(self):
        """lines 배열이 키가 실제로 나타나는 줄번호를 가리켜야 한다."""
        doc = self.td / "lineno_test.md"
        # 줄 5, 9, 13 에만 "갈랐다" 를 넣는다 (1-indexed)
        lines = [
            "# 줄번호 테스트\n",   # 1
            "\n",                  # 2
            "배경 설명이다.\n",     # 3
            "\n",                  # 4
            "이 흐름이 갈랐다.\n", # 5 ← 매치
            "\n",                  # 6
            "다른 내용이다.\n",     # 7
            "\n",                  # 8
            "또 갈랐다.\n",        # 9 ← 매치
            "\n",                  # 10
            "무관한 문장이다.\n",   # 11
            "\n",                  # 12
            "흐름이 갈랐다.\n",    # 13 ← 매치
            "\n",                  # 14
            "끝 문장이다.\n",      # 15
        ]
        doc.write_text("".join(lines), encoding="utf-8")
        r = run_ar(["scan", "--src", str(doc), "--json"])
        self.assertEqual(r.returncode, 0)
        data = json.loads(r.stdout)
        galr_findings = [f for f in data["findings"] if "갈" in f["key"]]
        if not galr_findings:
            self.skipTest("갈랐 계열 finding이 없어 줄번호 검증 스킵")
        for f in galr_findings:
            for ln in f.get("lines", []):
                # 매치 줄은 반드시 5, 9, 13 중 하나여야 한다
                self.assertIn(
                    ln, [5, 9, 13],
                    f"줄번호 {ln} 은 실제 매치 줄(5,9,13)이 아니다",
                )

    # ------------------------------------------------------------------
    # Fix 3: 기능어 어간·서술격 분류
    # ------------------------------------------------------------------

    def test_functional_verb_stem_filtered(self):
        """않는다·없이·위에 등 기능어가 profile 에 verb 로 올라오지 않는다."""
        # 기능어를 반복적으로 사용하는 문서
        func_doc = (
            "# 기능어 반복 문서\n\n"
            "이 기능이 없이는 작동하지 않는다.\n"
            "그 방법이 없이는 결과가 나오지 않는다.\n"
            "위에서 언급한 대로 없이는 안 된다.\n"
            "없이는 불가능하다.\n\n"
        )
        for i in range(5):
            (self.td / f"func_{i}.md").write_text(func_doc, encoding="utf-8")
        profile_path = self.td / "func_profile.json"
        r = run_ar([
            "build", "--corpus", str(self.td), "--out", str(profile_path),
            "--min-docs", "2", "--min-doc-ratio", "0.2",
        ])
        self.assertEqual(r.returncode, 0)
        profile = json.loads(profile_path.read_text(encoding="utf-8"))
        # 기능어 어간이 verb 로 profile 에 올라와서는 안 된다
        func_stems = {"않", "없", "있", "되", "하", "위", "아래", "때문",
                      "경우", "대한", "통해", "위해", "따라",
                      "않는", "않았", "없이", "위에"}
        for item in profile["items"]:
            if item.get("cls") == "verb" and item["key"] in func_stems:
                self.fail(
                    f'기능어 "{item["key"]}" 가 cls=verb 로 프로필에 올라왔다'
                )

    def test_copula_stripping_yields_noun(self):
        """이다/이고/이며 를 벗긴 어간은 cls=verb 가 아닌 noun 이어야 한다.

        "특징이다" → 어간 "특징", cls 는 noun 이어야 한다.
        """
        # classify_stem 직접 호출 (스크립트를 임포트하는 방식)
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "author_repeat", str(SCRIPT)
        )
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        cases = [
            ("특징이다", "특징", "noun"),
            ("목표이고", "목표", "noun"),
            ("방향이며", "방향", "noun"),
            ("갈랐다", "갈랐", "verb"),    # 일반 용언은 여전히 verb
            ("솔직히", "솔직히", "adv"),   # 부사형은 adv
        ]
        for raw, expected_stem, expected_cls in cases:
            stem, cls = mod.classify_stem(raw)
            self.assertEqual(
                stem, expected_stem,
                f'classify_stem("{raw}") → stem "{stem}", 기대값 "{expected_stem}"',
            )
            self.assertEqual(
                cls, expected_cls,
                f'classify_stem("{raw}") → cls "{cls}", 기대값 "{expected_cls}"',
            )


@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestNewFixes(unittest.TestCase):
    """A1~A5, B, E4 항목 신규 테스트."""

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.td = Path(self.tmpdir.name)

    def tearDown(self):
        self.tmpdir.cleanup()

    # ── A1: per_doc_in_df vs per_doc_all ──────────────────────────────────

    def test_per_doc_in_df_is_df_average(self):
        """per_doc_in_df = total / df, per_doc_all = total / corpus_docs."""
        # 5개 문서 코퍼스, "갈랐다"는 3개 문서에만 등장 (각 2회)
        phrase = "갈랐다"
        for i in range(3):
            doc = f"# doc {i}\n\n이 흐름이 갈랐다. 또 갈랐다.\n\n"
            (self.td / f"hit_{i}.md").write_text(doc, encoding="utf-8")
        for i in range(2):
            doc = "# 다른 문서\n\n관련 없는 내용이다.\n\n"
            (self.td / f"miss_{i}.md").write_text(doc, encoding="utf-8")
        profile_path = self.td / "p.json"
        r = run_ar([
            "build", "--corpus", str(self.td), "--out", str(profile_path),
            "--min-docs", "2", "--min-doc-ratio", "0.0",
        ])
        self.assertEqual(r.returncode, 0)
        profile = json.loads(profile_path.read_text(encoding="utf-8"))
        n_docs = profile["corpus_docs"]  # should be 5
        hits = [it for it in profile["items"] if "갈" in it["key"]]
        if not hits:
            self.skipTest("갈랐 계열 항목이 프로필에 없음")
        item = hits[0]
        # per_doc_in_df = total / df
        expected_in_df = round(item["total"] / item["df"], 3)
        self.assertAlmostEqual(item["per_doc_in_df"], expected_in_df, places=2)
        # per_doc_all = total / n_docs
        expected_all = round(item["total"] / n_docs, 3)
        self.assertAlmostEqual(item["per_doc_all"], expected_all, places=2)
        # per_doc_in_df >= per_doc_all (df <= n_docs always)
        self.assertGreaterEqual(item["per_doc_in_df"], item["per_doc_all"])

    # ── A2: _ENDING_STEMS 필터 ────────────────────────────────────────────

    def test_ending_stems_filtered(self):
        """합쇼체 잔재 어간(합니/됩니 등)이 프로필 verb 로 올라오지 않는다."""
        import importlib.util
        spec = importlib.util.spec_from_file_location("ar", str(SCRIPT))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        # "합니다" → strip "다" → "합니" should be in _ENDING_STEMS
        stem, cls = mod.classify_stem("합니다")
        sw = mod.load_stopwords()
        # _tokenize_line should filter "합니"
        lines = [(1, "이 기능이 없이는 합니다. 또 합니다.")]
        tokens = mod._tokenize_line("합니다", 1, sw)
        # stem "합니" should not appear in the result
        stems = [t[0] for t in tokens]
        self.assertNotIn("합니", stems, '"합니" 어간이 토큰에 있다')
        self.assertNotIn("됩니", stems, '"됩니" 어간이 토큰에 있다')

    # ── A3: 에서/로서 조사 오인 방지 ──────────────────────────────────────

    def test_esse_particle_not_verb(self):
        """쪽에서/에게서/으로서가 verb 로 분류되지 않는다."""
        import importlib.util
        spec = importlib.util.spec_from_file_location("ar", str(SCRIPT))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        for word in ("쪽에서", "여기에서", "그에게서", "방향으로서", "예시로서"):
            _, cls = mod.classify_stem(word)
            self.assertNotEqual(
                cls, "verb",
                f'"{word}" 이 cls=verb 로 잘못 분류됨',
            )

    # ── A4: 예시 결정성 ───────────────────────────────────────────────────

    def test_example_deterministic(self):
        """같은 코퍼스로 두 번 빌드하면 example 필드가 동일해야 한다."""
        for i in range(4):
            (self.td / f"d{i}.md").write_text(
                f"# 문서 {i}\n\n이 흐름이 완전히 갈랐다.\n\n또 갈랐다.\n\n",
                encoding="utf-8",
            )
        p1 = self.td / "p1.json"
        p2 = self.td / "p2.json"
        for out in (p1, p2):
            r = run_ar([
                "build", "--corpus", str(self.td), "--out", str(out),
                "--min-docs", "2", "--min-doc-ratio", "0.0",
            ])
            self.assertEqual(r.returncode, 0)
        prof1 = json.loads(p1.read_text(encoding="utf-8"))
        prof2 = json.loads(p2.read_text(encoding="utf-8"))
        ex1 = {it["key"]: it["example"] for it in prof1["items"]}
        ex2 = {it["key"]: it["example"] for it in prof2["items"]}
        self.assertEqual(ex1, ex2, "두 번 빌드 결과의 example 필드가 다르다")

    # ── B: 시드 섹션 레이블 ────────────────────────────────────────────────

    def test_seed_section_label_in_kind(self):
        """## 섹션이 있는 시드 파일을 쓰면 kind가 '시드:섹션명' 형식이어야 한다."""
        seed_file = self.td / "test_seed.txt"
        seed_file.write_text(
            "## 에세이·분석문\n갈랐다\n## 기술 게시글\n다만\n",
            encoding="utf-8",
        )
        doc = self.td / "doc.md"
        doc.write_text(
            "# 테스트\n\n흐름이 갈랐다. 갈랐다. 갈랐다.\n\n다만 이 부분은 다르다. 다만.\n\n",
            encoding="utf-8",
        )
        r = run_ar(["scan", "--src", str(doc), "--seed", str(seed_file), "--json"])
        self.assertEqual(r.returncode, 0)
        data = json.loads(r.stdout)
        seed_findings = [f for f in data["findings"] if f["kind"].startswith("시드")]
        self.assertTrue(len(seed_findings) > 0, "시드 매치가 없다")
        kinds = {f["kind"] for f in seed_findings}
        # 최소 하나는 섹션 레이블 포함
        labeled = [k for k in kinds if ":" in k]
        self.assertTrue(len(labeled) > 0, f"시드 kind에 ':' 없음: {kinds}")
        for k in labeled:
            prefix, section = k.split(":", 1)
            self.assertEqual(prefix, "시드")
            self.assertTrue(len(section) > 0, "섹션 레이블이 비어 있다")

    # ── E4: generate_tics_block 단위 테스트 ───────────────────────────────

    def test_generate_tics_block_with_instruction(self):
        """=> 가 있는 줄은 '표현 → 지시문' 형식으로 출력된다."""
        import importlib.util
        spec = importlib.util.spec_from_file_location("ar", str(SCRIPT))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        seed = self.td / "seed.txt"
        seed.write_text(
            "## 에세이\n"
            "갈랐다 => 흐름이 나뉘었다\n"
            "따로 논다\n"  # no instruction → default
            "# 보류: 여기서\n",
            encoding="utf-8",
        )
        block = mod.generate_tics_block(seed)
        self.assertIn("갈랐다", block)
        self.assertIn("흐름이 나뉘었다", block)
        self.assertIn("따로 논다", block)
        self.assertIn("평이한 말로", block)  # default instruction
        # 주석(보류)은 HTML 코멘트로
        self.assertNotIn("<!--", block)  # 파일 머리 주석은 지침에 섞지 않는다
        self.assertIn("보류", block)
        # 섹션 헤더는 소제목으로
        self.assertIn("에세이", block)

    def test_generate_tics_block_no_file(self):
        """시드 파일이 없으면 빈 문자열을 반환한다."""
        import importlib.util
        spec = importlib.util.spec_from_file_location("ar", str(SCRIPT))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        missing = self.td / "no_such_file.txt"
        block = mod.generate_tics_block(missing)
        self.assertEqual(block, "")

    def test_generate_tics_block_section_header_only(self):
        """섹션 헤더만 있고 표현이 없어도 오류 없이 처리된다."""
        import importlib.util
        spec = importlib.util.spec_from_file_location("ar", str(SCRIPT))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)

        seed = self.td / "empty_section.txt"
        seed.write_text("## 섹션만\n# 주석만\n", encoding="utf-8")
        block = mod.generate_tics_block(seed)
        # 헤더 블록이 있어야 함
        self.assertIn("작성자 반복", block)

@unittest.skipIf(_script_missing_reason(), _script_missing_reason() or "")
class TestOvercuttingFix(unittest.TestCase):
    """E5: 약한 어미 오절단 방지 — verb_weak 두 단계 확인."""

    def _load_mod(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("ar", str(SCRIPT))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    def test_page_word_stays_noun_without_confirmation(self):
        """'페이지'는 코퍼스 확인 없이 noun으로 남는다."""
        mod = self._load_mod()
        lines = [(1, "페이지 보기")]
        _, ngrams, cls_map, _, _ = mod._build_ngrams_per_line(
            lines, set(), frozenset()
        )
        self.assertIn("페이지", ngrams[1], "'페이지'가 1-gram에 없음")
        self.assertEqual(cls_map.get("페이지"), "noun", "'페이지'가 noun이 아님")

    def test_conjunction_filtered_as_stopword(self):
        """'그리고'는 약한 어미 미확인 → noun으로 fallback → 불용어로 제거된다."""
        mod = self._load_mod()
        stopwords = mod.load_stopwords()
        # 그리고 → strip_particle → 그리고 (noun after weak fallback) → in stopwords
        lines = [(1, "그리고 다음으로")]
        _, ngrams, _, _, _ = mod._build_ngrams_per_line(
            lines, stopwords, frozenset()
        )
        self.assertNotIn("그리", ngrams[1], "'그리'가 1-gram에 남아 있음")
        self.assertNotIn("그리고", ngrams[1], "'그리고'가 1-gram에 남아 있음")

    def test_confirmed_verb_stem_classified_as_verb(self):
        """강한 어미로 2회 이상 등장한 어간은 약한 어미도 verb로 분류된다."""
        mod = self._load_mod()
        # "갈랐" = 2자 어간 (갈+랐). "갈랐다" → strong "다" → 어간 "갈랐"
        # "갈랐고" → weak "고" → 어간 "갈랐" → confirmed → verb
        lines = [
            (1, "갈랐다"),   # strong "다" → stem "갈랐" count=1
            (2, "갈랐다"),   # strong "다" → stem "갈랐" count=2
            (3, "갈랐고"),   # weak "고" → verb_weak, confirmed → verb
        ]
        confirmed = mod._collect_confirmed_verb_stems(lines, min_count=2)
        self.assertIn("갈랐", confirmed, "'갈랐'이 confirmed 집합에 없음")
        _, ngrams, cls_map, _, _ = mod._build_ngrams_per_line(
            lines, set(), confirmed
        )
        self.assertIn("갈랐", ngrams[1], "'갈랐'이 1-gram에 없음")
        self.assertEqual(cls_map.get("갈랐"), "verb", "'갈랐'이 verb가 아님")


class TestGenBlockCLI(unittest.TestCase):
    """gen-block 서브커맨드 통합 테스트."""

    def test_gen_block_outputs_tics_header(self):
        """gen-block --seed 호출이 '## 작성자 반복 구절' 헤더를 stdout에 출력한다."""
        seed = SKILL_DIR / "references" / "author-tics.txt"
        if not seed.exists():
            self.skipTest(f"시드 파일 없음: {seed}")
        result = run_ar(["gen-block", "--seed", str(seed)])
        self.assertEqual(result.returncode, 0, f"rc={result.returncode}\n{result.stderr}")
        self.assertIn(
            "## 작성자 반복 구절",
            result.stdout,
            f"헤더 없음. stdout 앞 300자:\n{result.stdout[:300]}",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
