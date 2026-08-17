#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
md_shield.py 에 대한 적대적 테스트 하네스.

주의: 이 파일은 md_shield.py 의 구현을 임포트하지 않는다. 오직 CLI 계약(공유 계약 문서)에만
근거해서 subprocess 로 실행 파일을 호출하고 결과를 검증한다. 구현이 아직 없거나 미완성이면
각 테스트 클래스는 크래시 대신 명확한 스킵 메시지를 내야 한다.

실행:
    python3 tests/test_md_shield.py
    (또는 run.sh 경유)
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# ---------------------------------------------------------------------------
# 경로 상수
# ---------------------------------------------------------------------------

TESTS_DIR = Path(__file__).resolve().parent
SKILL_DIR = TESTS_DIR.parent
CORPUS_DIR = TESTS_DIR / "corpus"
SCRIPT = SKILL_DIR / "scripts" / "md_shield.py"

TOKEN_RE = re.compile(r"⟦HZ-([BI])(\d+)⟧")
CONFLICT_MARKER = "⟦HZ-B0001⟧"


def _script_missing_reason():
    """md_shield.py 가 없으면 스킵 사유 문자열을, 있으면 None 을 반환한다."""
    if not SCRIPT.exists():
        return (
            f"md_shield.py 가 아직 존재하지 않습니다: {SCRIPT}\n"
            "  구현 에이전트가 작업 중일 수 있습니다. 이 스킵은 정상입니다 — "
            "구현이 도착하면 같은 명령으로 다시 실행하세요."
        )
    return None


def corpus_files():
    """corpus/ 아래 .md 파일들을 이름순으로 반환한다."""
    if not CORPUS_DIR.exists():
        return []
    return sorted(CORPUS_DIR.glob("*.md"))


def run_shield(args, cwd=None):
    """md_shield.py 를 subprocess 로 실행한다."""
    cmd = [sys.executable, str(SCRIPT), *args]
    return subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)


def parse_json_report(proc):
    """stdout 마지막 줄을 JSON 으로 파싱한다. 실패하면 None."""
    if not proc.stdout:
        return None
    lines = [l for l in proc.stdout.splitlines() if l.strip()]
    if not lines:
        return None
    try:
        return json.loads(lines[-1])
    except json.JSONDecodeError:
        return None


def proc_debug(proc, label=""):
    """실패 메시지에 붙일 subprocess 결과 요약."""
    return (
        f"[{label}] returncode={proc.returncode}\n"
        f"  stdout(tail 500)={proc.stdout[-500:]!r}\n"
        f"  stderr(tail 500)={proc.stderr[-500:]!r}"
    )


def do_mask(src: Path, workdir: Path, profile="docs", extra_args=None):
    prose = workdir / (src.stem + ".prose.txt")
    map_path = workdir / (src.stem + ".map.json")
    args = [
        "mask",
        "--src", str(src),
        "--out-prose", str(prose),
        "--out-map", str(map_path),
        "--profile", profile,
        "--json",
    ]
    if extra_args:
        args += extra_args
    proc = run_shield(args)
    return proc, prose, map_path


def do_restore(prose: Path, map_path: Path, out: Path, extra_args=None):
    args = [
        "restore",
        "--prose", str(prose),
        "--map", str(map_path),
        "--out", str(out),
        "--json",
    ]
    if extra_args:
        args += extra_args
    proc = run_shield(args)
    return proc


def do_verify(src: Path, restored: Path, map_path: Path, extra_args=None):
    args = [
        "verify",
        "--src", str(src),
        "--restored", str(restored),
        "--map", str(map_path),
        "--json",
    ]
    if extra_args:
        args += extra_args
    proc = run_shield(args)
    return proc


