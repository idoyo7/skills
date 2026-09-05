#!/usr/bin/env python3
"""slop_scan.py — 게이트 S(초안 관문) 결정적 스캐너.

wwe 는 문장과 레이아웃의 AI 티를 걷는다. 이 스크립트는 그 표면 윤문으로 덮이지
않는 축 — 근거 없는 단정(S1), 지워도 손실 없는 문장(S2), 출처 없는 수치·사례(S3) —
를 세어서 승인 전에 사람에게 보여준다. 고치지 않는다.

CLI:
    scan        --src <md> [--lexicon <txt>] [--json]
    extract-llm --final <final.md> --out <11_slop.json>
    compare     --before <원본> --after <candidate> [--lexicon <txt>]
                [--llm <11_slop.json>] [--judge <11_slop_judge.json>]
                [--out <11_slop.json>] [--pending <pending.txt>]

구현 제약:
    - Python 3.11, 표준 라이브러리만. PyYAML·konlpy 금지.
    - md_shield.py 를 import 하지 않는다. 코드펜스·표·헤딩 판별은 같은 기준의
      자체 정규식으로 재현한다(설계 스펙 §2-1).
    - exit code 는 항상 0이다(argparse 사용법 오류만 2). 게이트 exit 에 기여하지 않는다.
    - 출력 스키마는 llm_signature.metric() 계약과 같다. 그 모듈을 import 하면
      md_shield 까지 딸려오므로 같은 형태를 여기서 다시 정의한다.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import traceback
from pathlib import Path

DEFAULT_LEXICON = Path(__file__).resolve().parent.parent / "references" / "slop-lexicon.txt"

# ---------------------------------------------------------------------------
# 1. 보호 구간 판별 — md_shield.py 와 같은 기준을 자체 정규식으로 재현한다
# ---------------------------------------------------------------------------

FENCE_OPEN_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")
FENCE_CLOSE_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})[ \t]*$")
HEADING_RE = re.compile(r"^ {0,3}(#{1,6})(?:\s+(.*))?$")
TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$")
TABLE_ROW_RE = re.compile(r"^\s*\|")
LIST_MARKER_RE = re.compile(r"^ {0,3}([-*+]|\d{0,9}[.)])(?:\s+|$)")

# 문장 분리 — `다.`·`요.`·`까?` 뒤 공백 기준. `습니다.` 는 `다.` 에 포함된다.
SENT_SPLIT_RE = re.compile(r"(?<=다\.)\s+|(?<=요\.)\s+|(?<=까\?)\s+")

SECTION_RE = re.compile(r"^\[([A-Za-z0-9_]+)\]$")
LEXICON_SECTIONS = ("S1_certainty", "S2_filler", "S3_claim", "S3_evidence")


def is_fence_close(line: str, fence_char: str, n: int) -> bool:
    m = FENCE_CLOSE_RE.match(line)
    if not m:
        return False
    run = m.group(1)
    return run[0] == fence_char and len(run) >= n


# ---------------------------------------------------------------------------
# 2. lexicon 로더
# ---------------------------------------------------------------------------


def load_lexicon(path) -> dict[str, list[dict]] | None:
    p = Path(path)
    if not p.exists():
        return None
    sections: dict[str, list[dict]] = {name: [] for name in LEXICON_SECTIONS}
    current = None
    for raw in p.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = SECTION_RE.match(line)
        if m:
            name = m.group(1)
            if name in LEXICON_SECTIONS:
                current = name
            else:
                print(f"slop_scan: lexicon 알 수 없는 절 [{name}] 무시", file=sys.stderr)
                current = None
            continue
        if current is None:
            continue
        body = line
        label = None
        if "=>" in body:
            body, label = (x.strip() for x in body.split("=>", 1))
        if body.startswith("re:"):
            pattern = body[3:].strip()
            try:
                compiled = re.compile(pattern)
            except re.error as e:
                print(
                    f"slop_scan: lexicon 정규식 오류 무시 [{current}] {line!r}: {e}",
                    file=sys.stderr,
                )
                continue
            sections[current].append({"term": label or pattern, "re": compiled})
        else:
            sections[current].append({"term": label or body, "re": re.compile(re.escape(body))})
    return sections


# ---------------------------------------------------------------------------
# 3. 산문 추출 — 보호 구간을 건너뛰고 (줄번호, 텍스트) 로 돌려준다
# ---------------------------------------------------------------------------


def prose_units(text: str) -> tuple[list[tuple[int, str]], str, set[int]]:
    """산문 줄 목록, 문서 차원 근거 코퍼스, 코드펜스 줄번호 집합을 돌려준다.

    근거 코퍼스는 표 행과 코드펜스 안 내용을 이어붙인 문자열이다 — S3 의
    "같은 수치가 문서 안 표나 코드 블록에도 나오면 근거 있음" 예외에 쓴다.
    빈 줄은 텍스트가 빈 항목으로 그대로 남긴다(문단 경계 판정에 필요하다).
    """
    lines = text.splitlines()
    units: list[tuple[int, str]] = []
    evidence: list[str] = []
    fence_lines: set[int] = set()

    i = 0
    if lines and lines[0].strip() == "---":
        for j in range(1, len(lines)):
            if lines[j].strip() == "---":
                i = j + 1
                break

    fence_char: str | None = None
    fence_n = 0
    while i < len(lines):
        line = lines[i]
        lineno = i + 1
        if fence_char is not None:
            fence_lines.add(lineno)
            if is_fence_close(line, fence_char, fence_n):
                fence_char = None
            else:
                evidence.append(line)
            i += 1
            continue
        m = FENCE_OPEN_RE.match(line)
        if m:
            run = m.group(1)
            fence_char, fence_n = run[0], len(run)
            fence_lines.add(lineno)
            i += 1
            continue
        if HEADING_RE.match(line):
            i += 1
            continue
        if TABLE_SEP_RE.match(line) or TABLE_ROW_RE.match(line):
            evidence.append(line)
            i += 1
            continue
        units.append((lineno, LIST_MARKER_RE.sub("", line, count=1)))
        i += 1
    return units, "\n".join(evidence), fence_lines


# ---------------------------------------------------------------------------
# 4. 문장·문단 분리
# ---------------------------------------------------------------------------


def sentences(units: list[tuple[int, str]]) -> list[dict]:
    """산문 줄들을 문단(빈 줄 경계) → 문장으로 쪼갠다. 항목은 {line, text, para}."""
    out: list[dict] = []
    buf: list[tuple[int, str]] = []
    para_idx = 0

    def flush() -> None:
        nonlocal buf, para_idx
        if not buf:
            return
        para_idx += 1
        parts: list[str] = []
        offsets: list[tuple[int, int]] = []
        pos = 0
        for line_no, text in buf:
            t = text.strip()
            if not t:
                continue
            offsets.append((pos, line_no))
            parts.append(t)
            pos += len(t) + 1
        joined = " ".join(parts)
        cursor = 0
        for piece in SENT_SPLIT_RE.split(joined):
            idx = joined.find(piece, cursor)
            if idx < 0:
                idx = cursor
            cursor = idx + len(piece)
            s = piece.strip()
            if not s:
                continue
            line_no = offsets[0][1] if offsets else 0
            for off, ln in offsets:
                if off <= idx:
                    line_no = ln
                else:
                    break
            out.append({"line": line_no, "text": s, "para": para_idx})
        buf = []

    for line_no, text in units:
        if not text.strip():
            flush()
            continue
        buf.append((line_no, text))
    flush()
    return out


# ---------------------------------------------------------------------------
# 5. metric 계약 — llm_signature.metric() 과 같은 형태
# ---------------------------------------------------------------------------


def metric(id_: str, label: str, kind: str, raw: dict, value: float, triggered: bool, note: str) -> dict:
    return {
        "id": id_,
        "label": label,
        "kind": kind,
        "raw": raw,
        "value": round(max(0.0, min(1.0, value)), 4),
        "triggered": bool(triggered),
        "note": note,
    }


# ---------------------------------------------------------------------------
# 5c. 집계 — 지표는 Task 2~4 가 하나씩 채운다
# ---------------------------------------------------------------------------


def scan_text(text: str, lex: dict) -> dict:
    units, _evidence, _fence_lines = prose_units(text)
    _sents = sentences(units)
    return {"metrics": [], "hits": []}


# ---------------------------------------------------------------------------
# 6. 입출력 헬퍼
# ---------------------------------------------------------------------------


def read_text(path: str) -> str | None:
    try:
        return Path(path).read_bytes().decode("utf-8")
    except OSError as e:
        print(f"오류: 파일을 읽을 수 없습니다: {e}", file=sys.stderr)
        return None
    except UnicodeDecodeError as e:
        print(f"오류: UTF-8 디코딩 실패: {e}", file=sys.stderr)
        return None


# ---------------------------------------------------------------------------
# 7. CLI
# ---------------------------------------------------------------------------


def print_scan_table(file_: str, result: dict) -> None:
    """형식은 llm_signature.print_score_table 을 따른다 — Phase 4 가 두 표를
    같은 진단문에 이어 붙이므로 모양이 갈리면 읽기 나빠진다."""
    print(f"파일: {file_}  (초안 관문 — 수정 안 함)")
    print(f"{'ID':<4} {'라벨':<12} {'종류':<8} {'값':>6} {'발동':>6}  근거")
    print("-" * 90)
    for m in result["metrics"]:
        mark = "O" if m["triggered"] else "-"
        print(f"{m['id']:<4} {m['label']:<12} {m['kind']:<8} {m['value']:>6.2f} {mark:>6}  {m['note']}")
    print("-" * 90)
    triggered = [m["id"] for m in result["metrics"] if m["triggered"]]
    print(f"발동된 초안 관문 항목: {', '.join(triggered) if triggered else '없음'}")
    for h in result["hits"][:5]:
        print(f"  - {h['id']} (줄 {h['line']}, {h['term']}): {h['quote']}")


def cmd_scan(args: argparse.Namespace) -> int:
    lex = load_lexicon(args.lexicon)
    if lex is None:
        print(f"초안 관문: lexicon 파일 없음 — 스캔 건너뜀 ({args.lexicon})")
        return 0
    text = read_text(args.src)
    if text is None:
        return 0
    result = scan_text(text, lex)
    print_scan_table(args.src, result)
    if args.json:
        payload = {
            "file": args.src,
            "metrics": result["metrics"],
            "hits": result["hits"],
            "triggered": [m["id"] for m in result["metrics"] if m["triggered"]],
        }
        print(json.dumps(payload, ensure_ascii=False))
    return 0


def cmd_extract_llm(args: argparse.Namespace) -> int:
    print("extract-llm: 미구현")
    return 0


def cmd_compare(args: argparse.Namespace) -> int:
    print("compare: 미구현")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="slop_scan.py", description="게이트 S(초안 관문) 결정적 스캐너")
    sub = p.add_subparsers(dest="command", required=True)

    ps = sub.add_parser("scan", help="문서 하나를 초안 관문 세 항목으로 스캔한다")
    ps.add_argument("--src", required=True)
    ps.add_argument("--lexicon", default=str(DEFAULT_LEXICON))
    ps.add_argument("--json", action="store_true", help="stdout 마지막 줄에 JSON 한 줄 추가")
    ps.set_defaults(func=cmd_scan)

    pe = sub.add_parser("extract-llm", help="final.md 의 HUMANIZE-SUMMARY 에서 slop_findings 를 뽑는다")
    pe.add_argument("--final", required=True)
    pe.add_argument("--out", required=True)
    pe.set_defaults(func=cmd_extract_llm)

    pc = sub.add_parser("compare", help="윤문 전/후를 대조해 11_slop.json 을 완성한다")
    pc.add_argument("--before", required=True)
    pc.add_argument("--after", required=True)
    pc.add_argument("--lexicon", default=str(DEFAULT_LEXICON))
    pc.add_argument("--llm", default=None, help="extract-llm 산출물(11_slop.json)")
    pc.add_argument("--judge", default=None, help="wwe-slop-judge 산출물(11_slop_judge.json)")
    pc.add_argument("--out", default=None, help="생략하면 --llm 경로에 덮어쓴다")
    pc.add_argument("--pending", default=None, help="생략하면 pending 줄을 stdout 에 낸다")
    pc.set_defaults(func=cmd_compare)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as e:  # noqa: BLE001 — CLI 최상위 안전망. exit 는 항상 0 이다.
        print(f"slop_scan: 내부 오류: {type(e).__name__}: {e}", file=sys.stderr)
        print(traceback.format_exc(), file=sys.stderr)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
