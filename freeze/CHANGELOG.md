# CHANGELOG

## 1.1.3 — 2026-08-31

`arm` 으로 걸어둔 예약이 땡이 아니라 즉시 재개되던 blocker 를 고쳤고, 그 결함이 테스트에서 조용히 지나가게 만든 구조들을 함께 걷었다. `arm` 과 체인 선무장은 이 저장소에 들어온 뒤 실사용 이력이 없었고(오늘까지의 실제 재개는 전부 `reserve`), 스위트는 통과하면서 결함과 공존하고 있었다.

- **예약이 즉시 재개되던 레이스.** `cmd_reserve` 가 reservation.json 을 쓰고 곧바로 슬리퍼를 띄운 뒤 `cmd_arm` 이 같은 파일에 두 번째 read-modify-write 를 했다. 슬리퍼는 기동 후 밀리초 안에 그 파일을 읽으므로 `writeFileSync` 의 truncate~write 창과 겹쳤다. `field()` 가 파싱 실패를 빈 문자열로 흘리고 대기 루프가 그걸 산술 확장에서 0 으로 봐서 즉시 탈출했다 — 5시간 뒤에 뜰 헤드리스 세션이 지금 뜨고, `NEXT_AT` 이 18000 이 되어 체인 선무장까지 실패했다. 세 겹으로 막았다: 체인 필드를 유일한 첫 쓰기에 합쳐 두 번째 쓰기를 없애고(`cmd_reserve` 에 내부 인자 `--chain`/`--chain-left`/`--via` 추가), reservation.json 의 모든 쓰기를 임시파일 + `renameSync` 로 원자화하고(`_node.sh` 의 `FREEZE_JS_ATOMIC`, 호출 4곳), 파싱 실패를 재시도 후 **fail-closed** 로 바꿨다(`thaw.sh` 의 `die()`, `resume_at` 정수 검사). 동시 리더를 붙인 `arm` 실측 12%(18/150) → 0/150. 프리미티브 A/B 는 1.24%(388/31,281) → 0/110,847.
  - 대가: reservation.json 이 진짜로 깨지면 그 예약은 이제 영구히 안 뜬다. "예약이 안 도는 것보다 안 부른 세션이 뜨는 게 나쁘다"를 택했다. `status` 에 `sleeper=dead`, thaw.log 에 판정 로그가 남는다.
- **다음 창 해제와 부모 status 의 순서.** `thaw.sh` 가 부모를 `completed_early` 로 바꾼 뒤에 선무장된 자식을 cancel 해서, 그 사이를 관측하면 자식이 아직 `frozen` 이었다. 해제를 먼저 하도록 세 호출 지점을 `release_next_job()` 으로 통일했다(cancel 실패는 WARN 으로만 남기고 status 는 반드시 갱신). 이제 "부모가 완료로 보이면 자식은 이미 해제됐다"가 불변식이다.
- **테스트 하네스가 fail-open 이었다.** `set -euo pipefail` 아래에서 중간 명령이 비영 종료하면 `PASS=/FAIL=` 요약줄에 닿기 전에 죽어, 출력만으로는 정상 완주와 구분되지 않았다(종료코드만 1). `SUITE_COMPLETED` 플래그 + EXIT 트랩의 ABORTED 배너 + ERR 트랩으로 마지막 섹션·죽은 줄·명령·rc 를 찍고 반드시 비영 종료한다. `set -E` 를 켜서 함수 안 실패도 죽은 지점을 남긴다(bash 3.2 의 서브셸은 한계). 중단 8형태 전부 배너가 뜨고, 중단 출력에 `PASS=`/`FAIL=` 확장값이 새지 않는다.
- **`grep -q` 파이프 단언을 전부 걷었다(26곳).** `grep -q` 는 첫 일치에서 파이프를 닫고 좌변이 SIGPIPE(141)를 맞는데, `pipefail` 이 그걸 올려 내용과 무관하게 판정이 뒤집힌다. 긍정 극성에서는 거짓 실패고 **부정 극성에서는 조용한 거짓 통과**다(회귀를 심어도 100/100 "ok"). 임계값으로 안전을 논증하려 세 번 실패했다 — bash 내장 `echo` 는 여러 줄 문자열을 한 번의 write 로 내보내지 않아 166바이트가 65536 버퍼에서 45/20000 뒤집히고, 파이프 용량 자체도 상수가 아니다(할당된 파이프 버퍼가 ~16MiB 를 넘으면 새 파이프가 512바이트로 강등된다). 그래서 크기를 재는 대신 부류를 없앴다: 고정 문자열은 캡처 + `case`, 정규식은 herestring, 외부 명령은 rc 를 단언에 접어넣는 `assert_out` 헬퍼. 불변식 확인 명령을 파일에 박아뒀다.
- **이빨 없던 단언 하나.** `deadreapjob` 부정 극성 단언은 캡처에 `2>&1` 이 없는데 제품 메시지가 `>&2` 로 나가, 제품이 그 로그를 37개 job 에 걸쳐 39건 찍어도 초록이었다. 파이프와 무관한 선재 결함이다. 회귀를 심으면 정확히 그 단언만 빨개진다.
- **공유 폴링 예산.** 28개 섹션이 `20 × sleep 1` 을 공유해 부하 하 1/52 로 터졌다. `POLL_TRIES`(기본 40, `FREEZE_TEST_POLL_TRIES` 로 덮어쓰기) 로 뽑고, 타임아웃과 진짜 회귀의 FAIL 문구를 갈랐다 — 예산 확대가 감지력을 깎지 않는지 제품 변이 6종으로 확인했고 오분류 0건이다. 정상 경로 실행 시간은 변하지 않는다(기대 상태를 보는 즉시 break).
- 순서 불변식·ledger 게이트 분기에 결정적 게이트 3섹션을 추가했다. `FREEZE_NODE_BIN` 래퍼로 cancel/status 의 node 호출 순서를 직접 관측하므로 확률 게이트가 아니다 — 순서를 되돌린 변이를 무부하에서도 20/20 잡는다.

단언 124 → 150, 삭제·약화 0(기준선과 최종의 ok/FAIL/skip 151줄이 순서·문구까지 동일). 최종 스위트는 파이프 압력 조건을 포함해 100회 이상 전부 `PASS=150 FAIL=0 SKIP=1` rc=0 이고 `Broken pipe`·rc=141·ABORTED 각 0건이다. 수정 전 기준선은 21회 중 5회 비정상(중단 3 + FAIL=2 2회)이었다.

남긴 것: `&& ok || fail` 구문이 비주석 96곳에 남아 있다(stdout 닫힘·ENOSPC 에서 한 사이트가 단언 2개로 세어지지만 그 상황은 `set -e` 로 중단되므로 조용한 오집계는 아니다). `wfledger.sh` 의 `ledger_field()` 는 SIGPIPE 에 errexit 가 살아 있고 호출 지점 5곳 중 3곳이 맨 대입이지만 페이로드가 구조적으로 1~2줄이라 잠재적이다 — 가드 주석만 남겼다. `thaw.sh` 의 늦은 기상 체인 끊김(`NEXT_AT` 이 실제 기상 시각이 아니라 예약 시각 기준)과 ledger 완료 게이트의 SKILL.md 미문서화는 이번 회차 범위 밖이다.

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