def byte_diff_report(a: bytes, b: bytes, name: str) -> str:
    """원본(a)과 복원본(b)이 다를 때, 사람이 바로 알 수 있게 첫 차이 지점을 보여준다."""
    minlen = min(len(a), len(b))
    offset = None
    for i in range(minlen):
        if a[i] != b[i]:
            offset = i
            break
    if offset is None:
        offset = minlen  # 길이만 다른 경우
    start = max(0, offset - 30)
    a_ctx = a[start:offset + 30]
    b_ctx = b[start:offset + 30]

    def safe(bs):
        return bs.decode("utf-8", errors="replace")

    return (
        f"[IDENTITY 위반] {name}\n"
        f"  원본 길이={len(a)} bytes, 복원본 길이={len(b)} bytes\n"
        f"  첫 차이 offset={offset}\n"
        f"  원본   근처: {safe(a_ctx)!r}\n"
        f"  복원본 근처: {safe(b_ctx)!r}"
    )


def load_map(map_path: Path):
    with open(map_path, encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# 스킵 가능한 베이스 클래스
# ---------------------------------------------------------------------------

class ShieldTestCase(unittest.TestCase):
    """md_shield.py 가 없으면 명확한 사유로 전체 클래스를 스킵한다."""

    @classmethod
    def setUpClass(cls):
        reason = _script_missing_reason()
        if reason:
            raise unittest.SkipTest(reason)
        if not corpus_files():
            raise unittest.SkipTest(
                f"코퍼스 파일이 없습니다: {CORPUS_DIR} — tests/corpus/*.md 를 먼저 준비하세요."
            )

    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="mdshield_test_")

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    @property
    def workdir(self) -> Path:
        return Path(self._tmp)


# ---------------------------------------------------------------------------
# T1 — IDENTITY (가장 중요)
# ---------------------------------------------------------------------------

class T1_Identity(ShieldTestCase):
    """mask -> 산문 무수정 -> restore == 원본 (바이트 단위)."""

    def test_identity_roundtrip_all_corpus(self):
        failures = []
        for src in corpus_files():
            with self.subTest(file=src.name):
                wd = self.workdir / src.stem
                wd.mkdir(parents=True, exist_ok=True)

                mask_proc, prose, map_path = do_mask(src, wd)
                if mask_proc.returncode != 0:
                    failures.append(
                        f"{src.name}: mask 가 실패했습니다 (기대: 0).\n{proc_debug(mask_proc, 'mask')}"
                    )
                    continue

                restored = wd / "restored.md"
                restore_proc = do_restore(prose, map_path, restored)
                if restore_proc.returncode != 0:
                    failures.append(
                        f"{src.name}: restore 가 실패했습니다 (기대: 0).\n{proc_debug(restore_proc, 'restore')}"
                    )
                    continue

                src_bytes = src.read_bytes()
                restored_bytes = restored.read_bytes()
                if src_bytes != restored_bytes:
                    failures.append(byte_diff_report(src_bytes, restored_bytes, src.name))

        if failures:
            self.fail(
                f"\n\nIDENTITY 위반 {len(failures)}건 (전체 {len(corpus_files())}개 중):\n\n"
                + "\n\n".join(failures)
            )


# ---------------------------------------------------------------------------
# T9 — CRLF / 끝개행 없음 보존 (11번 코퍼스 특화)
# ---------------------------------------------------------------------------

class T9_CRLFAndNoTrailingNewline(ShieldTestCase):
    TARGET = "11_edge_whitespace.md"

    def test_crlf_and_missing_trailing_newline_preserved(self):
        src = CORPUS_DIR / self.TARGET
        if not src.exists():
            self.skipTest(f"{self.TARGET} 코퍼스 파일이 없습니다.")

        src_bytes = src.read_bytes()
        self.assertIn(b"\r\n", src_bytes, "코퍼스 픽스처 자체에 CRLF 가 없습니다 (테스트 픽스처 버그).")
        self.assertFalse(src_bytes.endswith(b"\n"), "코퍼스 픽스처 자체가 끝개행을 갖고 있습니다 (테스트 픽스처 버그).")

        wd = self.workdir
        mask_proc, prose, map_path = do_mask(src, wd)
        self.assertEqual(mask_proc.returncode, 0, proc_debug(mask_proc, "mask"))

        restored = wd / "restored.md"
        restore_proc = do_restore(prose, map_path, restored)
        self.assertEqual(restore_proc.returncode, 0, proc_debug(restore_proc, "restore"))

        restored_bytes = restored.read_bytes()
        self.assertEqual(
            restored_bytes, src_bytes,
            byte_diff_report(src_bytes, restored_bytes, self.TARGET),
        )
        self.assertIn(b"\r\n", restored_bytes, "복원본에서 CRLF 가 LF 로 정규화됐습니다 — 개행 정규화 금지 규칙 위반.")
        self.assertFalse(
            restored_bytes.endswith(b"\n"),
            "원본은 끝개행이 없는데 복원본에는 끝개행이 생겼습니다.",
        )


