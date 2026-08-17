#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
heading_anchor.py 에 대한 적대적 테스트 하네스.

주의: 이 파일은 heading_anchor.py 의 구현을 임포트하지 않는다. 오직 CLI 계약에만
근거해서 subprocess 로 실행 파일을 호출하고 결과를 검증한다. 구현이 아직 없거나
미완성이면 각 테스트 클래스는 크래시 대신 명확한 스킵 메시지를 내야 한다.

실행:
    python3 tests/test_heading_anchor.py
    (또는 run.sh 경유)
"""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SKILL_DIR = TESTS_DIR.parent
CORPUS_DIR = TESTS_DIR / "corpus"
SCRIPT = SKILL_DIR / "scripts" / "heading_anchor.py"


def _script_missing_reason():
    if not SCRIPT.exists():
        return (
            f"heading_anchor.py 가 아직 존재하지 않습니다: {SCRIPT}\n"
            "  구현 에이전트가 작업 중일 수 있습니다. 이 스킵은 정상입니다 — "
            "구현이 도착하면 같은 명령으로 다시 실행하세요."
        )
    return None


def run_ha(args, cwd=None):
    cmd = [sys.executable, str(SCRIPT), *args]
    return subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)


def parse_json_report(proc):
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
    return (
        f"[{label}] returncode={proc.returncode}\n"
        f"  stdout(tail 500)={proc.stdout[-500:]!r}\n"
        f"  stderr(tail 500)={proc.stderr[-500:]!r}"
    )


class HeadingAnchorTestCase(unittest.TestCase):
    """heading_anchor.py 가 없으면 명확한 사유로 전체 클래스를 스킵한다."""

    @classmethod
    def setUpClass(cls):
        reason = _script_missing_reason()
        if reason:
            raise unittest.SkipTest(reason)

    def setUp(self):
        self._tmp = tempfile.mkdtemp(prefix="heading_anchor_test_")

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    @property
    def workdir(self) -> Path:
        return Path(self._tmp)

    def write(self, name: str, text: str) -> Path:
        p = self.workdir / name
        p.write_text(text, encoding="utf-8")
        return p


# ---------------------------------------------------------------------------
# T1 — 헤딩에 같은 파일 내부 앵커 링크가 걸린 문서: 텍스트 변경 + 링크 자동 갱신
# (테스트 계획 1번, corpus/13_heading_anchor_linked.md)
# ---------------------------------------------------------------------------


class T1_InternalAnchorsRewritten(HeadingAnchorTestCase):
    TARGET = "13_heading_anchor_linked.md"

    RESTORED = """# 캐시 설정 가이드

