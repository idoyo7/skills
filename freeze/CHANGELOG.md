# CHANGELOG

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