# ---------------------------------------------------------------------------
# T2 — 코드 불가침 (산문에 코드 조각이 한 글자도 노출되면 안 됨)
# ---------------------------------------------------------------------------

# 파일별로, mask 후 산문 텍스트에 "절대 등장하면 안 되는" 코드 내부 문자열들.
# 이 문자열들은 corpus 파일을 직접 작성할 때 넣어둔 코드펜스/들여쓰기 코드 본문 발췌다.
FORBIDDEN_IN_PROSE = {
    "01_fence_traps.md": [
        "curl -sSL https://example.com/install.sh",
        'os.environ.get("HOME")',
        "print(\"이 코드는 실행되지 않는다",
        "이 펜스는 탭으로 들여써져 있다",
    ],
    "04_nested_lists.md": [
        'echo "리스트 안에 들어있는 코드블록"',
    ],
    "09_unclosed_fence.md": [
        'echo "이 펜스는 파일 끝까지 이어진다"',
        "curl https://example.com/never-closes",
    ],
    "10_mixed_korean_tech.md": [
        'tracer := otel.Tracer("주문서비스")',
        'attribute.String("주문.id", orderID)',
    ],
    "12_math_mermaid.md": [
        "graph TD",
        "participant U as 사용자",
    ],
}


class T2_CodeInviolability(ShieldTestCase):
    def test_code_never_leaks_into_prose(self):
        failures = []
        for name, forbidden_list in FORBIDDEN_IN_PROSE.items():
            src = CORPUS_DIR / name
            if not src.exists():
                failures.append(f"{name}: 코퍼스 파일이 없습니다 (테스트 매핑 오류).")
                continue
            with self.subTest(file=name):
                wd = self.workdir / src.stem
                wd.mkdir(parents=True, exist_ok=True)
                mask_proc, prose, _map_path = do_mask(src, wd)
                if mask_proc.returncode != 0:
                    failures.append(f"{name}: mask 실패.\n{proc_debug(mask_proc, 'mask')}")
                    continue
                prose_text = prose.read_text(encoding="utf-8")
                for needle in forbidden_list:
                    if needle in prose_text:
                        failures.append(
                            f"{name}: 코드 조각이 산문에 노출됐습니다 -> {needle!r}"
                        )
        if failures:
            self.fail("\n\n코드 불가침 위반:\n" + "\n".join(failures))


# ---------------------------------------------------------------------------
# T3 — 토큰 왕복 (개수/중복/순서)
# ---------------------------------------------------------------------------

