#!/usr/bin/env python3
"""UserPromptSubmit 훅: reply-check.py(advise 모드)가 남긴 pending 힌트를
다음 사용자 턴이 시작될 때 모델에게만 보이는 컨텍스트로 끼워 넣는다.

reply-check.py는 Stop 이벤트에서 돈다 — 답변이 이미 화면에 표시된 뒤다. 그
자리에서 decision:block을 내면 Claude가 같은 내용을 다시 써서 사용자가 답을
두 번 보게 된다. advise 모드에서는 그 대신 사유를 세션별 pending 파일에
적어두기만 하고, 이 훅이 다음 프롬프트 제출 시점에 그 파일을 읽어
additionalContext로 얹는다. 사용자 화면에는 안 보이고 모델 컨텍스트에만
들어간다.

stdin  (JSON): { session_id, transcript_path, cwd, hook_event_name, prompt, ... }
stdout (JSON): { "hookSpecificOutput": {...} }  — pending 이 있고 신선할 때만 출력
stderr       : 내부 오류 시 한 줄, exit 0
exit code    : 항상 0  (훅 때문에 프롬프트 제출이 막히는 사고는 없어야 한다)
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

_MAX_AGE_SECONDS = 6 * 60 * 60  # 6시간 — 이보다 오래된 pending은 더 이상 유효한 힌트가 아니다
_SWEEP_AGE_SECONDS = 24 * 60 * 60  # 24시간 — 이보다 오래된 파일은 기회될 때마다 청소
_REASON_TRUNCATE = 800  # 컨텍스트에 얹는 사유 길이 상한


def _err(msg: str) -> None:
    print(f"[reply-hint] {msg}", file=sys.stderr)


def _claude_config_dir() -> Path:
    """Claude Code 설정 디렉터리. CLAUDE_CONFIG_DIR 을 존중한다(기본 ~/.claude).

    reply-check.py의 동명 함수와 완전히 같은 구현이다 — pending 파일 경로가
    어긋나면 안 되므로 두 훅이 각자 독립적으로 계산해도 같은 값이 나와야 한다.
    """
    env = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    return Path(env).expanduser() if env else Path.home() / ".claude"


def _pending_dir() -> Path:
    return _claude_config_dir() / "hooks/state/reply-check"


_RE_UNSAFE_SESSION_CHARS = re.compile(r"[^A-Za-z0-9_-]")


def _sanitize_session_id(session_id: str) -> str:
    """reply-check.py의 _sanitize_session_id와 동일해야 같은 파일을 가리킨다."""
    return _RE_UNSAFE_SESSION_CHARS.sub("_", session_id.strip())[:200]


def _sweep_stale(pending_dir: Path) -> None:
    """24시간 넘은 pending 파일을 기회될 때 청소한다. 실패해도 무시 — 훅 본연의
    동작(이번 세션 힌트 전달)을 막으면 안 된다."""
    try:
        if not pending_dir.is_dir():
            return
        now = time.time()
        for f in pending_dir.glob("*.json"):
            try:
                if now - f.stat().st_mtime > _SWEEP_AGE_SECONDS:
                    f.unlink(missing_ok=True)
            except Exception:
                continue
    except Exception:
        pass


def _emit_context(text: str) -> None:
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": text,
        }
    }
    print(json.dumps(payload, ensure_ascii=False))


def main() -> None:
    try:
        raw = sys.stdin.read()
        inp = json.loads(raw)
    except Exception as exc:  # noqa: BLE001
        _err(f"stdin parse failed: {exc}")
        sys.exit(0)

    session_id = str(inp.get("session_id", ""))

    pending_dir = _pending_dir()
    _sweep_stale(pending_dir)

    safe = _sanitize_session_id(session_id)
    if not safe:
        sys.exit(0)

    path = pending_dir / f"{safe}.json"
    if not path.exists():
        sys.exit(0)

    try:
        rec = json.loads(path.read_text(encoding="utf-8"))
        ts = float(rec.get("ts", 0))
        reason = str(rec.get("reason", "")).strip()
    except Exception as exc:  # noqa: BLE001
        _err(f"pending 파일 읽기 실패: {exc}")
        try:
            path.unlink(missing_ok=True)
        except Exception:  # noqa: BLE001
            pass
        sys.exit(0)

    # 읽었으면(신선하든 아니든) 지운다 — 최신 답변 하나만 의미가 있고, 지우지
    # 않으면 다음 턴에도 같은 힌트가 반복된다.
    try:
        path.unlink(missing_ok=True)
    except Exception as exc:  # noqa: BLE001
        _err(f"pending 파일 삭제 실패: {exc}")

    age = time.time() - ts
    if age > _MAX_AGE_SECONDS or not reason:
        sys.exit(0)

    if len(reason) > _REASON_TRUNCATE:
        reason = reason[:_REASON_TRUNCATE].rstrip() + " …"

    text = "직전 답변이 말투 검사에 걸렸다. 이번 답변에서는 다음을 피한다:\n" + reason
    _emit_context(text)
    sys.exit(0)


if __name__ == "__main__":
    main()
