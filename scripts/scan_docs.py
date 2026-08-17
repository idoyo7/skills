#!/usr/bin/env python3
"""humanize-docs 스캐너 — 마크다운 문서를 훑어 윤문 대상 분류표를 낸다.

표준 라이브러리만 사용한다. 같은 디렉토리의 md_shield.py 를 (가능하면) 써서
정확한 산문 글자수·보호 구간 카운트를 얻고, humanize-korean 의
metrics_v2.compute_all + prepare_monolith_input.compute_route_hint 를 재사용해
light|standard|heavy 경로 힌트를 낸다. 어느 쪽이든 실패하면 자체 근사치로
graceful degrade 한다 — 병렬 작업 중이라 md_shield.py 가 아직 없을 수 있다.

사용법:
    python3 scan_docs.py --root . [--glob '**/*.md'] [--max-depth 4]
        [--min-hangul 0.25] [--include PAT ...] [--exclude PAT ...] [--json]
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# humanize-korean 참조 경로 (읽기 전용 — 이 저장소를 수정하지 않는다)
# 설치 위치는 사용자마다 다르므로 동적으로 찾는다: 버전별 플러그인 캐시(최신 버전)
# → 마켓플레이스 체크아웃 순으로 시도하고, 둘 다 없으면 None — 호출부
# (_load_route_modules)가 import 실패로 graceful degrade 한다.
# ---------------------------------------------------------------------------


def _find_hk_root() -> Path | None:
    home = Path.home()
    cache_dir = home / ".claude" / "plugins" / "cache" / "im-not-ai" / "humanize-korean"
    versions = sorted(
        (p for p in cache_dir.glob("*") if p.is_dir()),
        key=lambda p: tuple(int(x) if x.isdigit() else x for x in p.name.split(".")),
    )
    if versions:
        return versions[-1]
    marketplace_root = home / ".claude" / "plugins" / "marketplaces" / "im-not-ai"
    if (marketplace_root / ".claude" / "skills" / "humanize-korean").is_dir():
        return marketplace_root
    return None


_HK_ROOT = _find_hk_root()
_METRICS_DIR = (
    _HK_ROOT / ".claude" / "skills" / "humanize-korean" / "references"
    if _HK_ROOT is not None
    else Path()
)
_HK_SCRIPTS_DIR = _HK_ROOT / "scripts" if _HK_ROOT is not None else Path()

_SELF_DIR = Path(__file__).resolve().parent

VERSION = "1.0"

# ---------------------------------------------------------------------------
# 기본 제외/판정 상수
# ---------------------------------------------------------------------------

DEFAULT_EXCLUDE_DIRS = {
    "node_modules", ".git", "dist", "build", "out", ".next", "vendor",
    "target", "_workspace", ".venv", "site-packages", ".omc",
}

_AUTOGEN_BASENAMES = {"changelog.md", "license.md"}
_AUTOGEN_MARKER_RE = re.compile(r"<!--\s*generated|do not edit", re.IGNORECASE)

_AGENT_INSTRUCTION_BASENAMES = {"CLAUDE.md", "AGENTS.md", "GEMINI.md", ".cursorrules"}

FENCE_HEAVY_RATIO = 0.6

# ---------------------------------------------------------------------------
# 근사(fallback) 마크다운 파싱 정규식 — md_shield.py 를 못 쓸 때만 사용.
# CLI 계약의 mask 규칙과 100% 동일하지는 않다(근사치임을 명시).
# ---------------------------------------------------------------------------

_FRONTMATTER_RE = re.compile(
    r"^﻿?(?:---|\+\+\+)\r?\n.*?\r?\n(?:---|\+\+\+)[ \t]*\r?\n?", re.DOTALL
)
_FENCE_RE = re.compile(
    r"(?m)^([ \t]{0,3})(`{3,}|~{3,})[^\n]*\r?\n(?:.*\r?\n)*?\1\2[ \t]*\r?\n?"
)
_TABLE_ROW_RE = re.compile(r"^[ \t]{0,3}\|.*\|[ \t]*$")
_TABLE_SEP_RE = re.compile(r"^[ \t]{0,3}\|?[ \t]*:?-{1,}:?[ \t]*(\|[ \t]*:?-{1,}:?[ \t]*)*\|?[ \t]*$")
_IMAGE_RE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
_LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)]*)\)")
_AUTOLINK_RE = re.compile(r"<(https?://[^ >]+)>")
_BARE_URL_RE = re.compile(r"(?<![(\[<])\bhttps?://[^\s)>\]]+")
_REFDEF_RE = re.compile(r"(?m)^[ \t]{0,3}\[[^\]]+\]:[ \t]*\S+.*$\n?")
_INLINE_CODE_RE = re.compile(r"`[^`\n]+`")


def _approx_prose(text: str) -> dict[str, Any]:
    """md_shield.py 없이 자체 근사치로 산문·보호구간 카운트를 낸다.

    구조를 정확히 재구성하지 않는다 — 오직 "얼마나 산문이고 얼마나
    보호되어야 하는지" 통계만 필요하므로, 보호 구간을 제거한 뒤 남는
    텍스트 분량을 산문으로 취급한다.
    """
    original_len = len(text)

    fm_match = _FRONTMATTER_RE.match(text)
    body = text[fm_match.end():] if fm_match else text

    fence_char_total = 0
    fence_count = 0
    for m in _FENCE_RE.finditer(body):
        fence_count += 1
        fence_char_total += len(m.group(0))
    body = _FENCE_RE.sub("", body)

    lines = body.split("\n")
    out_lines: list[str] = []
    table_count = 0
    table_char_total = 0
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if _TABLE_ROW_RE.match(line) and i + 1 < n and _TABLE_SEP_RE.match(lines[i + 1]):
            start = i
            j = i + 2
            while j < n and _TABLE_ROW_RE.match(lines[j]):
                j += 1
            block = lines[start:j]
            table_char_total += sum(len(l) + 1 for l in block)
            table_count += 1
            i = j
            continue
        out_lines.append(line)
        i += 1
    body = "\n".join(out_lines)

    image_count = len(_IMAGE_RE.findall(body))
    body = _IMAGE_RE.sub("", body)

    link_count = len(_LINK_RE.findall(body))
    body = _LINK_RE.sub(r"\1", body)

    autolink_count = len(_AUTOLINK_RE.findall(body))
    body = _AUTOLINK_RE.sub("", body)

    bare_count = len(_BARE_URL_RE.findall(body))
    body = _BARE_URL_RE.sub("", body)

    refdef_count = len(_REFDEF_RE.findall(body))
    body = _REFDEF_RE.sub("", body)

    body = _INLINE_CODE_RE.sub("", body)

    prose_text = body
    prose_chars = len(re.sub(r"\s+", "", prose_text))

    return {
        "source": "approx",
        "prose_text": prose_text,
        "prose_chars": prose_chars,
        "protected": {
            "fence": fence_count,
            "table": table_count,
            "link": link_count + autolink_count + bare_count + refdef_count,
            "image": image_count,
        },
        "fence_chars": fence_char_total,
        "total_chars_seen": original_len,
    }


# ---------------------------------------------------------------------------
# md_shield.py 경유 정확 계산 — 있으면 우선 사용.
# ---------------------------------------------------------------------------

_TOKEN_RE = re.compile(r"⟦HZ-[BI]\d{4,}⟧")

_LINK_KINDS = {"link_dest", "autolink", "url_bare", "ref_def"}


def _via_md_shield(path: Path, text: str) -> dict[str, Any] | None:
    """가능하면 md_shield.py 를 import 해서 정확한 mask 결과를 얻는다.

    내부 함수 시그니처는 병렬 작업 중이라 확정되지 않았으므로, 알려질 법한
    후보 API를 순서대로 시도하고, 전부 실패하면 고정된 CLI 계약(서브프로세스)
    으로 폴백한다. 그것도 실패하면 None을 반환해 근사치 경로로 넘긴다.
    """
    scripts_dir = str(_SELF_DIR)
    if scripts_dir not in sys.path:
        sys.path.insert(0, scripts_dir)
    try:
        import md_shield  # type: ignore
    except Exception:
        md_shield = None  # type: ignore

    prose: str | None = None
    segments: list[dict[str, Any]] | None = None

    if md_shield is not None:
        for fn_name in ("mask_text", "mask_source", "mask"):
            fn = getattr(md_shield, fn_name, None)
            if fn is None:
                continue
            try:
                result = fn(text)
            except TypeError:
                try:
                    result = fn(text, profile="docs")
                except Exception:
                    continue
            except Exception:
                continue
            try:
                if isinstance(result, tuple) and len(result) >= 2:
                    prose, map_obj = result[0], result[1]
                    segments = (
                        map_obj.get("segments", [])
                        if isinstance(map_obj, dict)
                        else map_obj
                    )
                elif isinstance(result, dict):
                    prose = result.get("prose")
                    segments = result.get("segments", [])
                if prose is not None:
                    break
            except Exception:
                prose = None
                continue

    if prose is None:
        # CLI 계약(고정)으로 폴백 — 내부 API보다 신뢰도가 높다.
        script_path = _SELF_DIR / "md_shield.py"
        if not script_path.exists():
            return None
        import subprocess
        import tempfile

        with tempfile.TemporaryDirectory() as td:
            out_prose = Path(td) / "prose.txt"
            out_map = Path(td) / "map.json"
            try:
                proc = subprocess.run(
                    [
                        sys.executable, str(script_path), "mask",
                        "--src", str(path),
                        "--out-prose", str(out_prose),
                        "--out-map", str(out_map),
                        "--json",
                    ],
                    capture_output=True, text=True, timeout=30,
                )
                if proc.returncode not in (0, 1) or not out_prose.exists() or not out_map.exists():
                    return None
                prose = out_prose.read_text(encoding="utf-8")
                map_obj = json.loads(out_map.read_text(encoding="utf-8"))
                segments = map_obj.get("segments", [])
            except Exception:
                return None

    if prose is None or segments is None:
        return None

    counts = {"fence": 0, "table": 0, "link": 0, "image": 0}
    fence_chars = 0
    for seg in segments:
        try:
            kind = seg.get("kind")
            seg_text = seg.get("text", "")
        except AttributeError:
            continue
        if kind == "fence":
            counts["fence"] += 1
            fence_chars += len(seg_text)
        elif kind == "table":
            counts["table"] += 1
        elif kind == "image":
            counts["image"] += 1
        elif kind in _LINK_KINDS:
            counts["link"] += 1

    stripped = _TOKEN_RE.sub("", prose)
    prose_chars = len(re.sub(r"\s+", "", stripped))

    return {
        "source": "md_shield",
        "prose_text": prose,
        "prose_chars": prose_chars,
        "protected": counts,
        "fence_chars": fence_chars,
        "total_chars_seen": len(text),
    }


# ---------------------------------------------------------------------------
# route_hint — metrics_v2.compute_all + prepare_monolith_input.compute_route_hint
# ---------------------------------------------------------------------------

_route_mods: dict[str, Any] = {}


def _load_route_modules() -> bool:
    if _route_mods.get("_loaded"):
        return _route_mods.get("ok", False)
    _route_mods["_loaded"] = True
    _route_mods["ok"] = False
    try:
        for p in (str(_METRICS_DIR), str(_HK_SCRIPTS_DIR)):
            if p not in sys.path:
                sys.path.insert(0, p)
        import metrics_v2  # type: ignore
        import prepare_monolith_input as pmi  # type: ignore

        _route_mods["metrics_v2"] = metrics_v2
        _route_mods["pmi"] = pmi
        _route_mods["ok"] = True
    except Exception:
        pass
    return _route_mods["ok"]


def _compute_route_hint(prose_text: str) -> tuple[str | None, str | None]:
    if not _load_route_modules():
        return None, None
    try:
        metrics_v2 = _route_mods["metrics_v2"]
        pmi = _route_mods["pmi"]
        metrics_obj = metrics_v2.compute_all(prose_text, genre="essay")
        route = pmi.compute_route_hint(metrics_obj)
        return route.get("route_hint"), route.get("route_reason")
    except Exception:
        return None, None


# ---------------------------------------------------------------------------
# 한글 비율
# ---------------------------------------------------------------------------


def _hangul_ratio(text: str) -> float:
    """한글 음절 / (공백·마크업 제외 문자). isalnum() 으로 마크업 기호를
    자연스럽게 걸러낸다(#, *, |, -, > 등은 alnum이 아니다)."""
    denom = 0
    hangul = 0
    for ch in text:
        if ch.isalnum():
            denom += 1
            if "가" <= ch <= "힣":
                hangul += 1
    return hangul / denom if denom else 0.0


# ---------------------------------------------------------------------------
# 판정
# ---------------------------------------------------------------------------


def _is_agent_instruction_file(rel: Path) -> bool:
    if rel.name in _AGENT_INSTRUCTION_BASENAMES:
        return True
    if ".claude" in rel.parts:
        return True
    if rel.name == "SKILL.md" and "skills" in rel.parts:
        return True
    return False


def _is_autogen(rel: Path, text: str) -> bool:
    if rel.name.lower() in _AUTOGEN_BASENAMES:
        return True
    head = text[:2048]
    return bool(_AUTOGEN_MARKER_RE.search(head))


def _match_any(patterns: list[str], rel_posix: str, basename: str) -> bool:
    for pat in patterns:
        if fnmatch.fnmatch(rel_posix, pat) or fnmatch.fnmatch(basename, pat):
            return True
    return False


def scan_file(path: Path, root: Path, args: argparse.Namespace) -> dict[str, Any]:
    rel = path.relative_to(root)
    rel_posix = rel.as_posix()

    try:
        text = path.read_text(encoding="utf-8")
        read_error = None
    except Exception as exc:  # noqa: BLE001 — 파일별 오류는 스킵 처리로 흡수
        text = ""
        read_error = f"{type(exc).__name__}: {exc}"

    try:
        size_bytes = path.stat().st_size
    except OSError:
        size_bytes = 0

    total_chars = len(text)

    if read_error is not None:
        return {
            "path": rel_posix,
            "bytes": size_bytes,
            "total_chars": 0,
            "hangul_ratio": 0.0,
            "prose_chars": 0,
            "protected": {"fence": 0, "table": 0, "link": 0, "image": 0},
            "route_hint": None,
            "route_reason": None,
            "prose_source": None,
            "verdict": "skip",
            "reason": f"읽기 오류: {read_error}",
        }

    shield_result = _via_md_shield(path, text)
    used = shield_result if shield_result is not None else _approx_prose(text)

    hangul_ratio = _hangul_ratio(text)
    prose_chars = used["prose_chars"]
    protected = used["protected"]
    fence_chars = used.get("fence_chars", 0)
    fence_ratio = (fence_chars / total_chars) if total_chars else 0.0

    route_hint, route_reason = _compute_route_hint(used["prose_text"])

    # --- exclude 경로 (최우선) ---
    if args.exclude and _match_any(args.exclude, rel_posix, rel.name):
        verdict, reason = "skip", "제외 경로(--exclude)"
    elif args.include and not _match_any(args.include, rel_posix, rel.name):
        verdict, reason = "skip", "포함 목록(--include)에 없음"
    elif hangul_ratio < args.min_hangul:
        verdict, reason = "skip", f"한글 비율 {hangul_ratio:.1%} < {args.min_hangul:.0%} (영문 문서로 판단)"
    elif prose_chars < 200:
        verdict, reason = "skip", f"윤문할 산문 부족(prose_chars={prose_chars} < 200)"
    elif _is_autogen(rel, text):
        verdict, reason = "skip", "자동생성 문서 흔적(DO NOT EDIT/generated 주석 또는 CHANGELOG·LICENSE)"
    elif _is_agent_instruction_file(rel):
        verdict, reason = "caution", "에이전트 지시 파일 — 윤문하면 에이전트 동작이 바뀔 수 있음"
    elif fence_ratio > FENCE_HEAVY_RATIO:
        verdict, reason = "caution", f"코드펜스 비중 {fence_ratio:.0%} > {FENCE_HEAVY_RATIO:.0%}"
    else:
        verdict, reason = "target", "윤문 대상"

    return {
        "path": rel_posix,
        "bytes": size_bytes,
        "total_chars": total_chars,
        "hangul_ratio": round(hangul_ratio, 4),
        "prose_chars": prose_chars,
        "protected": protected,
        "route_hint": route_hint,
        "route_reason": route_reason,
        "prose_source": used["source"],
        "verdict": verdict,
        "reason": reason,
    }


# ---------------------------------------------------------------------------
# 파일 탐색
# ---------------------------------------------------------------------------


def _iter_candidates(root: Path, args: argparse.Namespace) -> list[Path]:
    out: list[Path] = []
    for p in sorted(root.glob(args.glob)):
        if not p.is_file():
            continue
        rel = p.relative_to(root)
        parts = rel.parts[:-1]
        if any(part in DEFAULT_EXCLUDE_DIRS for part in parts):
            continue
        depth = len(rel.parts) - 1
        if depth > args.max_depth:
            continue
        out.append(p)
    return out


# ---------------------------------------------------------------------------
# 출력
# ---------------------------------------------------------------------------

_VERDICT_ORDER = {"target": 0, "caution": 1, "skip": 2}


def _print_table(files: list[dict[str, Any]]) -> None:
    if not files:
        print("(대상 없음)")
        return
    ordered = sorted(files, key=lambda f: (_VERDICT_ORDER.get(f["verdict"], 9), f["path"]))

    headers = ["PATH", "한글%", "산문자수", "ROUTE", "판정", "사유"]
    rows = []
    for f in ordered:
        rows.append([
            f["path"],
            f"{f['hangul_ratio']:.1%}",
            str(f["prose_chars"]),
            f["route_hint"] or "-",
            f["verdict"],
            f["reason"],
        ])

    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))
    # 사유 열은 길어질 수 있으니 과도한 폭 확장은 그대로 둔다(가독성 우선).

    def fmt_row(cells: list[str]) -> str:
        return "  ".join(c.ljust(widths[i]) for i, c in enumerate(cells))

    print(fmt_row(headers))
    print("  ".join("-" * w for w in widths))
    for row in rows:
        print(fmt_row(row))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="마크다운 문서 윤문 대상 스캐너")
    ap.add_argument("--root", default=".", help="스캔 루트 디렉토리 (기본: 현재 디렉토리)")
    ap.add_argument("--glob", default="**/*.md", help="탐색 glob 패턴 (기본: **/*.md)")
    ap.add_argument("--max-depth", type=int, default=4, help="루트 기준 최대 디렉토리 깊이 (기본: 4)")
    ap.add_argument("--min-hangul", type=float, default=0.25, help="skip 판정 한글 비율 임계값 (기본: 0.25)")
    ap.add_argument("--include", nargs="*", default=[], help="포함 패턴(fnmatch, 반복 가능)")
    ap.add_argument("--exclude", nargs="*", default=[], help="제외 패턴(fnmatch, 반복 가능)")
    ap.add_argument("--json", action="store_true", help="마지막 줄에 JSON 리포트 출력")
    args = ap.parse_args(argv)

    root = Path(args.root).resolve()
    if not root.exists() or not root.is_dir():
        print(f"오류: --root 가 디렉토리가 아님: {root}", file=sys.stderr)
        return 3

    try:
        candidates = _iter_candidates(root, args)
    except Exception as exc:  # noqa: BLE001
        print(f"오류: 탐색 실패: {exc}", file=sys.stderr)
        return 3

    files = [scan_file(p, root, args) for p in candidates]

    _print_table(files)

    summary = {"target": 0, "caution": 0, "skip": 0}
    for f in files:
        summary[f["verdict"]] = summary.get(f["verdict"], 0) + 1
    print(f"\n총 {len(files)}개 — 대상 {summary['target']} · 주의 {summary['caution']} · 스킵 {summary['skip']}")

    if args.json:
        report = {"root": str(root), "files": files, "summary": summary}
        print(json.dumps(report, ensure_ascii=False))

    return 0


if __name__ == "__main__":
    sys.exit(main())
