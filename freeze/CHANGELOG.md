# CHANGELOG

## 1.2.0 — 2026-08-31

즉발 예약(`snap`), workflow-arm 훅의 규모 게이트, codex waker 를 들이고 맥에서 남아 있던 하드코딩을 걷었다.

**즉발 — `freeze.sh snap`.** 얼음의 병목은 handoff 였다. 한도 95~99% 에서 부르면 LLM 이 handoff 를 쓰다 중간에 끊기고, 그러면 예약 자체가 통째로 날아간다. 이제 handoff 를 스크립트가 만든다 — 최신 transcript 뒤쪽 2MB 에서 사람이 친 사용자 메시지 다섯 개와 마지막 TodoWrite 상태, 직전 어시스턴트 발언을 뽑고 거기에 브랜치·최근 커밋·`git status --porcelain`·diffstat 을 붙여 SKILL.md 가 정하는 네 섹션 골격에 채운 뒤 곧바로 reserve 또는 arm 까지 간다. LLM 이 하는 일은 Bash 한 줄이고, 토큰이 남았을 때만 `## 다음 단계` 를 손보면 된다. transcript 를 못 읽든 cwd 가 git 워크트리가 아니든 그 자리엔 안내 문구가 들어가고 예약은 그대로 걸린다 — handoff 품질보다 예약이 걸리는 쪽이 언제나 우선이다.

**workflow-arm 훅이 작은 워크플로우를 놔준다.** 지금까지는 `script`·`scriptPath`·`name` 중 하나라도 있으면 규모를 가리지 않고 한 번 막았다. 이제 서브에이전트 수를 먼저 추정해 열 개 이하면 예약 여부를 볼 것도 없이 통과시키고 세션 마커도 남기지 않는다 — 작은 워크플로우 한 번이 그 세션의 "한 번만 막기" 기회를 태워버리면 안 되기 때문이다. 추정은 `agent(` 호출 수에 팬아웃 대상의 크기를 곱한다. `parallel`·`pipeline`·`map` 계열은 Workflow 툴의 표준 API 라 그 존재만으로 막으면 게이트가 예전과 똑같아지므로, 대상이 인라인 배열 리터럴이거나 `const` 로 선언된 배열이면 깊이 인식 스캐너로 원소를 세어 계산에 넣는다(문자열 안 콤마와 중첩 구조를 구분한다). 팬아웃이 중첩되면 곱해서 누적한다 — 열 개 위에 열 개면 백이다. `review.findings.map(...)` 처럼 모델 산출물 위로 도는 팬아웃, `[...items]` 같은 spread 가 섞인 배열, `for`·`while` 루프는 상한이 없으니 그때만 막는다. 패턴 매칭은 주석과 문자열 리터럴을 지운 텍스트 위에서만 돈다 — 주석에 적힌 `for (` 하나로 소형 워크플로우가 막히던 오탐을 없앴다. 임계값은 `FREEZE_HOOK_AGENT_THRESHOLD` 로 바꿀 수 있다.

**codex waker — `--waker codex`.** 땡의 재개 경로에서 Anthropic 을 건드리는 지점을 실제 재개 호출 하나로 줄인다. haiku 프로브를 건너뛰고 codex 가 재개를 주도한다. 다만 codex 에게 셸 명령을 조립시키지는 않는다 — `do-resume.sh` 가 재개 실행을 통째로 소유하고, codex 는 그것을 언제 몇 번 부를지만 판단한다. codex 가 다루는 텍스트에는 claude 경로도 세션 UUID 도 프롬프트도 나타나지 않아 따옴표나 개행이 섞인 job 이름·경로로 인자 경계가 깨질 여지가 없다. `do-resume.sh` 는 claude 를 부르기 전에 nonce 를 `resume-attempt.json` 에 남기고 부른 직후 같은 nonce 로 판정을 원자적으로 쓴다. 그래서 재개가 성공한 뒤 codex 가 죽어도 thaw 가 그 흔적을 보고 같은 세션을 두 번 열지 않는다 — 결과가 불명확하면 폴백 대신 `ambiguous` 로 멈춘다. 재개 시도 흔적 자체가 없을 때만 기존 bash 경로(프로브 → 재개)로 떨어진다.

대기 자체는 어느 쪽을 골라도 그대로 detached bash 슬리퍼가 맡는다. 몇 시간을 기다리는 데는 모델이 필요 없고, 슬리퍼는 이미 Claude 세션과 무관하게 독립 프로세스로 살기 때문이다. `waker` 필드가 없는 구버전 reservation 은 bash 로 돈다.

체인 쪽도 같이 손봤다. 선무장에 성공하면 부모 reservation 에 `next_job` 을 남기고, `cancel` 이 그 사슬을 따라 체인 전체로 전파한다. 예전엔 폴백 도중 취소하면 미리 걸어둔 다음 창이 고아로 남아 이미 끝난 작업을 다시 열 수 있었다.

**맥에서 남아 있던 하드코딩.** 1.1.1~1.1.2 가 GNU 전제와 node 탐색을 걷었는데 claude 실행 파일 자체는 `$HOME/.local/bin/claude` 로 굳어 있었다. 맥은 homebrew·npm 전역·`~/.claude/local` 어디에나 claude 를 두고 비대화형 ssh 의 PATH 는 `/usr/bin:/bin:/usr/sbin:/sbin` 뿐이라 못 찾는다. `_claude.sh` 의 `resolve_claude_bin` 이 `_node.sh` 와 같은 사다리로 찾고, `cmd_reserve` 가 예약을 만들기 전에 미리 검증한다 — 예전엔 땡이 되어서야 실패를 알았다(`FREEZE_SKIP_CLAUDE_CHECK=1` 로 우회). `--at auto` 추정이 실패할 때도 HUD 캐시 상태와 최근 transcript 개수를 stderr 에 찍어, 맥처럼 HUD 가 없는 환경에서 왜 실패했는지 보이게 했다.

리눅스 PASS=267 FAIL=0 SKIP=0, 훅 57 passed.

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