class T3_TokenRoundTrip(ShieldTestCase):
    def test_token_count_matches_map_segments_no_duplicates_ordered(self):
        failures = []
        for src in corpus_files():
            with self.subTest(file=src.name):
                wd = self.workdir / src.stem
                wd.mkdir(parents=True, exist_ok=True)
                mask_proc, prose, map_path = do_mask(src, wd)
                if mask_proc.returncode != 0:
                    failures.append(f"{src.name}: mask 실패.\n{proc_debug(mask_proc, 'mask')}")
                    continue

                prose_text = prose.read_text(encoding="utf-8")
                found = TOKEN_RE.findall(prose_text)  # [(kind, digits), ...] 등장 순서
                found_ids = [f"HZ-{k}{d}" for k, d in found]

                data = load_map(map_path)
                segments = data.get("segments", [])
                map_ids = [seg["id"] for seg in segments]

                # 개수 일치
                if len(found_ids) != len(map_ids):
                    failures.append(
                        f"{src.name}: 산문 토큰 개수({len(found_ids)}) != map.segments 개수({len(map_ids)})"
                    )
                    continue

                # 중복 없음
                if len(set(found_ids)) != len(found_ids):
                    dupes = [i for i in found_ids if found_ids.count(i) > 1]
                    failures.append(f"{src.name}: 산문에 중복 토큰이 있습니다 -> {sorted(set(dupes))}")

                # 전단사(bijection): 산문 토큰 집합 == map id 집합
                if set(found_ids) != set(map_ids):
                    only_prose = set(found_ids) - set(map_ids)
                    only_map = set(map_ids) - set(found_ids)
                    failures.append(
                        f"{src.name}: 토큰 집합 불일치. 산문에만 있음={sorted(only_prose)}, "
                        f"map에만 있음={sorted(only_map)}"
                    )

                # 블록/인라인 각각 독립 시퀀스로 1부터(0001) 순증하는지
                for kind_letter, kind_name in (("B", "블록"), ("I", "인라인")):
                    nums_in_order = [
                        int(d) for (k, d) in found if k == kind_letter
                    ]
                    expected = list(range(1, len(nums_in_order) + 1))
                    if nums_in_order != expected:
                        failures.append(
                            f"{src.name}: {kind_name} 토큰 번호가 등장 순서대로 1부터 증가하지 않습니다. "
                            f"실제={nums_in_order}"
                        )

                # 블록 토큰은 자기 줄 단독 + 앞뒤 빈 줄
                lines = prose_text.splitlines()
                for i, line in enumerate(lines):
                    m = re.fullmatch(r"⟦HZ-B\d+⟧", line.strip())
                    if not m:
                        continue
                    if line.strip() != line:
                        failures.append(
                            f"{src.name}: 블록 토큰 줄에 여분의 공백이 있습니다 (줄 {i + 1}): {line!r}"
                        )
                    if i > 0 and lines[i - 1].strip() != "":
                        failures.append(
                            f"{src.name}: 블록 토큰 앞에 빈 줄이 없습니다 (줄 {i + 1})."
                        )
                    if i < len(lines) - 1 and lines[i + 1].strip() != "":
                        failures.append(
                            f"{src.name}: 블록 토큰 뒤에 빈 줄이 없습니다 (줄 {i + 1})."
                        )

        if failures:
            self.fail("\n\n토큰 왕복 위반:\n" + "\n".join(failures))


# ---------------------------------------------------------------------------
# T4 — 링크 텍스트는 산문에 남는다, URL 은 남지 않는다
# ---------------------------------------------------------------------------

class T4_LinkTextSurvives(ShieldTestCase):
    TARGET = "06_links.md"

    # (산문에 있어야 하는 텍스트, 산문에 없어야 하는 목적지 문자열)
    CASES = [
        ("한글 링크 텍스트가 있는 링크", "https://example.com/ko/문서"),
        ("참조 스타일 링크", "https://example.com/reference-one"),
        ("축약형 참조", "https://example.com/shorthand"),
    ]
    URL_MUST_BE_GONE = [
        "https://example.com/autolink",
        "https://example.com/bare/url?query=1&other=2",
        "https://example.com/images/그림.png",
    ]

    def test_link_text_kept_url_masked(self):
        src = CORPUS_DIR / self.TARGET
        if not src.exists():
            self.skipTest(f"{self.TARGET} 코퍼스 파일이 없습니다.")

        wd = self.workdir
        mask_proc, prose, _map_path = do_mask(src, wd)
        self.assertEqual(mask_proc.returncode, 0, proc_debug(mask_proc, "mask"))
        prose_text = prose.read_text(encoding="utf-8")

        failures = []
        for text, url in self.CASES:
            if text not in prose_text:
                failures.append(f"링크 텍스트가 산문에서 사라졌습니다: {text!r}")
            if url in prose_text:
                failures.append(f"링크 목적지 URL 이 산문에 그대로 남아있습니다: {url!r}")

        for url in self.URL_MUST_BE_GONE:
            if url in prose_text:
                failures.append(f"URL 이 마스킹되지 않고 산문에 노출됐습니다: {url!r}")

        if failures:
            self.fail("\n\n" + "\n".join(failures))


