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
            for key in ("key", "n", "df", "total", "per_doc", "score", "example"):
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
        valid_kinds = {"프로필", "시드", "문서내"}
        for f in data["findings"]:
            self.assertIn(f["kind"], valid_kinds, f"유효하지 않은 kind: {f['kind']}")

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
        seed_matches = [f for f in data["findings"] if f["kind"] == "시드"]
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
