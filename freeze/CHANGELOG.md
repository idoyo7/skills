# CHANGELOG

## 1.1.2 — 2026-08-29

PATH 에 node 가 없는 환경에서 스크립트가 첫 node 호출에 죽던 것을 막았다. 1.1.1 이 GNU 전제를 걷으면서 경로 정규화·날짜 파싱·프로세스 detach·sha256 폴백을 전부 node 로 옮겼는데, 정작 node 를 찾는 일은 PATH 에 맡겨두고 있었다.

- `_node.sh` 를 새로 두고 freeze.sh·thaw.sh·wfledger.sh·테스트가 source 한다. 탐색은 `FREEZE_NODE_BIN`, PATH, `/opt/homebrew/bin/node`, `/usr/local/bin/node`, nvm 글롭 순이고 전부 실패하면 명확한 에러와 비영 종료코드를 낸다. 맥의 비대화형 ssh PATH 는 `/usr/bin:/bin:/usr/sbin:/sbin` 뿐이라 homebrew 가 깐 node 가 안 잡혔다 — mac-run 이 ssh 로 작업을 넘기는 경로에서 실제로 밟는다.
- `node` 를 찾은 경로를 부르는 함수로 가린다. 호출 지점이 수십 곳(`node -e`, 히어독 포함)이라 전부 치환하면 diff 가 커진다. PATH 에 node 가 있는 환경에서는 같은 실행 파일이 잡히므로 동작이 같다. 함수 정의는 반드시 탐색 뒤에 와야 한다 — 먼저 정의하면 `command -v node` 가 실행 파일이 아니라 그 함수를 찾아 순환한다.
- 찾은 경로를 export 한다. `spawn_sleeper` 가 띄우는 thaw.sh 와 thaw.sh 가 되부르는 `freeze.sh arm` 이 같은 node 를 쓰게 하려는 방어다. 실제로는 bash 의 `VAR=val cmd` 접두 할당이 그 시점부터 환경에 넣어 손자까지 전파하고, 자식도 같은 사다리로 혼자 다시 찾으므로 현재 호출 경로에서 이 export 가 유일한 방어선인 자리는 없다. 그래서 회귀 테스트도 E2E 완주가 아니라 소싱 직후 `env` 노출 여부를 직접 본다 — export 를 지운 사본으로 돌려 그 단언만 FAIL 하는 것을 확인했다.

리눅스 PASS=110 FAIL=0, 맥 PASS=109 FAIL=0 SKIP=1(PATH 를 손대지 않은 맨 상태로 실행). 맥의 SKIP 1건은 "node 를 못 찾는 상황"이 재현되지 않은 것으로, `/opt/homebrew/bin/node` 가 실제로 잡힌다는 뜻이다.

## 1.1.1 — 2026-08-28

macOS/BSD 에서 스크립트가 실행 자체를 못 하던 결함들을 걷었다. GNU coreutils 와 bash 4 를 전제한 코드가 여러 곳에 있었다.

- `date -d` 를 걷었다. HH:MM 과 임의 문자열/ISO8601 파싱은 node 로 옮기고, epoch → 사람이 읽는 포맷은 `fmt_epoch` 로 감쌌다. GNU 는 `date -d @N`, BSD 는 `date -r N` 이고 GNU 의 `-r` 은 파일 mtime 이라 의미가 달라 분기가 필수다.
- `setsid nohup` 을 node `spawn(detached:true)` 로 바꿨다. macOS 에는 setsid 커맨드가 없다. detached 는 POSIX 에서 setsid(2) 를 호출하니 세션 분리 의미가 같고, PID 도 정확히 받는다.
- `normalize_handoff` 의 `realpath -m` 을 걷었다. `-m` 은 GNU 확장이라 BSD realpath 가 `illegal option` 으로 거부한다. 존재하는 최장 접두부만 심링크를 풀고 남은 조각을 붙여 같은 결과를 낸다.
- `sha256sum` 에 폴백을 뒀다 — `shasum -a 256`, 그다음 node crypto. freeze.sh 와 thaw.sh 가 마커 경로를 서로 맞춰 찾으므로 두 파일에 같은 순서를 둔다.
- `cmd_arm` 이 빈 배열을 `"${extra[@]}"` 로 전개해 bash 3.2(macOS 기본 셸)에서 unbound variable 로 즉사했다. `--pad`/`--session`/`--created-at` 없이 arm 을 부르는 기본 경로가 전부 걸렸다. `${extra[@]+...}` 로 고쳤다.
- `wfledger.sh` 가 여러 줄 값을 `awk -v` 로 넘겨 BSD awk 가 `newline in string` 으로 거부했다. 환경변수와 `ENVIRON` 으로 바꿨다 — `ENVIRON` 은 POSIX awk 라 두 구현 모두 지원하고 값에 개행이 들어가도 된다.
- `--at` 해석 결과에 sanity 검사를 넣었다. 숫자가 아니거나 지금부터 30일 밖이면 거부한다. `Date.parse("-5")` 가 2001년을, 오타 `5` 가 1970년을 조용히 통과시켜 thaw 가 즉시 깨거나 영원히 자던 사고를 막는다.

## 1.1.0

원장 기반 재개(ledger 모드)와 workflow-arm 훅, 선예약(arm) 모드와 체인 재무장.

## 1.0.0

얼음/땡 세션 예약 — 한도 리셋 후 헤드리스 자동 재개.
