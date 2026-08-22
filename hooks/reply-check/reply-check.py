#!/usr/bin/env python3
"""Stop hook: 마지막 assistant 메시지의 한국어 산문 품질을 점검한다.

stdin  (JSON): { session_id, transcript_path, stop_hook_active, hook_event_name }
stdout (JSON): { "decision": "block", "reason": "..." }  — 막을 때만 출력
stderr       : 내부 오류 시 한 줄, exit 0
exit code    : 항상 0  (훅이 세션을 죽이는 사고는 없어야 한다)
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import sys
import time
from collections import Counter
from pathlib import Path

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------

# 심링크를 통해 실행될 때 resolve()하면 저장소 실제 경로가 된다.
# hooks/reply-check/reply-check.py → ../../wwe/ 로 올라가면 wwe/ 디렉터리
_SELF_DIR = Path(__file__).resolve().parent


def _find_path(relative_from_self: str, *fallbacks: Path) -> Path:
    """심링크 resolve 기준 경로를 먼저 시도하고, 없으면 fallback 순서로 반환한다."""
    primary = (_SELF_DIR / relative_from_self).resolve()
    if primary.exists():
        return primary
    for fb in fallbacks:
        if fb.exists():
            return fb
    return primary  # 없어도 primary 반환 (호출 시 exists() 확인)


_METRICS_V2_PATH = (
    Path.home()
    / ".claude/plugins/marketplaces/im-not-ai/.claude/skills/humanize-korean/references/metrics_v2.py"
)

_AUTHOR_TICS_PATH = _find_path(
    "../../wwe/references/author-tics.txt",
    Path.home() / "evejuni/skills/wwe/references/author-tics.txt",
    Path.home() / ".claude/skills/wwe/references/author-tics.txt",
)

_AUTHOR_REPEAT_PATH = _find_path(
    "../../wwe/scripts/author_repeat.py",
    Path.home() / "evejuni/skills/wwe/scripts/author_repeat.py",
)

_LOG_PATH = Path.home() / ".claude/hooks/logs/reply-check.jsonl"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _err(msg: str) -> None:
    print(f"[reply-check] {msg}", file=sys.stderr)


def _log(rec: dict) -> None:
    try:
        _LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(_LOG_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except Exception as e:  # noqa: BLE001
        _err(f"log write failed: {e}")


def _block(reason: str) -> None:
    print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))


# ---------------------------------------------------------------------------
# transcript parsing
# ---------------------------------------------------------------------------

_TAIL_BYTES = 200_000  # 긴 transcript는 끝에서 역방향으로 탐색


def _load_last_assistant(transcript_path: str) -> str:
    """마지막 assistant 레코드에서 text 블록만 합쳐 반환한다."""
    path = Path(transcript_path)
    if not path.exists():
        return ""
    with open(path, "rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        fh.seek(max(0, size - _TAIL_BYTES))
        data = fh.read()
    lines = data.decode("utf-8", errors="replace").splitlines()
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") != "assistant":
            continue
        content = obj.get("message", {}).get("content", [])
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = [
                blk["text"]
                for blk in content
                if isinstance(blk, dict) and blk.get("type") == "text"
            ]
            return "\n".join(parts)
        return ""
    return ""


# ---------------------------------------------------------------------------
# text cleaning
# ---------------------------------------------------------------------------

_RE_CODE_FENCE = re.compile(r"```[\s\S]*?```", re.MULTILINE)
_RE_INLINE_CODE = re.compile(r"`[^`\n]+`")
_RE_URL = re.compile(r"https?://\S+")
_RE_TABLE_ROW = re.compile(r"^\|.*$", re.MULTILINE)
_RE_HEADING = re.compile(r"^#{1,6}\s.*$", re.MULTILINE)


def _clean(text: str) -> str:
    text = _RE_CODE_FENCE.sub(" ", text)
    text = _RE_INLINE_CODE.sub(" ", text)
    text = _RE_URL.sub(" ", text)
    text = _RE_TABLE_ROW.sub(" ", text)
    text = _RE_HEADING.sub(" ", text)
    return text


def _korean_ratio(text: str) -> float:
    non_ws = [c for c in text if not c.isspace()]
    if not non_ws:
        return 0.0
    korean = sum(1 for c in non_ws if "가" <= c <= "힣")
    return korean / len(non_ws)


def _split_sentences(text: str) -> list[str]:
    r"""[.?!]\s 또는 줄바꿈으로 문장 분리."""
    parts = re.split(r"(?<=[.?!。])\s+|\n+", text)
    return [s.strip() for s in parts if s.strip()]


# ---------------------------------------------------------------------------
# axis 1: 무생물·추상 주어 + 타동사
# ---------------------------------------------------------------------------

# 자체 정규식: 주어부가 ~느냐가|~는지가|~것이|~점이|~성이|~도가 로 끝나고
#             뒤에 타동사가 오는 패턴
_RE_INANI = re.compile(
    # (a) 명사절 주어: ~느냐가/~는지가/~것이/~점이/~성이/~도가 + 타동사
    r"[가-힣]+(?:느냐가|는지가|것이|점이|성이|도가)\s+"
    r"(?:[가-힣]+\s+){0,5}"
    r"(?:정했다|결정했다|만들었다|가져왔다|바꿨다|이끌었다|낳았다|좌우했다)"
    # (b) 추상 명사 주어 + 목적어 + 추상 타동사 (예: "반응이 방향을 결정했다", "도구가 성공을 가져왔고")
    r"|[가-힣]+(?:이|가)\s+(?:[가-힣]+\s+){0,3}[가-힣]+(?:을|를)\s+"
    r"(?:정했|결정했|결정한|만들었|가져왔|가져다|바꿨|바꾸었|이끌었|낳았|낳는|좌우했|좌우한|보여줬|보여준|말해준|말해줬|드러냈|드러낸|증명했|증명한|입증했|가른|갈랐|결정짓)"
)


def _check_axis1(text: str) -> tuple[float | None, int, list[str]]:
    """(metrics_v2 rate or None, regex_hit_count, example_sentences)."""
    rate: float | None = None
    if _METRICS_V2_PATH.exists():
        try:
            spec = importlib.util.spec_from_file_location("_metrics_v2", _METRICS_V2_PATH)
            assert spec and spec.loader
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)  # type: ignore[union-attr]
            rate = float(mod.inanimate_subject_rate(text))
        except Exception as exc:
            _err(f"metrics_v2 load failed: {exc}")

    matches = _RE_INANI.findall(text)
    return rate, len(matches), matches


# ---------------------------------------------------------------------------
# axis 2: 반복 구절
# ---------------------------------------------------------------------------

# 기본 내장 시드 — 흔한 AI 글쓰기 tic 패턴
_DEFAULT_SEEDS: list[str] = [
    "결론적으로",
    "요약하면",
    "시사하는 바",
    "주목할 만하다",
    "라고 할 수 있다",
    "살펴보면",
    "짚어볼 필요",
    "다양한 측면",
    "이라고 할 수",
    "이에 따라",
    # 작성자(Claude) 고유 반복구 — author-tics.txt가 없을 때의 폴백
    "갈랐다", "따로 논다", "뿌리가 된", "거칠다", "못박았다", "못박아뒀다",
    "손은 내가 댔다", "하는 자리다", "한눈에", "모양새", "셈이다", "그 지점",
]

# 용언 어간 추출을 위한 정규식
_RE_VERB_FORM = re.compile(
    r"([가-힣]{2,})"
    r"(?:했다|한다|하는|하여|하고|됩니다|됐다|됐습니다|있습니다|없습니다|"
    r"했습니다|합니다|했어요|해요|였다|이다|이며|이고|라고|로서|로써)"
)


def _load_seeds() -> list[str]:
    seeds = list(_DEFAULT_SEEDS)
    if _AUTHOR_TICS_PATH.exists():
        try:
            with open(_AUTHOR_TICS_PATH, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    # "표현 => 대체 지시" 형식 — 표현만 쓴다
                    key = line.split("=>", 1)[0].strip()
                    if key:
                        seeds.append(key)
        except Exception as exc:
            _err(f"author-tics.txt read failed: {exc}")
    return seeds


def _check_axis2(text: str) -> tuple[list[str], str | None, int]:
    """(seed_hits, top_stem, top_stem_count).

    author_repeat.py가 있으면 import해서 사용, 없으면 시드+어간 정규식만.
    """
    # author_repeat.py 우선 시도
    if _AUTHOR_REPEAT_PATH.exists():
        try:
            spec = importlib.util.spec_from_file_location("_author_repeat", _AUTHOR_REPEAT_PATH)
            assert spec and spec.loader
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)  # type: ignore[union-attr]
            # 공개 함수가 있으면 사용 — 없으면 아래 fallback
            if hasattr(mod, "check_repeats"):
                return mod.check_repeats(text, seed_path=str(_AUTHOR_TICS_PATH))
        except Exception as exc:
            _err(f"author_repeat.py load failed: {exc}")

    # Fallback: 시드 파일 정규식 + 어간 카운트
    seeds = _load_seeds()
    seed_hits: list[str] = []
    for seed in seeds:
        pattern = re.compile(re.escape(seed))
        count = len(pattern.findall(text))
        if count >= 1:
            seed_hits.append(f"{seed} ×{count}")

    stems = _RE_VERB_FORM.findall(text)
    c = Counter(stems)
    most = c.most_common(1)
    top_stem = most[0][0] if most else None
    top_count = most[0][1] if most else 0

    return seed_hits, top_stem, top_count


# ---------------------------------------------------------------------------
# axis 3: 읽기 난도
# ---------------------------------------------------------------------------

def _check_axis3(text: str) -> tuple[float, float, list[str]]:
    """(avg_len, pct_long_sents, long_sent_examples)."""
    sents = _split_sentences(text)
    if not sents:
        return 0.0, 0.0, []
    lens = [len(s) for s in sents]
    avg = sum(lens) / len(lens)
    long_sents = [s for s in sents if len(s) > 60]
    pct_long = len(long_sents) / len(sents)
    # 90자 넘는 문장이 하나라도 있으면 비율과 무관하게 히트로 취급한다.
    very_long = [s for s in sents if len(s) >= 90]
    if very_long:
        pct_long = max(pct_long, 0.30)
        long_sents = very_long + [s for s in long_sents if s not in very_long]
    return avg, pct_long, long_sents


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> None:
    # stdin 파싱
    try:
        raw = sys.stdin.read()
        inp = json.loads(raw)
    except Exception as exc:
        _err(f"stdin parse failed: {exc}")
        sys.exit(0)

    session_id: str = str(inp.get("session_id", ""))
    transcript_path: str = str(inp.get("transcript_path", ""))
    stop_hook_active: bool = bool(inp.get("stop_hook_active", False))

    # 이미 한 번 막고 재작성한 결과면 절대 다시 막지 않는다
    if stop_hook_active:
        sys.exit(0)

    if not transcript_path:
        _err("transcript_path 없음")
        sys.exit(0)

    # transcript에서 마지막 assistant 메시지 추출
    try:
        raw_text = _load_last_assistant(transcript_path)
    except Exception as exc:
        _err(f"transcript 읽기 실패: {exc}")
        sys.exit(0)

    cleaned = _clean(raw_text)
    kr_ratio = _korean_ratio(cleaned)
    char_count = len(cleaned.replace(" ", "").replace("\n", ""))

    log_rec: dict = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "session": session_id,
        "chars": char_count,
        "inanimate_rate": None,
        "seed_hits": 0,
        "avg_len": 0.0,
        "blocked": False,
    }

    # 한글 비율 30% 미만이거나 120자 미만이면 스킵
    if kr_ratio < 0.30 or char_count < 120:
        _log(log_rec)
        sys.exit(0)

    # ── axis 1 ──────────────────────────────────────────────────────────────
    a1_rate, a1_regex_hits, a1_examples = _check_axis1(cleaned)
    log_rec["inanimate_rate"] = a1_rate

    a1_fail = False
    a1_reason_lines: list[str] = []
    if a1_rate is not None and a1_rate >= 0.25:
        a1_fail = True
        a1_reason_lines.append(f"- 무생물·추상 주어: rate={a1_rate:.2f}")
    if a1_regex_hits >= 2:
        a1_fail = True
        for ex in a1_examples[:2]:
            a1_reason_lines.append(f'- 무생물 주어: "{ex[:60]}"')

    # ── axis 2 ──────────────────────────────────────────────────────────────
    a2_seed_hits, a2_top_stem, a2_top_count = _check_axis2(cleaned)
    log_rec["seed_hits"] = len(a2_seed_hits)

    a2_fail = False
    a2_reason_lines: list[str] = []
    if len(a2_seed_hits) >= 1:
        a2_fail = True
        for h in a2_seed_hits[:2]:
            a2_reason_lines.append(f"- 반복 구절: {h[:60]}")
    if a2_top_stem and a2_top_count >= 4:
        a2_fail = True
        a2_reason_lines.append(f"- 반복 구절: {a2_top_stem} ×{a2_top_count}")

    # ── axis 3 ──────────────────────────────────────────────────────────────
    a3_avg, a3_pct, a3_long_sents = _check_axis3(cleaned)
    log_rec["avg_len"] = round(a3_avg, 1)

    a3_fail = a3_avg >= 45 or a3_pct >= 0.30
    a3_reason_lines: list[str] = []
    if a3_fail:
        for s in a3_long_sents[:2]:
            a3_reason_lines.append(f'- 긴 문장({len(s)}자): "{s[:60]}"')

    blocked = a1_fail or a2_fail or a3_fail
    log_rec["blocked"] = blocked
    _log(log_rec)

    if not blocked:
        sys.exit(0)

    # reason 구성
    reason_parts = ["[reply-check] 다시 써라 — 짧은 문장, 구체 주어, 비유 없이."]
    reason_parts.extend(a1_reason_lines)
    reason_parts.extend(a2_reason_lines)
    reason_parts.extend(a3_reason_lines)
    _block("\n".join(reason_parts))
    sys.exit(0)


if __name__ == "__main__":
    main()