# ---------------------------------------------------------------------------
# T5 — 적대적 윤문 시뮬레이션: 반드시 verify 실패(exit 2)
# ---------------------------------------------------------------------------

class T5_AdversarialCorruption(ShieldTestCase):
    def _mask_target(self, name):
        src = CORPUS_DIR / name
        if not src.exists():
            self.skipTest(f"{name} 코퍼스 파일이 없습니다.")
        wd = self.workdir / name
        wd.mkdir(parents=True, exist_ok=True)
        mask_proc, prose, map_path = do_mask(src, wd)
        self.assertEqual(mask_proc.returncode, 0, proc_debug(mask_proc, "mask"))
        return src, wd, prose, map_path

    def test_a_delete_one_token(self):
        src, wd, prose, map_path = self._mask_target("10_mixed_korean_tech.md")
        text = prose.read_text(encoding="utf-8")
        m = TOKEN_RE.search(text)
        if not m:
            self.skipTest("이 코퍼스에는 토큰이 없어 삭제 테스트를 할 수 없습니다.")
        corrupted = text[:m.start()] + text[m.end():]
        corrupted_path = wd / "corrupted_a.txt"
        corrupted_path.write_text(corrupted, encoding="utf-8")

        restored = wd / "restored_a.md"
        restore_proc = do_restore(corrupted_path, map_path, restored)
        verify_proc = do_verify(src, restored, map_path)
        self.assertEqual(
            verify_proc.returncode, 2,
            f"(a) 토큰 삭제 후에도 verify 가 실패(exit 2)하지 않았습니다.\n"
            f"{proc_debug(restore_proc, 'restore')}\n{proc_debug(verify_proc, 'verify')}",
        )

    def test_b_duplicate_one_token(self):
        src, wd, prose, map_path = self._mask_target("10_mixed_korean_tech.md")
        text = prose.read_text(encoding="utf-8")
        m = TOKEN_RE.search(text)
        if not m:
            self.skipTest("이 코퍼스에는 토큰이 없어 복제 테스트를 할 수 없습니다.")
        token_str = m.group(0)
        corrupted = text[:m.end()] + "\n\n" + token_str + text[m.end():]
        corrupted_path = wd / "corrupted_b.txt"
        corrupted_path.write_text(corrupted, encoding="utf-8")

        restored = wd / "restored_b.md"
        restore_proc = do_restore(corrupted_path, map_path, restored)
        verify_proc = do_verify(src, restored, map_path)
        self.assertEqual(
            verify_proc.returncode, 2,
            f"(b) 토큰 복제 후에도 verify 가 실패(exit 2)하지 않았습니다.\n"
            f"{proc_debug(restore_proc, 'restore')}\n{proc_debug(verify_proc, 'verify')}",
        )

    def test_c_swap_token_order(self):
        src, wd, prose, map_path = self._mask_target("10_mixed_korean_tech.md")
        text = prose.read_text(encoding="utf-8")
        matches = list(TOKEN_RE.finditer(text))
        if len(matches) < 2:
            self.skipTest("토큰이 2개 미만이라 순서 교환 테스트를 할 수 없습니다.")
        m1, m2 = matches[0], matches[1]
        tok1, tok2 = m1.group(0), m2.group(0)
        # 텍스트 상에서 두 토큰의 위치만 맞바꾼다 (사이 내용은 그대로 둔다)
        corrupted = (
            text[:m1.start()] + tok2 + text[m1.end():m2.start()] + tok1 + text[m2.end():]
        )
        corrupted_path = wd / "corrupted_c.txt"
        corrupted_path.write_text(corrupted, encoding="utf-8")

        restored = wd / "restored_c.md"
        restore_proc = do_restore(corrupted_path, map_path, restored)
        verify_proc = do_verify(src, restored, map_path)
        self.assertEqual(
            verify_proc.returncode, 2,
            f"(c) 토큰 순서 교환 후에도 verify 가 실패(exit 2)하지 않았습니다.\n"
            f"{proc_debug(restore_proc, 'restore')}\n{proc_debug(verify_proc, 'verify')}",
        )

    def test_d_change_heading_text_breaks_heading_count(self):
        # 06_links.md 의 "### 가 나 다 섹션" 줄에서 '#' 을 떼어내 헤딩이 아니게 만든다.
        # -> restore 시 헤딩 줄 개수가 map 과 달라져서 자동복구가 안 되고, verify 가 실패해야 한다.
        src, wd, prose, map_path = self._mask_target("06_links.md")
        text = prose.read_text(encoding="utf-8")
        target_line = "### 가 나 다 섹션"
        if target_line not in text:
            self.skipTest(f"기대한 헤딩 줄을 산문에서 찾지 못했습니다: {target_line!r}")
        corrupted = text.replace(target_line, "가 나 다 섹션 (헤딩 마커 제거됨)", 1)
        corrupted_path = wd / "corrupted_d.txt"
        corrupted_path.write_text(corrupted, encoding="utf-8")

        restored = wd / "restored_d.md"
        restore_proc = do_restore(corrupted_path, map_path, restored)
        verify_proc = do_verify(src, restored, map_path)
        self.assertEqual(
            verify_proc.returncode, 2,
            f"(d) 헤딩 개수가 어긋났는데도 verify 가 실패(exit 2)하지 않았습니다.\n"
            f"{proc_debug(restore_proc, 'restore')}\n{proc_debug(verify_proc, 'verify')}",
        )

    def test_e_merge_bullets_without_allow_restructure(self):
        # 04_nested_lists.md 의 체크박스 3줄을 한 문단으로 합친다.
        src, wd, prose, map_path = self._mask_target("04_nested_lists.md")
        text = prose.read_text(encoding="utf-8")
        three_bullets = (
            "   - [ ] 아직 안 한 일\n"
            "   - [x] 이미 끝낸 일\n"
            "   - [ ] 진행 중인 일\n"
        )
        # 정확한 들여쓰기를 모르므로 유연하게 매칭한다.
        pattern = re.compile(
            r"[ \t]*-\s*\[ \]\s*아직 안 한 일\n"
            r"[ \t]*-\s*\[x\]\s*이미 끝낸 일\n"
            r"[ \t]*-\s*\[ \]\s*진행 중인 일\n",
        )
        m = pattern.search(text)
        if not m:
            self.skipTest("체크박스 3줄 블록을 산문에서 찾지 못했습니다 (마스킹 방식이 다를 수 있음).")
        merged = "아직 안 한 일, 이미 끝낸 일, 진행 중인 일을 한 문단으로 합쳤다.\n"
        corrupted = text[:m.start()] + merged + text[m.end():]
        corrupted_path = wd / "corrupted_e.txt"
        corrupted_path.write_text(corrupted, encoding="utf-8")

        restored = wd / "restored_e.md"
        restore_proc = do_restore(corrupted_path, map_path, restored)
        # --allow-restructure 를 주지 않는다 -> list_blocks 항목수 변화가 FAIL 이어야 한다.
        verify_proc = do_verify(src, restored, map_path)
        self.assertEqual(
            verify_proc.returncode, 2,
            f"(e) 불릿 3개를 문단으로 합쳤는데도(--allow-restructure 없이) "
            f"verify 가 실패(exit 2)하지 않았습니다.\n"
            f"{proc_debug(restore_proc, 'restore')}\n{proc_debug(verify_proc, 'verify')}",
        )


