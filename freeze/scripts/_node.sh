#!/usr/bin/env bash
# _node.sh — node 실행 파일 탐색·export·함수 가리기 공용 파일.
# source 전용, 단독 실행하지 않는다.
#
# 배경: freeze 스크립트들은 경로 정규화·날짜 파싱·프로세스 detach·sha256 폴백을 전부
# node 로 한다. 그런데 비대화형 ssh PATH(예: 맥 `/usr/bin:/bin:/usr/sbin:/sbin`)에는
# node 가 없을 수 있다 — node 는 보통 `.zshrc`/`.bashrc` 에서만 PATH 에 붙기 때문이다.
# 이 파일은 여러 후보 경로에서 node 를 찾아 FREEZE_NODE_BIN 으로 export 하고,
# `node` 를 그 경로를 호출하는 함수로 가려서 호출 지점을 한 곳도 안 건드린다.
#
# 사용: SCRIPT_DIR(테스트는 HERE) 확정 직후 `source ".../_node.sh"`.

# (a) 탐색 — 순서대로 첫 번째로 실행 가능한 후보를 쓴다.
if [ -n "${FREEZE_NODE_BIN:-}" ] && [ -x "${FREEZE_NODE_BIN:-}" ]; then
  : # 1. 사용자·부모 프로세스가 이미 지정한 값 — 존중하고 그대로 쓴다.
elif command -v node >/dev/null 2>&1; then
  FREEZE_NODE_BIN="$(command -v node)"      # 2. PATH
elif [ -x /opt/homebrew/bin/node ]; then
  FREEZE_NODE_BIN=/opt/homebrew/bin/node    # 3. apple silicon homebrew
elif [ -x /usr/local/bin/node ]; then
  FREEZE_NODE_BIN=/usr/local/bin/node       # 4. intel mac homebrew / 일부 리눅스
else
  # 5. nvm 전용 디렉토리 글롭. 버전 디렉토리명을 사전식 역순 정렬해 첫 번째를 쓴다 —
  # 사전식이라 "v9.x" 가 "v10.x" 보다 뒤로 밀리는 한계가 있다. 이건 폴백의 폴백이라
  # 근사로 충분하다.
  _freeze_nvm_found=""
  for _freeze_nvm_ver in $(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -r); do
    if [ -x "$HOME/.nvm/versions/node/$_freeze_nvm_ver/bin/node" ]; then
      _freeze_nvm_found="$HOME/.nvm/versions/node/$_freeze_nvm_ver/bin/node"
      break
    fi
  done
  [ -n "$_freeze_nvm_found" ] && FREEZE_NODE_BIN="$_freeze_nvm_found"
  unset _freeze_nvm_ver _freeze_nvm_found
fi

if [ -z "${FREEZE_NODE_BIN:-}" ] || [ ! -x "$FREEZE_NODE_BIN" ]; then
  echo "ERROR: node 를 찾지 못했다 — FREEZE_NODE_BIN 으로 경로를 직접 지정해라" >&2
  exit 1
fi

# (b) export — spawn_sleeper(freeze.sh) 가 node 의 child_process.spawn(detached:true) 으로
# thaw.sh 를 띄우는데, 자식 bash 는 부모 PATH 를 그대로 물려받는다. PATH 에 node 가 없는
# 환경이면 export 없이는 thaw.sh 가 field() 첫 호출에서 즉사한다. export 해두면 thaw.sh 가
# 이 파일을 source 할 때 (a)의 1번 후보로 바로 잡는다. thaw.sh 가 체인 재무장으로
# 되부르는 `bash freeze.sh arm` 에도 같은 이유로 전파된다.
export FREEZE_NODE_BIN

# (c) 함수로 가리기 — 호출 지점이 수십 곳(`node -e ...`, 히어독 포함)이라 전부
# "$FREEZE_NODE_BIN" 치환은 diff 가 커진다. 함수로 가리면 호출부를 한 줄도 안 건드린다.
# PATH 에 node 가 있는 환경에서는 (a)의 2번이 같은 node 를 잡으므로 동작이 완전히 같다.
#
# 순서 주의: 이 정의는 반드시 (a) 탐색이 끝난 뒤에 와야 한다. 먼저 정의하면 (a)의
# `command -v node` 가 PATH 의 실행 파일이 아니라 이 함수를 찾아 순환한다.
node() { "$FREEZE_NODE_BIN" "$@"; }