이 문서는 캐시 설정 방법을 다룬다. 자세한 절차는 [설정 방법에 대하여](#설정-방법에-대하여) 섹션을 참고하고, 문제가 생기면 [자주 발생하는 오류에 대하여](#자주-발생하는-오류에-대하여) 섹션으로 이동하라.

## 설정 방법

캐시 설정은 `cache.yaml` 파일에서 관리한다. 주요 필드는 다음과 같다.

- `ttl`: 캐시 만료 시간(초)
- `max_size`: 최대 캐시 항목 수

## 자주 발생하는 오류

설정 파일 경로가 잘못되면 애플리케이션이 시작되지 않는다. 아래 [설정 방법에 대하여](#설정-방법에-대하여) 섹션을 다시 확인하라.

## 요약

위 두 섹션([설정 방법에 대하여](#설정-방법에-대하여), [자주 발생하는 오류에 대하여](#자주-발생하는-오류에-대하여))을 참고하면 대부분의 문제를 해결할 수 있다.
"""

    def test_rewrite_then_gate_pass(self):
        src = CORPUS_DIR / self.TARGET
        if not src.exists():
            self.skipTest(f"{self.TARGET} 코퍼스 파일이 없습니다.")

        wd = self.workdir
        restored = self.write("restored.md", self.RESTORED)
        anchored = wd / "anchored.md"

        rw = run_ha(
            ["rewrite", "--src", str(src), "--restored", str(restored), "--out", str(anchored), "--json"]
        )
        self.assertEqual(rw.returncode, 0, proc_debug(rw, "rewrite"))
        rw_report = parse_json_report(rw)
        self.assertIsNotNone(rw_report, proc_debug(rw, "rewrite-json"))
        self.assertEqual(rw_report["links_rewritten"], 5, proc_debug(rw, "rewrite-json"))
        renamed_before = {r["before_slug"] for r in rw_report["renamed"]}
        renamed_after = {r["after_slug"] for r in rw_report["renamed"]}
        self.assertIn("설정-방법에-대하여", renamed_before)
        self.assertIn("설정-방법", renamed_after)

        final = wd / "final.md"
        gt = run_ha(
            ["gate", "--src", str(src), "--candidate", str(anchored), "--out", str(final), "--json"]
        )
        self.assertEqual(gt.returncode, 0, proc_debug(gt, "gate"))
        gt_report = parse_json_report(gt)
        self.assertEqual(gt_report["fail"], [], proc_debug(gt, "gate-json"))
        self.assertEqual(gt_report["warn"], [], proc_debug(gt, "gate-json"))

        final_text = final.read_text(encoding="utf-8")
        self.assertNotIn("(#설정-방법에-대하여)", final_text, "치환 이후 옛 슬러그가 남아있으면 안 됩니다.")
        self.assertIn("(#설정-방법)", final_text)
        self.assertEqual(final_text.count("(#설정-방법)"), 3, "설정 방법 앵커 3곳 모두 갱신되어야 합니다.")


# ---------------------------------------------------------------------------
# T2 — 헤딩에 아무 링크도 없는 문서: 자유롭게 편집됨
# (테스트 계획 2번, corpus/14_heading_no_links.md)
# ---------------------------------------------------------------------------


class T2_NoLinksFreeEdit(HeadingAnchorTestCase):
    TARGET = "14_heading_no_links.md"

    RESTORED = """# 배포 절차

이 문서는 배포 절차를 설명한다.

## 사전 준비 사항

배포 전에 테스트를 전부 통과시켜야 한다.

## 배포 실행 방법

`deploy.sh` 스크립트를 실행하면 자동으로 배포된다.

## 배포 후 확인할 점

로그를 확인하고 헬스체크 엔드포인트를 호출한다.
"""

    def test_rewrite_then_gate_pass_no_links(self):
        src = CORPUS_DIR / self.TARGET
        if not src.exists():
            self.skipTest(f"{self.TARGET} 코퍼스 파일이 없습니다.")

        wd = self.workdir
        restored = self.write("restored.md", self.RESTORED)
        anchored = wd / "anchored.md"

        rw = run_ha(
            ["rewrite", "--src", str(src), "--restored", str(restored), "--out", str(anchored), "--json"]
        )
        self.assertEqual(rw.returncode, 0, proc_debug(rw, "rewrite"))
        rw_report = parse_json_report(rw)
        self.assertEqual(rw_report["links_rewritten"], 0)
        self.assertEqual(len(rw_report["renamed"]), 4, "헤딩 4개 전부 텍스트가 바뀌어야 합니다.")

        final = wd / "final.md"
        gt = run_ha(
            ["gate", "--src", str(src), "--candidate", str(anchored), "--out", str(final), "--json"]
        )
        self.assertEqual(gt.returncode, 0, proc_debug(gt, "gate"))
        gt_report = parse_json_report(gt)
        self.assertEqual(gt_report["fail"], [])
        self.assertEqual(gt_report["warn"], [])


# ---------------------------------------------------------------------------
# T3 — 게이트 D 경고: 원래도 깨져 있던 링크는 진행하되 고지만 한다(exit 1)
# ---------------------------------------------------------------------------


class T3_GateWarnsOnPreexistingBrokenLink(HeadingAnchorTestCase):
    SRC = """# 제목

이미 깨진 링크: [없는 섹션](#없는-섹션)

## 소개

내용.
"""
    CANDIDATE = """# 제목

이미 깨진 링크: [없는 섹션](#없는-섹션)

## 소개 정리

내용.
"""

    def test_gate_warn_not_fail(self):
        wd = self.workdir
        src = self.write("src.md", self.SRC)
        candidate = self.write("candidate.md", self.CANDIDATE)
        out = wd / "final.md"

        gt = run_ha(["gate", "--src", str(src), "--candidate", str(candidate), "--out", str(out), "--json"])
        self.assertEqual(gt.returncode, 1, proc_debug(gt, "gate"))
        report = parse_json_report(gt)
        self.assertEqual(report["exit"], 1)
        self.assertEqual(len(report["warn"]), 1)
        self.assertEqual(report["fail"], [])
        self.assertEqual(report["rolled_back_headings"], [])
        # 경고일 뿐이므로 헤딩 편집은 그대로 유지되어야 한다.
        self.assertIn("## 소개 정리", out.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# T4 — 게이트 D 실패: 새로 끊어진 앵커는 해당 헤딩만 롤백하고 계속 진행한다(exit 2)
# ---------------------------------------------------------------------------


class T4_GateFailsAndRollsBackOffendingHeading(HeadingAnchorTestCase):
    SRC = """# 제목

[설정 방법](#설정-방법) 참고.

## 설정 방법

내용.
"""
    # rewrite 단계가 어떤 이유로든 이 링크를 놓쳤다고 가정한 손상 시나리오:
    # 헤딩 텍스트는 바뀌었는데 링크는 옛 슬러그를 그대로 가리킨다.
    CORRUPT_CANDIDATE = """# 제목

[설정 방법](#설정-방법) 참고.

## 설정하기

내용.
"""

    def test_gate_fail_rolls_back_single_heading(self):
        wd = self.workdir
        src = self.write("src.md", self.SRC)
        candidate = self.write("candidate.md", self.CORRUPT_CANDIDATE)
        out = wd / "final.md"

        gt = run_ha(["gate", "--src", str(src), "--candidate", str(candidate), "--out", str(out), "--json"])
        self.assertEqual(gt.returncode, 2, proc_debug(gt, "gate"))
        report = parse_json_report(gt)
        self.assertEqual(report["exit"], 2)
        self.assertEqual(len(report["fail"]), 1)
        self.assertEqual(len(report["rolled_back_headings"]), 1)
        self.assertEqual(report["rolled_back_headings"][0]["before_text"], "설정 방법")

        out_text = out.read_text(encoding="utf-8")
        self.assertIn("## 설정 방법", out_text, "롤백된 헤딩은 원문 텍스트로 되돌아가야 합니다.")
        self.assertNotIn("## 설정하기", out_text)
        self.assertIn("(#설정-방법)", out_text, "링크는 계속 유효한 슬러그를 가리켜야 합니다.")


# ---------------------------------------------------------------------------
# T5 — 코드펜스 안의 `#` 줄은 헤딩으로 오인하지 않는다
# ---------------------------------------------------------------------------


class T5_FenceAwareHeadingScan(HeadingAnchorTestCase):
    SRC = """# 제목

```bash
# 이것은 코드 안의 가짜 헤딩입니다 — 무시되어야 함
echo hi
```

## 진짜 헤딩

내용
"""
    RESTORED = """# 제목

```bash
# 이것은 코드 안의 가짜 헤딩입니다 — 무시되어야 함
echo hi
```

## 진짜 헤딩입니다요

내용
"""

    def test_fenced_hash_line_not_treated_as_heading(self):
        wd = self.workdir
        src = self.write("src.md", self.SRC)
        restored = self.write("restored.md", self.RESTORED)
        out = wd / "anchored.md"

        rw = run_ha(["rewrite", "--src", str(src), "--restored", str(restored), "--out", str(out), "--json"])
        self.assertEqual(rw.returncode, 0, proc_debug(rw, "rewrite"))
        report = parse_json_report(rw)
        self.assertEqual(len(report["renamed"]), 1, "펜스 안의 `#` 줄은 헤딩으로 잡히면 안 됩니다(진짜 헤딩 1개만).")
        self.assertEqual(report["renamed"][0]["before_text"], "진짜 헤딩")


# ---------------------------------------------------------------------------
# T6 — 중복 슬러그(같은 텍스트의 헤딩 2개): 편집되지 않은 쪽 링크는 절대 건드리지
# 않고, 편집된 쪽만 정확히 갱신된다(리뷰 C2/C3/I2 회귀 — INDEX 기반 판정 + 전역
# 유일 슬러그 보장이 없으면 두 헤딩이 서로 뒤섞일 수 있다).
# ---------------------------------------------------------------------------


class T6_DuplicateSlugHeadings(HeadingAnchorTestCase):
    SRC = """# 제목

[첫 설정](#설정) 그리고 [둘째 설정](#설정-1) 참고.

## 설정

내용 A

## 설정

내용 B
"""
    # 첫 번째 "설정" 헤딩은 그대로 두고, 두 번째("설정-1" 슬러그)만 편집한다.
    RESTORED = """# 제목

[첫 설정](#설정) 그리고 [둘째 설정](#설정-1) 참고.

## 설정

내용 A

## 설정 보완

내용 B
"""

    def test_duplicate_heading_slugs_resolved_by_index(self):
        wd = self.workdir
        src = self.write("src.md", self.SRC)
        restored = self.write("restored.md", self.RESTORED)
        anchored = wd / "anchored.md"

        rw = run_ha(
            ["rewrite", "--src", str(src), "--restored", str(restored), "--out", str(anchored), "--json"]
        )
        self.assertEqual(rw.returncode, 0, proc_debug(rw, "rewrite"))
        rw_report = parse_json_report(rw)
        self.assertIsNotNone(rw_report, proc_debug(rw, "rewrite-json"))
        # 편집되지 않은 첫 번째 "설정" 헤딩은 renamed 에 들어가면 안 된다.
        self.assertEqual(len(rw_report["renamed"]), 1)
        self.assertEqual(rw_report["renamed"][0]["before_slug"], "설정-1")
        self.assertEqual(rw_report["renamed"][0]["after_slug"], "설정-보완")
        self.assertEqual(rw_report["links_rewritten"], 1, "편집된 두 번째 헤딩을 가리키는 링크 1개만 치환되어야 합니다.")

        anchored_text = anchored.read_text(encoding="utf-8")
        self.assertIn("[첫 설정](#설정)", anchored_text, "편집되지 않은 첫 번째 헤딩의 링크는 그대로여야 합니다.")
        self.assertIn("[둘째 설정](#설정-보완)", anchored_text)

        final = wd / "final.md"
        gt = run_ha(
            ["gate", "--src", str(src), "--candidate", str(anchored), "--out", str(final), "--json"]
        )
        self.assertEqual(gt.returncode, 0, proc_debug(gt, "gate"))
        gt_report = parse_json_report(gt)
        self.assertEqual(gt_report["fail"], [], proc_debug(gt, "gate-json"))
        self.assertEqual(gt_report["warn"], [], proc_debug(gt, "gate-json"))

        final_text = final.read_text(encoding="utf-8")
        self.assertIn("[첫 설정](#설정)", final_text)
        self.assertIn("[둘째 설정](#설정-보완)", final_text)
        self.assertIn("## 설정\n", final_text, "편집되지 않은 첫 번째 헤딩 텍스트는 그대로 남아야 합니다.")
        self.assertIn("## 설정 보완", final_text)


# ---------------------------------------------------------------------------
# T7 — 이모지·em dash 로 둘러싸인 공백: 구두점 제거 후 남는 이중 공백이 이중
# 하이픈이 되어야 한다(리뷰 C1 회귀 — `\s+` 로 뭉개면 GitHub 실제 슬러그와 달라진다).
# ---------------------------------------------------------------------------


class T7_EmojiEmDashWhitespaceSlug(HeadingAnchorTestCase):
    SRC = """# 문서

[검증 절차](#검증-절차) 참고.

## 검증 절차

내용
"""
    RESTORED = """# 문서

[검증 절차](#검증-절차) 참고.

## 검증 — 완료 ✅ 최종

내용
"""

    def test_emoji_em_dash_whitespace_not_collapsed(self):
        wd = self.workdir
        src = self.write("src.md", self.SRC)
        restored = self.write("restored.md", self.RESTORED)
        anchored = wd / "anchored.md"

        rw = run_ha(
            ["rewrite", "--src", str(src), "--restored", str(restored), "--out", str(anchored), "--json"]
        )
        self.assertEqual(rw.returncode, 0, proc_debug(rw, "rewrite"))
        rw_report = parse_json_report(rw)
        self.assertEqual(len(rw_report["renamed"]), 1)
        # 이모지·em dash 제거로 생기는 이중 공백은 이중 하이픈이 되어야 한다(뭉개면 안 됨).
        self.assertEqual(rw_report["renamed"][0]["after_slug"], "검증--완료--최종")
        self.assertEqual(rw_report["links_rewritten"], 1)

        anchored_text = anchored.read_text(encoding="utf-8")
        self.assertIn("(#검증--완료--최종)", anchored_text)
        self.assertNotIn("(#검증-완료-최종)", anchored_text, "공백 런이 하이픈 하나로 뭉개지면 안 됩니다.")

        final = wd / "final.md"
        gt = run_ha(
            ["gate", "--src", str(src), "--candidate", str(anchored), "--out", str(final), "--json"]
        )
        self.assertEqual(gt.returncode, 0, proc_debug(gt, "gate"))
        gt_report = parse_json_report(gt)
        self.assertEqual(gt_report["fail"], [], proc_debug(gt, "gate-json"))
        self.assertEqual(gt_report["warn"], [], proc_debug(gt, "gate-json"))


# ---------------------------------------------------------------------------
# T8 — 롤백은 발생(occurrence) 단위: 깨진 헤딩을 롤백할 때 무관한 다른 헤딩의
# 멀쩡한 링크는 절대 건드리지 않는다(리뷰 C4 회귀 — 문서 전체 문자열 치환 금지).
# ---------------------------------------------------------------------------


class T8_RollbackDoesNotTouchUnrelatedHeading(HeadingAnchorTestCase):
    SRC = """# 제목

[설정](#설정-방법) 참고. [사용법](#사용-안내) 참고.

## 설정 방법

내용 A

## 사용 안내

내용 B
"""
    # "설정 방법" 은 헤딩 텍스트만 바뀌고 링크가 rewrite 단계를 놓친 손상 시나리오
    # (T4 와 동일 패턴). "사용 안내" 는 완전히 별개로, 정상적으로 편집되고 링크도
    # 이미 올바르게 갱신되어 있다 — 이 쪽은 게이트가 절대 건드리면 안 된다.
    CANDIDATE = """# 제목

[설정](#설정-방법) 참고. [사용법](#사용-안내-정리) 참고.

## 설정하기

내용 A

## 사용 안내 정리

내용 B
"""

    def test_unrelated_heading_and_link_untouched_by_rollback(self):
        wd = self.workdir
        src = self.write("src.md", self.SRC)
        candidate = self.write("candidate.md", self.CANDIDATE)
        out = wd / "final.md"

        gt = run_ha(["gate", "--src", str(src), "--candidate", str(candidate), "--out", str(out), "--json"])
        self.assertEqual(gt.returncode, 2, proc_debug(gt, "gate"))
        report = parse_json_report(gt)
        self.assertEqual(len(report["fail"]), 1)
        self.assertEqual(report["fail"][0]["heading_index"], 1)
        self.assertEqual(len(report["rolled_back_headings"]), 1)
        self.assertEqual(report["rolled_back_headings"][0]["before_text"], "설정 방법")

        out_text = out.read_text(encoding="utf-8")
        self.assertIn("## 설정 방법", out_text, "손상된 헤딩만 원문으로 롤백되어야 합니다.")
        self.assertNotIn("## 설정하기", out_text)
        self.assertIn("(#설정-방법)", out_text)
        # 무관한 헤딩과 그 링크는 완전히 그대로 남아야 한다.
        self.assertIn("## 사용 안내 정리", out_text, "무관한 헤딩 편집이 롤백되면 안 됩니다.")
        self.assertNotIn("## 사용 안내\n", out_text)
        self.assertIn("(#사용-안내-정리)", out_text, "무관한 헤딩의 정상 링크가 건드려지면 안 됩니다.")


# ---------------------------------------------------------------------------
# T9 — 롤백의 부작용: 같은 헤딩을 가리키는 링크가 둘 있고 하나는 이미 새 슬러그로
# 올바르게 갱신됐는데, 다른 하나(stale)가 게이트를 트리거해 헤딩 텍스트를 되돌리면
# 방금 전까지 멀쩡했던 그 링크가 새로 깨진다. 게이트는 이 부작용을 놓치면 안 된다
# (리뷰 R1 회귀 — 롤백 적용 후 전체 재검증이 없으면 조용히 넘어간다).
# ---------------------------------------------------------------------------


class T9_RollbackCollateralBreakDetected(HeadingAnchorTestCase):
    SRC = """# 제목

[좋음](#설정-방법) 첫 참고. [부실](#설정-방법) 둘째 참고.

## 설정 방법

내용
"""
    # "좋음" 링크는 (가상의) rewrite 단계에서 이미 새 슬러그로 정확히 갱신됐다.
    # "부실" 링크는 그 rewrite 를 놓친 손상 시나리오(T4 와 같은 패턴)다.
    CANDIDATE = """# 제목

[좋음](#설정하기) 첫 참고. [부실](#설정-방법) 둘째 참고.

## 설정하기

내용
"""

    def test_rollback_side_effect_on_valid_sibling_link_is_reported(self):
        wd = self.workdir
        src = self.write("src.md", self.SRC)
        candidate = self.write("candidate.md", self.CANDIDATE)
        out = wd / "final.md"

        gt = run_ha(["gate", "--src", str(src), "--candidate", str(candidate), "--out", str(out), "--json"])
        self.assertEqual(gt.returncode, 2, proc_debug(gt, "gate"))
        report = parse_json_report(gt)
        self.assertIsNotNone(report, proc_debug(gt, "gate-json"))

        # "부실" 이 트리거한 롤백 자체는 성공했다 — 그 자신의 타깃은 다시 유효해졌다.
        self.assertEqual(len(report["rolled_back_headings"]), 1)
        self.assertEqual(report["rolled_back_headings"][0]["before_text"], "설정 방법")

        # 하지만 "좋음" 은 롤백의 부작용으로 새로 깨졌다 — unremediated 에 반드시 잡혀야
        # 하고, rolled_back_headings 하나만 봐서는 이 파손을 알 수 없다.
        self.assertIn("unremediated", report, "R1/R2 재검증 결과를 담는 unremediated 필드가 있어야 합니다.")
        collateral = [u for u in report["unremediated"] if u.get("reason") == "collateral_break"]
        self.assertEqual(len(collateral), 1, proc_debug(gt, "gate-json"))
        self.assertEqual(collateral[0]["target"], "설정하기")

        out_text = out.read_text(encoding="utf-8")
        self.assertIn("## 설정 방법", out_text, "헤딩은 원문으로 롤백되어야 합니다.")
        self.assertIn("[부실](#설정-방법)", out_text, "롤백 트리거였던 링크는 유효해야 합니다.")
        # "좋음" 링크는 문서 전체 치환 대상이 아니었으므로(C4) 텍스트 자체는 안 바뀐 채
        # 남아 있다 — 그런데 헤딩이 되돌아갔으니 이제는 어떤 헤딩과도 안 맞는다.
        self.assertIn("[좋음](#설정하기)", out_text)
        self.assertNotIn("## 설정하기", out_text, "헤딩 텍스트는 원문으로 롤백되어 더 이상 남아 있으면 안 됩니다.")


# ---------------------------------------------------------------------------
# T10 — 무효 롤백: 헤딩 A 의 새 슬러그가 헤딩 B 의 원래 슬러그와 충돌해서 B 를
# 향하던 링크가 오배선된다. B 자신은 편집되지 않았으므로 B 의 텍스트를 "롤백"해도
# 실제로는 아무것도 안 바뀐다 — 이 무효 롤백이 rolled_back_headings 에 마치 진짜
# 복구인 것처럼 잡히면 안 되고, 여전히 깨진 채라는 게 unremediated 로 드러나야 한다
# (리뷰 R2/R6 회귀 — C2 오배선 탐지와 같은 뿌리지만, "탐지" 만으로는 부족하고
# "탐지했는데 못 고쳤다" 는 사실 자체가 정직하게 보고돼야 한다).
# ---------------------------------------------------------------------------


class T10_CollisionRollbackReportedUnremediated(HeadingAnchorTestCase):
    SRC = """# 제목

[B로](#설정하기) 참고.

## 이전 이름

내용 A

## 설정하기

내용 B
"""
    # 헤딩 A("이전 이름")가 "설정하기" 로 편집되어 헤딩 B(원래부터 "설정하기")의
    # 슬러그와 충돌한다. B 자신은 전혀 편집되지 않았다.
    CANDIDATE = """# 제목

[B로](#설정하기) 참고.

## 설정하기

내용 A

## 설정하기

내용 B
"""

    def test_collision_rollback_is_no_op_and_reported_unremediated(self):
        wd = self.workdir
        src = self.write("src.md", self.SRC)
        candidate = self.write("candidate.md", self.CANDIDATE)
        out = wd / "final.md"

        gt = run_ha(["gate", "--src", str(src), "--candidate", str(candidate), "--out", str(out), "--json"])
        self.assertEqual(gt.returncode, 2, proc_debug(gt, "gate"))
        report = parse_json_report(gt)
        self.assertIsNotNone(report, proc_debug(gt, "gate-json"))

        self.assertEqual(len(report["fail"]), 1)
        self.assertEqual(report["fail"][0]["heading_index"], 2, "B(인덱스 2)를 향하던 링크가 실패로 잡혀야 합니다.")

        # B 의 텍스트는 원래 안 바뀌었으므로 "롤백" 은 아무 효과가 없다 — 진짜
        # remediation 이 아니므로 rolled_back_headings 에 들어가면 안 된다.
        self.assertEqual(report["rolled_back_headings"], [], "무효 롤백을 remediated 로 잘못 보고하면 안 됩니다.")

        still_broken = [u for u in report["unremediated"] if u.get("reason") == "still_broken"]
        self.assertEqual(len(still_broken), 1, proc_debug(gt, "gate-json"))
        self.assertEqual(still_broken[0]["heading_index"], 2)

        # 문서 자체는 사실상 그대로다(둘 다 "설정하기") — 여전히 오배선된 채 남는다.
        out_text = out.read_text(encoding="utf-8")
        self.assertEqual(out_text.count("## 설정하기"), 2, "충돌이 해소되지 않은 채 두 헤딩 모두 같은 텍스트로 남습니다.")


# ---------------------------------------------------------------------------
# 진입점
# ---------------------------------------------------------------------------


def _print_preflight():
    print("=" * 70)
    print("heading_anchor.py 테스트 하네스 사전 점검")
    print(f"  SCRIPT      = {SCRIPT}  (존재={SCRIPT.exists()})")
    print(f"  CORPUS_DIR  = {CORPUS_DIR}")
    reason = _script_missing_reason()
    if reason:
        print("  -> " + reason.replace("\n", "\n     "))
    print("=" * 70)


if __name__ == "__main__":
    _print_preflight()
    unittest.main(verbosity=2)