# ---------------------------------------------------------------------------
# T6 — 정상 윤문 시뮬레이션: 구조는 그대로, 문장만 바뀜 -> exit 0 또는 1
# ---------------------------------------------------------------------------

class T6_NormalHumanizeSimulation(ShieldTestCase):
    TARGET = "10_mixed_korean_tech.md"

    # 헤딩/리스트 마커/토큰과 무관한, 본문 중 유일하게 등장하는 단어들만 치환한다.
    WORD_SWAPS = [
        ("우리는 최근 몇 달간", "저희는 최근 몇 달간"),
        ("결론적으로,", "정리하자면,"),
        ("이러한 문제를 해결하기 위해", "이 문제를 풀기 위해"),
    ]

    def test_sentence_only_edit_passes_or_warns(self):
        src = CORPUS_DIR / self.TARGET
        if not src.exists():
            self.skipTest(f"{self.TARGET} 코퍼스 파일이 없습니다.")
        wd = self.workdir
        mask_proc, prose, map_path = do_mask(src, wd)
        self.assertEqual(mask_proc.returncode, 0, proc_debug(mask_proc, "mask"))

        text = prose.read_text(encoding="utf-8")
        applied = 0
        for old, new in self.WORD_SWAPS:
            if old in text:
                text = text.replace(old, new, 1)
                applied += 1
        if applied == 0:
            self.skipTest("치환 대상 문구를 산문에서 하나도 찾지 못했습니다 (마스킹 방식이 다를 수 있음).")

        humanized = wd / "humanized.md"
        humanized.write_text(text, encoding="utf-8")

        restored = wd / "restored.md"
        restore_proc = do_restore(humanized, map_path, restored)
        self.assertEqual(restore_proc.returncode, 0, proc_debug(restore_proc, "restore"))

        verify_proc = do_verify(src, restored, map_path)
        report = parse_json_report(verify_proc)
        self.assertIn(
            verify_proc.returncode, (0, 1),
            f"구조는 그대로 두고 문장만 바꿨는데 verify 가 실패(exit {verify_proc.returncode})했습니다.\n"
            f"{proc_debug(verify_proc, 'verify')}\nreport={report}",
        )


