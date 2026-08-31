#!/usr/bin/env bash
# _claude.sh — claude 실행 파일 탐색 함수 정의 전용. source 전용, 단독 실행하지 않는다.
#
# 배경: thaw.sh 는 지금 CLAUDE_BIN="${FREEZE_CLAUDE_BIN:-$HOME/.local/bin/claude}" 로
# 고정돼 있다. 리눅스 기본 설치는 대체로 그 경로에 있지만, 맥은 homebrew·npm 전역·
# ~/.claude/local 어디든 있을 수 있고, 비대화형 ssh PATH(예: `/usr/bin:/bin:/usr/sbin:/sbin`)엔
# claude 가 아예 없다 — claude 도 보통 `.zshrc`/`.bashrc` 에서만 PATH 에 붙기 때문이다.
# _node.sh 가 node 를 찾는 것과 같은 사다리를 claude 에도 둔다.
#
# _node.sh 와 다른 큰 차이 하나 — 이 파일은 source 만으로 즉사하지 않는다. freeze.sh 의
# status/cancel/estimate 는 claude 실행 파일 없이도 동작해야 하므로, 실제 탐색은
# resolve_claude_bin 함수를 "호출"하는 시점으로 미룬다. 이 파일 자체는 함수 정의만 한다.
#
# 사용: SCRIPT_DIR 확정 직후 `source ".../_claude.sh"`, 필요한 시점에 `resolve_claude_bin`
# 을 직접 불러라.
#   성공: stdout 에 절대경로 한 줄, exit 0 (FREEZE_CLAUDE_BIN 도 그 값으로 export 된다 —
#         thaw.sh, 그리고 thaw.sh 가 체인 재무장으로 되부르는 `freeze.sh arm` 이 같은
#         실행 파일을 쓰게 하려는 것. _node.sh 의 FREEZE_NODE_BIN export 와 같은 방어다.)
#   실패: stderr 에 탐색 사다리 설명, 비영 exit

resolve_claude_bin() {
  # 1. 사용자·부모 프로세스가 이미 지정한 값 — 존중하되, 실행 불가면 다른 후보로
  #    조용히 새지 않고 즉시 실패한다. 명시로 지정했다는 건 "이 경로를 써라"는
  #    뜻이지 "이게 없으면 알아서 딴 걸 골라라"가 아니다.
  if [ -n "${FREEZE_CLAUDE_BIN:-}" ]; then
    if [ -x "$FREEZE_CLAUDE_BIN" ]; then
      export FREEZE_CLAUDE_BIN
      echo "$FREEZE_CLAUDE_BIN"
      return 0
    fi
    echo "ERROR: FREEZE_CLAUDE_BIN 이 실행 불가 — $FREEZE_CLAUDE_BIN" >&2
    return 1
  fi

  local c
  if c=$(command -v claude 2>/dev/null) && [ -x "$c" ]; then
    # command -v 는 PATH 에 상대 디렉토리 항목이 있으면 상대경로를 그대로 낼 수 있다
    # (리뷰 MINOR). thaw.sh 는 이 값을 export 해 몇 시간 뒤 독립 프로세스로 쓰는데,
    # 그 사이 cd "$CWD" 를 하므로 상대경로면 다른 파일을 가리키거나 실행에 실패한다.
    # node realpathSync 로 절대화한다(freeze.sh:normalize_handoff 와 같은 패턴) —
    # _node.sh 가 이 파일보다 먼저 source 돼 있어야 한다(모든 실제 호출부가 그렇게
    # 하고 있다). 실패하면(예외적 상황) command -v 가 낸 값을 그대로 쓴다.
    FREEZE_CLAUDE_BIN=$(node -e '
try { console.log(require("fs").realpathSync(process.argv[1])); }
catch { console.log(process.argv[1]); }
' -- "$c")
    [ -n "$FREEZE_CLAUDE_BIN" ] || FREEZE_CLAUDE_BIN="$c"        # 2. PATH
  elif [ -x "$HOME/.local/bin/claude" ]; then
    FREEZE_CLAUDE_BIN="$HOME/.local/bin/claude"                 # 3. 지금까지의 고정값(리눅스 기본)
  elif [ -x "$HOME/.claude/local/claude" ]; then
    FREEZE_CLAUDE_BIN="$HOME/.claude/local/claude"              # 4. claude 자체 로컬 설치
  elif [ -x /opt/homebrew/bin/claude ]; then
    FREEZE_CLAUDE_BIN=/opt/homebrew/bin/claude                  # 5. apple silicon homebrew
  elif [ -x /usr/local/bin/claude ]; then
    FREEZE_CLAUDE_BIN=/usr/local/bin/claude                     # 6. intel mac homebrew / 일부 리눅스
  elif [ -x "$HOME/.bun/bin/claude" ]; then
    FREEZE_CLAUDE_BIN="$HOME/.bun/bin/claude"                   # 7. bun 전역 설치
  else
    # 8. nvm 전용 디렉토리 글롭. _node.sh 와 같은 근사(사전식 역순 정렬이라
    # "v9.x" 가 "v10.x" 보다 뒤로 밀리는 한계가 있다 — 폴백의 폴백이라 감수한다).
    local found="" ver
    for ver in $(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -r); do
      if [ -x "$HOME/.nvm/versions/node/$ver/bin/claude" ]; then
        found="$HOME/.nvm/versions/node/$ver/bin/claude"
        break
      fi
    done
    if [ -n "$found" ]; then
      FREEZE_CLAUDE_BIN="$found"
    elif [ -x "$HOME/.npm-global/bin/claude" ]; then
      FREEZE_CLAUDE_BIN="$HOME/.npm-global/bin/claude"          # 9. npm 전역 설치
    fi
  fi

  if [ -z "${FREEZE_CLAUDE_BIN:-}" ] || [ ! -x "$FREEZE_CLAUDE_BIN" ]; then
    unset FREEZE_CLAUDE_BIN
    cat >&2 <<'EOF'
ERROR: claude 실행 파일을 찾지 못했다. 다음 중 하나로 해결해라:
  - FREEZE_CLAUDE_BIN=<절대경로> 로 직접 지정
  - PATH 에 claude 를 추가 (예: PATH 를 물려주는 셸 설정 파일 확인)
  - 다음 위치 중 하나에 설치: ~/.local/bin, ~/.claude/local, /opt/homebrew/bin,
    /usr/local/bin, ~/.bun/bin, ~/.nvm/versions/node/*/bin, ~/.npm-global/bin
EOF
    return 1
  fi

  export FREEZE_CLAUDE_BIN
  echo "$FREEZE_CLAUDE_BIN"
  return 0
}
