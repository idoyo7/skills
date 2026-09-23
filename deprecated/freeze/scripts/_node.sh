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

# ---------------------------------------------------------------------------
# (d) reservation.json 쓰기·읽기 공용 JS 조각.
#
# 배경(blocker): writeFileSync 는 O_TRUNC 후 write 라 관측 가능하게 비원자적이다.
# 예전엔 cmd_reserve 가 reservation.json 을 쓰고 슬리퍼(thaw.sh)를 띄운 뒤 cmd_arm 이
# 같은 파일에 두 번째 read-modify-write(chain/chain_left/via)를 했고, 기동 직후
# 밀리초 안에 field() 로 resume_at 을 읽는 thaw.sh 가 그 truncate~write 창에 걸렸다
# (프리미티브 측정: 171,167회 읽기 중 971회 = 0.57% JSON.parse 실패, arm 회당 재현율 약 3%).
# 결과는 "5시간 뒤에 뜨기로 한 헤드리스 세션이 지금 뜬다" 였다 — 빈 resume_at 이
# 산술 확장에서 0 으로 읽혀 대기 루프가 즉시 탈출했기 때문.
#
# 세 겹으로 막는다: (1) 체인 필드를 첫 쓰기에 합쳐 두 번째 쓰기를 없앴다(freeze.sh),
# (2) 남은 모든 쓰기를 아래 writeJsonAtomic 으로 원자화, (3) 읽기를 fail-closed 로
# 바꿨다(아래 FREEZE_JS_FIELD + thaw.sh 의 정수 검사).
#
# 왜 .js 파일이 아니라 문자열 변수인가: 이 코드베이스의 JSON 조작은 전부
# `node -e '...'` 인라인이고 .js 파일이 하나도 없다. freeze.sh 와 thaw.sh 는 서로를
# source 하지 않지만 둘 다 이 파일을 source 하므로, 공유 위치는 여기가 맞다.
# 호출 지점은 인접한 두 인용 문자열을 셸이 한 단어로 붙이는 성질을 써서 앞세운다:
#   node -e "$FREEZE_JS_ATOMIC"'
#   ...
#   writeJsonAtomic(p, d);
#   ' "$RES" ...
# 식별자에 _A/_F 접미를 붙인 이유: `node -e` 의 코드는 한 스코프에서 돌기 때문에
# 호출부의 `const fs = require("fs")` 와 이름이 겹치면 SyntaxError 로 즉사한다.

# 원자적 JSON 쓰기 — 같은 디렉토리의 임시 파일에 다 쓴 뒤 renameSync 로 갈아치운다.
# 같은 디렉토리 = 같은 파일시스템이라 rename(2) 은 원자적이고, 읽는 쪽은 완전한 옛
# 내용이나 완전한 새 내용 중 하나만 본다(잘린 중간 상태가 존재하지 않는다).
# 임시 파일 이름을 점으로 시작하게 두는 이유: `"$STATE_ROOT"/*/reservation.json` 같은
# 기존 글롭에 절대 걸리지 않게.
FREEZE_JS_ATOMIC='
const _fsA = require("fs"), _pathA = require("path");
function writeJsonAtomic(p, obj) {
  const tmp = _pathA.join(_pathA.dirname(p), "." + _pathA.basename(p) + ".tmp." + process.pid);
  _fsA.writeFileSync(tmp, JSON.stringify(obj, null, 2));
  try { _fsA.renameSync(tmp, p); }
  catch (e) { try { _fsA.unlinkSync(tmp); } catch (e2) { /* 청소 실패는 원 에러를 가리지 않는다 */ } throw e; }
}
'

# 필드 하나 읽기 — argv: <path> <key>. 값이 없으면 빈 문자열.
# 파싱 실패를 곧바로 실패로 보지 않고 20ms 간격으로 짧게 재시도한다(쓰기 창은 밀리초
# 단위다). 위 (2)로 원자적 쓰기가 보장된 뒤엔 이 경로에 도달할 일이 사실상 없지만,
# 새 쓰기 지점이 규칙을 어겼을 때를 위한 방어 깊이로 남긴다.
# 끝까지 실패하면 stdout 을 비우고 비영 종료코드(3)를 낸다 — 여기서 빈 문자열을
# 성공으로 돌려주는 게 바로 fail-open 이었다(호출자가 산술 확장에서 0 으로 읽는다).
# Atomics.wait 로 자는 이유: 동기 대기라야 이 한 줄짜리 스크립트 구조가 유지된다
# (node 메인 스레드에서 허용된다 — 브라우저와 다르다).
FREEZE_JS_FIELD='
const _fsF = require("fs");
const _pF = process.argv[1], _kF = process.argv[2];
let _errF;
for (let _i = 0; _i < 10; _i++) {
  try {
    const _dF = JSON.parse(_fsF.readFileSync(_pF));
    process.stdout.write(String(_dF[_kF] ?? "") + "\n");
    process.exit(0);
  } catch (e) {
    _errF = e;
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
  }
}
process.stderr.write("field: 읽기 실패 " + _pF + " [" + _kF + "] — " + (_errF && _errF.message) + "\n");
process.exit(3);
'