# ---------------------------------------------------------------------------
# T7 — verify 경고축: 숫자가 사라지면 WARN(exit 1)
# ---------------------------------------------------------------------------

class T7_NumberWarning(ShieldTestCase):
    TARGET = "10_mixed_korean_tech.md"

    def test_digits_removed_triggers_warn(self):
        src = CORPUS_DIR / self.TARGET
        if not src.exists():
            self.skipTest(f"{self.TARGET} 코퍼스 파일이 없습니다.")
        wd = self.workdir
        mask_proc, prose, map_path = do_mask(src, wd)
        self.assertEqual(mask_proc.returncode, 0, proc_debug(mask_proc, "mask"))

        text = prose.read_text(encoding="utf-8")
        if not re.search(r"\d", text):
            self.skipTest("산문에 숫자가 전혀 없어 이 테스트를 수행할 수 없습니다.")
        stripped = re.sub(r"\d", "", text)

        humanized = wd / "no_digits.md"
        humanized.write_text(stripped, encoding="utf-8")

        restored = wd / "restored.md"
        restore_proc = do_restore(humanized, map_path, restored)
        self.assertEqual(restore_proc.returncode, 0, proc_debug(restore_proc, "restore"))

        verify_proc = do_verify(src, restored, map_path)
        report = parse_json_report(verify_proc)
        self.assertEqual(
            verify_proc.returncode, 1,
            f"산문의 숫자를 모두 지웠는데 WARN(exit 1)이 아니라 exit {verify_proc.returncode} 이 나왔습니다.\n"
            f"{proc_debug(verify_proc, 'verify')}\nreport={report}",
        )
        if report is not None:
            self.assertEqual(report.get("fails", []), [], f"WARN 이어야 하는데 fails 가 비어있지 않습니다: {report}")
            self.assertTrue(report.get("warns"), f"warns 배열이 비어있습니다: {report}")


# ---------------------------------------------------------------------------
# T8 — 충돌 거부: 원문에 이미 HZ- 토큰이 있으면 mask 는 exit 3
# ---------------------------------------------------------------------------

class T8_ConflictRejection(ShieldTestCase):
    def test_existing_hz_token_rejected(self):
        src = CORPUS_DIR / "10_mixed_korean_tech.md"
        if not src.exists():
            self.skipTest("기준 코퍼스 파일이 없습니다.")
        original = src.read_text(encoding="utf-8")
        injected = original.replace(
            "## 왜 분산 트레이싱이 필요한가",
            f"## 왜 분산 트레이싱이 필요한가 {CONFLICT_MARKER}",
            1,
        )
        if injected == original:
            # 못 찾았으면 그냥 맨 앞에 붙인다.
            injected = f"{CONFLICT_MARKER}\n\n" + original

        wd = self.workdir
        conflicted = wd / "conflicted.md"
        conflicted.write_text(injected, encoding="utf-8")

        mask_proc, prose, map_path = do_mask(conflicted, wd)
        self.assertEqual(
            mask_proc.returncode, 3,
            f"원문에 이미 ⟦HZ- 토큰이 있는데 mask 가 exit 3 으로 거부하지 않았습니다.\n"
            f"{proc_debug(mask_proc, 'mask')}",
        )


# ---------------------------------------------------------------------------
# T10 — 무편집 검증: 코퍼스 전체가 mask -> restore(무수정) -> verify 를 통과해야 한다
# ---------------------------------------------------------------------------

class T10_UnmodifiedVerifyPassesAllCorpus(ShieldTestCase):
    """mask -> 산문 무수정 restore -> verify 가 코퍼스 전체에서 PASS(exit 0) 여야 한다.

    T1 은 IDENTITY(바이트 동일)만 확인하고 verify CLI 는 호출하지 않는다. 다른
    verify 테스트(T5~T7)들은 특정 파일 하나를 골라 일부러 편집한 뒤 verify 를
    호출한다. 그래서 "아무것도 편집하지 않은 복원본인데도 verify 가 자체적으로
    FAIL 을 내는" 오탐(예: 같은 텍스트를 가진 블록 세그먼트가 여러 번 등장하는
    문서)을 코퍼스 전체 기준으로 잡아낼 테스트가 이전에는 없었다.
    """

    def test_verify_passes_on_unedited_restoration_all_corpus(self):
        failures = []
        for src in corpus_files():
            with self.subTest(file=src.name):
                wd = self.workdir / src.stem
                wd.mkdir(parents=True, exist_ok=True)

                mask_proc, prose, map_path = do_mask(src, wd)
                if mask_proc.returncode != 0:
                    failures.append(
                        f"{src.name}: mask 가 실패했습니다 (기대: 0).\n{proc_debug(mask_proc, 'mask')}"
                    )
                    continue

                restored = wd / "restored.md"
                restore_proc = do_restore(prose, map_path, restored)
                if restore_proc.returncode != 0:
                    failures.append(
                        f"{src.name}: restore 가 실패했습니다 (기대: 0).\n{proc_debug(restore_proc, 'restore')}"
                    )
                    continue

                verify_proc = do_verify(src, restored, map_path)
                if verify_proc.returncode != 0:
                    failures.append(
                        f"{src.name}: 무편집 복원본인데 verify 가 PASS(exit 0)가 아닙니다"
                        f"(exit {verify_proc.returncode}).\n{proc_debug(verify_proc, 'verify')}"
                    )

        if failures:
            self.fail(
                f"\n\n무편집 verify 위반 {len(failures)}건 (전체 {len(corpus_files())}개 중):\n\n"
                + "\n\n".join(failures)
            )


# ---------------------------------------------------------------------------
# 진입점
# ---------------------------------------------------------------------------

def _print_preflight():
    print("=" * 70)
    print("md_shield.py 테스트 하네스 사전 점검")
    print(f"  SCRIPT      = {SCRIPT}  (존재={SCRIPT.exists()})")
    print(f"  CORPUS_DIR  = {CORPUS_DIR}  (파일 수={len(corpus_files())})")
    reason = _script_missing_reason()
    if reason:
        print("  -> " + reason.replace("\n", "\n     "))
    print("=" * 70)


if __name__ == "__main__":
    _print_preflight()
    unittest.main(verbosity=2)
