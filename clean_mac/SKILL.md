---
name: clean_mac
version: "1.0.0"
description: "맥 로컬 디스크를 정리해 여유공간을 확보한다. Go·pnpm·npm·pip·Homebrew 캐시, 앱 캐시(Google·opencode), /private/tmp 의 오래된 빌드 산출물, Docker 이미지·빌드 캐시를 지우고, 승인받으면 다른 Claude 세션의 스크래치패드와 방치된 프로젝트의 node_modules 까지 지운다. 호출하면 미리보기에서 멈추지 않고 실제 정리까지 한다 — dry-run 표를 보여주고 범위를 한 번 물은 뒤 승인된 모듈만 실행한다. 삭제는 rm -rfx 라 되돌릴 수 없어서, 회귀 시험에서 확인된 위험을 근거로 모듈을 기본 세트와 개별 확인 세트로 나눴다. 트리거 — \"디스크 정리\", \"용량 확보\", \"로컬 스토리지 정리\", \"local storage 정리\", \"디스크 비워줘\", \"저장공간 부족\", \"맥 정리\", \"캐시 정리\", \"npm 캐시\", \"docker 정리\", \"clean_mac\". 앱 삭제, 사진·다운로드 같은 사용자 파일 정리, 원격 서버·쿠버네티스 노드의 디스크, Linux 는 이 스킬이 아니다."
argument-hint: "[바로 | 미리보기 | 모듈 이름들(예: docker,npm)]"
---

# /clean_mac — 로컬 디스크 정리

`/clean_mac` 을 불렀거나 디스크 정리를 직접 요청받았으면 **정리를 수행한다.** 미리보기만 하고 끝내지 않는다.

```
여유공간 ─▶ dry-run 전체 미리보기 ─▶ 표 제시 ─▶ 질문 1회 ─▶ -y --only <승인 모듈> ─▶ 결과 보고
              삭제 없음                                        복구 불가(rm -rfx)
```

스크립트는 `~/.claude/skills/clean_mac/scripts/clean.sh` 다. 명령마다 이 경로를 그대로 적는다. Bash 도구는 호출 사이에 셸 변수를 유지하지 않으므로 `DC=...` 같은 변수에 담아 다음 호출에서 쓰지 않는다(빈 값이 돼 `bash /clean.sh` 로 실패한다). 경로가 없다고 나오면 다른 경로를 추측해 돌리지 말고 설치 여부(§주의)를 확인한다.

Claude Code 의 Bash 도구에는 TTY 가 없다. `clean.sh` 를 옵션 없이 부르면 y/N 입력을 못 받아 `취소했습니다.` 로 끝난다(종료코드 0 — 성공이 아니다). 그래서 실행은 항상 `--dry-run` 아니면 `-y --only <모듈 목록>` 둘 중 하나다.

## 1. 모듈을 두 세트로 나눈다

**기본 세트** — 캐시와 재생성 가능한 산출물. 범위 승인 한 번으로 같이 돈다.

```bash
bash ~/.claude/skills/clean_mac/scripts/clean.sh -y --only go,pnpm,npm,pip,brew,app-caches,tmp-builds,docker
```

`--skip` 으로 뒤집어 쓰지 않는다. 모듈이 늘면 새 모듈이 자동으로 딸려 들어간다.

**개별 확인 세트** — `claude-tmp`, `node-modules`. 사람의 작업물에 가까운 것을 mtime 으로 추정해 지운다. dry-run 이 뽑은 후보 목록(`[dry-run] rm -rfx <경로>` 줄)을 보여주고 **모듈마다 따로** 승인받았을 때만 돌린다. 기본 세트에 딸려 들어가지 않는다.

`report` 는 삭제가 없다. 미리보기와 결과 보고에 자유롭게 쓴다.

### `claude-tmp` 는 활동 중인 세션을 스스로 뺀다

스크립트가 세션마다 다음을 본다. 하나라도 걸리면 후보에서 빼고 이유를 `[skip]` 줄에 찍는다.

- 현재 세션(`CLAUDE_CODE_SESSION_ID`)
- 그 디렉터리를 cwd 로 쓰거나 그 안의 파일을 열어 둔 프로세스
- 최근 24시간 안에 수정된 대화 기록. `~/.claude/projects/*/<세션 UUID>.jsonl` 과, 서브에이전트·워크플로·도구 결과가 쌓이는 `~/.claude/projects/*/<세션 UUID>/` 아래를 같이 본다. `CLAUDE_CONFIG_DIR` 이 설정돼 있으면 `$CLAUDE_CONFIG_DIR/projects` 도 같이 본다
- 최근 24시간 안에 바뀐 스크래치패드의 파일이나 디렉터리(세션 디렉터리 자신 포함). 방금 만들어져 빈 디렉터리만 있는 세션도 여기서 걸린다

판정을 못 하면 지우지 않는다.

- 대화 기록 조회나 스크래치패드 스캔이 오류로 끝난 세션(읽을 수 없는 하위 디렉터리 등)은 `판정 불가` 로 건너뛴다.
- 프로젝트 디렉터리(`~/.claude/projects/<프로젝트>`) 하나를 볼 수 없으면 그 실행의 **모든 세션**이 `판정 불가` 로 남는다. 읽기 권한이 없는 디렉터리, 끊어진 심볼릭 링크가 해당한다. 어느 항목인지는 `[경고] … 대화 기록을 볼 수 없는 항목(…): <경로>` 줄에 찍힌다. 그 줄을 그대로 전한다. 권한이나 링크를 대신 고치지 않는다.
- `~/.claude/projects` 가 없거나, `CLAUDE_CONFIG_DIR` 이 설정됐는데 그 아래 `projects` 가 없으면 모듈이 `skip` 으로 끝난다.

후보 줄에는 대화 기록의 마지막 수정 시각이 같이 찍힌다.

```
50-claude-tmp: [dry-run] rm -rfx <경로> (<크기>, 대화 기록 마지막 수정 YYYY-MM-DD HH:MM)
50-claude-tmp: [dry-run] rm -rfx <경로> (<크기>, 대화 기록 없음)
```

- 후보를 보일 때 경로·크기·이 시각을 그대로 옮긴다. 대화 기록을 따로 조회하지 않는다.
- 스크립트가 가리지 못하는 경우가 둘 남는다. 후보를 보일 때 한 줄로 알린다.
  - 실행 중이지만 대화 기록과 스크래치패드가 모두 24시간 넘게 조용한 세션
  - 대화 기록이 없는 세션(`대화 기록 없음`). 스크래치패드가 24시간 넘게 조용하면 후보다. 다른 `CLAUDE_CONFIG_DIR` 로 띄운 세션도 여기에 든다. 스크립트는 자기 환경의 `CLAUDE_CONFIG_DIR` 하나만 본다
- 그래서 `claude-tmp` 는 계속 개별 확인 세트다. 후보를 보이고 따로 승인받는다. `바로` 경로로는 돌리지 않는다.
- 이 모듈은 세션을 골라 지우지 못한다. 승인하면 후보 전부가 지워진다는 점을 질문에 적는다.

## 2. 단계

### 인자 없음 — `/clean_mac`

0. 현재 여유공간을 본다. `df -h /System/Volumes/Data`
1. 전체 미리보기. `lsof`·`du`가 느리면 몇 분 걸릴 수 있으므로 Bash timeout 을 300000 으로 준다.
   ```bash
   bash ~/.claude/skills/clean_mac/scripts/clean.sh --dry-run
   ```
2. 출력 끝의 `모듈별 예상 확보량` 표를 옮겨, 모듈마다 예상 확보량·위험도·지운 뒤 비용을 표로 제시한다(§3 표 참고). `skip`·`FAIL` 은 사유와 함께 그대로 적는다. 개별 확인 세트는 후보 경로 목록을 따로 보인다. `claude-tmp` 후보는 후보 줄에 찍힌 대화 기록 마지막 수정 시각을 같이 적고, §1 의 남는 한계를 한 줄로 알린다.
3. AskUserQuestion **한 번**으로 범위를 받는다.
   - 질문 1(범위): `기본 세트 실행(권장)` / `직접 고르기` / `취소`. 설명에 **docker 는 사용 중이 아닌 이미지 전부와 빌드 캐시를 지운다**는 점을 적는다.
   - 질문 2·3(개별 확인): `claude-tmp` 와 `node-modules` 를 각각 `지운다` / `남긴다`로 묻는다. dry-run 후보가 없는 모듈은 묻지 않는다. `claude-tmp` 질문에는 승인하면 후보 전부가 지워진다는 점을 적는다.
   - `직접 고르기`면 모듈 이름을 받아 그 모듈만 대상으로 한다.
   - 질문 1 이 `취소`면 나머지 답과 무관하게 아무것도 돌리지 않는다.
4. 승인된 모듈만 실행한다. timeout 600000.
   ```bash
   bash ~/.claude/skills/clean_mac/scripts/clean.sh -y --only <승인된 모듈들>
   ```
   모듈별 타임아웃의 합(brew 300초, pnpm 180초, docker 120초×2 등)이 10분을 넘을 수 있다. 캐시가 크면 `run_in_background` 로 돌린다.
5. 결과를 보고한다. 이전/이후 여유공간, 모듈별 확보량, `skip`·`FAIL`·경고. 읽는 법은 §4.

### `바로` 또는 `-y` — `/clean_mac 바로`

사용자가 확인 생략을 명시한 것이다. 미리보기·질문 없이 **기본 세트만** 곧바로 실행하고 결과를 보고한다. 개별 확인 세트는 이 경로로 절대 돌리지 않는다.

이 경로는 **슬래시 명령의 인자가 정확히 `바로` 또는 `-y` 일 때만** 해당한다(모듈 이름이 같이 오는 `/clean_mac 바로 docker,npm` 포함). 자연어 문장 속의 "바로"·"지금"·"빨리"·"당장"은 확인 생략이 아니다. "디스크 좀 바로 정리해줘"는 인자 없는 호출로 보고 미리보기와 질문을 거친다.

### `미리보기` / `--dry-run` / `검사만`

1~2단계까지 하고 끝낸다. 아무것도 지우지 않는다.

### 모듈 이름 — `/clean_mac docker,npm`

그 모듈만 대상으로 위 흐름을 따른다. 개별 확인 세트가 섞여 있으면 그 모듈은 후보 목록을 보이고 따로 승인받는다(`claude-tmp` 는 §1 대로 대화 기록 시각을 같이 보인다). `바로` 와 같이 오면(`/clean_mac 바로 docker,npm`) 지정한 것 중 기본 세트에 속한 모듈만 곧바로 돌린다.

모듈 이름은 `--only` 토큰이다. 번호 붙은 이름(`10-go`), 짧은 이름(`go`), 부분문자열 순으로 매칭하고, 0개나 2개 이상에 걸리면 에러로 끝난다(`--only tmp` 는 `tmp-builds`·`claude-tmp` 둘에 걸린다). 목록은 `bash ~/.claude/skills/clean_mac/scripts/clean.sh --list`.

### `-y` 를 붙여도 되는 경우

둘뿐이다.

- (a) **이번 호출에서 방금 보여준 미리보기**에 대한 AskUserQuestion 답으로 승인된 모듈.
- (b) 사용자가 슬래시 명령에 `바로`/`-y` 인자를 직접 붙인 호출의 기본 세트.

승인은 그 호출 한 번에만 쓴다. 같은 대화에서 앞서 받은 승인도 다시 쓰지 않는다. 다시 부르면 미리보기부터 새로 하고 새로 묻는다(그 사이 후보가 달라진다). 예전 대화의 승인, 메모리, 다른 작업 도중의 자체 판단("디스크가 부족해 보이니 정리하자")으로도 실행하지 않는다. 사용자가 부르지 않았는데 스스로 이 스킬을 꺼냈다면 미리보기까지만 하고 묻는다.

`claude-tmp` 는 승인받았더라도 `CLAUDE_CODE_SESSION_ID` 가 비어 있으면 돌리지 않는다. 현재 세션 보호가 이 환경변수에 달려 있다(`echo "$CLAUDE_CODE_SESSION_ID"` 로 확인).

실행 시점에 후보를 다시 판정한다. 승인받은 목록과 실제 삭제 로그가 다르면 그 차이를 보고한다.

## 3. 모듈

| 모듈 | 지우는 것 | 건드리지 않는 것 | 위험도 | 지운 뒤 비용 |
|---|---|---|---|---|
| `go` | `go clean -cache`, `go clean -modcache` 실행. 대상은 `go env GOCACHE`·`GOMODCACHE` | 스크립트가 직접 지우는 경로는 없다 | 낮음 | 다음 빌드에서 모듈 재다운로드·전체 재컴파일 |
| `pnpm` | `pnpm store prune` 실행 + `~/Library/Caches/pnpm` 삭제 | store 디렉터리(`~/Library/pnpm`)를 직접 지우지는 않는다 | 낮음 | 다음 `pnpm install` 에서 재다운로드 |
| `npm` | `npm cache clean --force` 실행. 크기는 `~/.npm/_cacache` 만 잰다 | 스크립트가 직접 지우는 경로는 없다 | 낮음 | 다음 `npm install` 에서 재다운로드 |
| `pip` | `pip3 cache purge` 실행. 대상은 `pip3 cache dir` | 스크립트가 직접 지우는 경로는 없다 | 낮음 | 다음 설치에서 재다운로드·휠 재빌드 |
| `brew` | `brew cleanup -s` 실행. 무엇을 지울지는 Homebrew 가 정한다 | 스크립트가 직접 지우는 경로는 없다 | 중간 | Homebrew 가 지운 것은 다시 받아야 한다 |
| `app-caches` | `~/Library/Caches/Google`, `~/.cache/opencode` | Chrome 이 실행 중이면 Google 캐시는 건너뛴다(opencode 는 지운다) | 낮음 | 앱이 캐시를 다시 채운다 |
| `tmp-builds` | `/private/tmp` 최상위에서 내 소유이고 이름이 `*verify*` 또는 `_site*` 이며 3일 넘은 항목 | `claude-*`, 마운트가 낀 것, 프로세스가 쓰는 것, 최근 3일 안에 수정된 파일이 든 것, 그 판정을 못 한 것 | 중간 | 그 빌드 산출물은 다시 빌드 |
| `docker` | `docker builder prune -a -f`, `docker image prune -a -f` | 볼륨, 컨테이너. 데몬이 응답하지 않거나 원격 데몬이면 통째로 건너뛴다(자동 kill 없음) | 중간 | 이미지 재pull·재빌드. 레지스트리에 없는 로컬 이미지는 복구 불가 |
| `claude-tmp` | `/private/tmp/claude-<uid>/<프로젝트>/<세션 UUID>/` 중 조건을 다 통과한 세션 디렉터리. **실행 중이어도 대화 기록과 스크래치패드가 모두 24시간 넘게 조용한 세션, 대화 기록이 없는 세션은 보호되지 않는다**(§1) | 현재 세션(`CLAUDE_CODE_SESSION_ID`), 마운트가 낀 것, 어떤 프로세스가 그 안을 cwd 로 쓰거나 그 안의 파일을 열어 둔 것, 최근 24시간 안에 대화 기록이 수정된 것, 최근 24시간 안에 바뀐 파일·디렉터리가 든 것, 판정을 못 한 것, UUID 가 아닌 디렉터리 | **높음** | 그 세션의 스크래치패드는 복구 불가 |
| `node-modules` | `~/src` 아래 깊이 5 이내의 `node_modules` 중 방치 판정된 것 | 프로젝트 소스. 최근 30일 안에 수정된 파일이 있는 프로젝트, 프로세스가 쓰는 프로젝트, 마운트가 낀 것 | **높음** | 그 프로젝트에서 다시 설치(`pnpm install` 등) |
| `report` | 없음. 고정된 대형 경로의 크기만 보고 | 전부 | 없음 | 없음 |

`node-modules` 의 방치 판정은 다음과 같다.

- 프로젝트 디렉터리에서 `node_modules`·`.git`·`.next` 를 빼고, 최근 30일 안에 수정된 파일이 하나라도 있으면 남긴다.
- 위로 올라가며 `pnpm-workspace.yaml` 이나 `package.json` 의 `"workspaces"` 를 찾으면 그 워크스페이스 루트를 기준으로 본다. 패키지 하나만 최근이어도 워크스페이스 전체의 `node_modules` 가 남는다.
- `.next` 아래의 `node_modules`(예: `.next/standalone/node_modules`)는 바로 위 디렉터리만 본다. 프로젝트가 활동 중이어도 지워질 수 있다.

lsof 가 실패하거나 타임아웃하면 `tmp-builds`·`claude-tmp`·`node-modules` 는 전부 "사용 중"으로 보고 아무것도 지우지 않는다.

`tmp-builds`·`claude-tmp` 는 최근 수정을 찾는 `find` 가 오류로 끝난 대상도 남긴다(`[skip] … 판정할 수 없어`). 읽을 수 없는 하위 디렉터리가 있는 대상은 권한을 고치기 전까지 계속 남는다. `claude-tmp` 의 대화 기록 쪽은 범위가 다르다. 프로젝트 디렉터리 하나를 볼 수 없으면 대상 하나가 아니라 모든 세션이 남는다(§1).

## 4. 숫자 읽는 법

- **dry-run 예상치는 상한이다.** `pnpm` 은 store 전체 크기를 잰다(실제로는 참조 없는 패키지만 지운다). `brew` 는 캐시 디렉터리 전체 크기다. `go`·`npm`·`pip` 도 캐시 디렉터리 크기다. `docker` 는 `docker system df` 의 Images·Build Cache 회수 가능량 합이고, 그 출력을 못 얻으면 0 이다.
- **표의 확보량은 모듈이 잰 값이다.** 도구 캐시 모듈(`go`·`pnpm`·`npm`·`pip`·`brew`)은 대상 디렉터리의 전후 `du` 차이, 경로를 직접 지우는 모듈은 지우기 전에 잰 크기, `docker` 는 prune 이 보고한 회수량이다. `brew` 는 캐시 디렉터리만 재므로 그 밖에서 지워진 것은 안 잡힌다.
- **`skip` 은 실패가 아니다.** 도구가 없거나, 대상이 없거나, docker 데몬이 응답하지 않거나, `claude-tmp` 가 대화 기록 디렉터리를 찾지 못한 경우 등이다. 사유는 로그의 `[skip]` 줄에 있다. Chrome 이 실행 중이라 Google 캐시를 건너뛴 경우는 `skip` 이 아니라 `0KB` 로 찍힌다.
- **`FAIL` 은 모듈이 RESULT 줄을 못 남긴 것이다.** 환경변수 값이 잘못됐거나 모듈이 죽었다. 숨기지 않고 로그와 함께 그대로 보고한다.
- **확보량이 찍혔다고 정리 명령이 성공한 것은 아니다.** 정리 명령의 종료코드는 결과에 반영되지 않는다. `npm` 이 실패해도 표에는 `0KB` 로 찍힌다. 그래서 보고의 근거는 스크립트가 찍는 `전체 여유공간` 의 이전/이후 값과 로그의 `[경고]`·에러 줄이다.

## 5. dry-run 이 실제로 하는 일

삭제는 없다. 아래는 실제로 실행된다.

- `go env`, `pip3 cache dir`, `brew --cache`, **`brew cleanup -ns`**
- `lsof -b -w -Fn` 전체 덤프(`tmp-builds`·`claude-tmp`·`node-modules` 가 각각 두 번, 한 번에 60초 한도)
- `docker info`, `docker context inspect`, `docker system df`
- `pgrep`, 그리고 대상 경로의 `find`·`du`·`stat` 순회
- `claude-tmp` 는 `~/.claude/projects` 를 세션마다 깊이 2까지 훑고, 찾은 대화 기록을 `stat` 한다(읽기만 한다). `CLAUDE_CONFIG_DIR` 이 설정돼 있으면 `$CLAUDE_CONFIG_DIR/projects` 도 같이 훑는다

"아무 일도 일어나지 않는다"고 안내하지 않는다. 옵션 없이 부른 기본 모드도 같은 dry-run 을 먼저 돌린다.

## 6. 막혔을 때

권한 분류기가 real 실행을 막으면 다른 방법으로 우회하지 않는다. 사용자가 직접 돌릴 명령을 안내한다.

```
! bash ~/.claude/skills/clean_mac/scripts/clean.sh -y --only <승인된 모듈들>
```

docker 데몬이 응답하지 않으면(Docker Desktop 이 꺼져 있을 때도 같다) 모듈이 상태를 찍고 건너뛴다. 그 안내를 그대로 전한다. 대신 kill 하거나 Docker 를 띄우지 않는다.

## 7. 금지

- 스크립트 밖의 임의 `rm` 으로 정리 범위를 넓히지 않는다. 추가 후보는 `report` 결과를 근거로 **제안만** 한다.
- `sudo` 를 쓰지 않는다.
- 스크립트를 고치거나 시험하는 중에는 실제 머신에서 real 모드를 돌리지 않는다. 허용되는 것은 `--list`, `-h`, `--dry-run` 뿐이다. 모듈 파일을 직접 `bash` 로 부를 때도 같다. 시험은 하네스로 한다.
  ```bash
  bash ~/.claude/skills/clean_mac/tests/test_clean_mac.sh
  ```

## 8. 조정값

| 환경변수 | 기본값 | 의미 |
|---|---|---|
| `TMP_BUILDS_MIN_AGE_D` | `3` | `tmp-builds` 의 나이 임계값(일). 최상위 mtime 과 내부 파일 보호 창에 같이 쓰인다. `0`~`36500` 의 10진 정수 |
| `CLAUDE_TMP_MIN_AGE_H` | `24` | `claude-tmp` 의 보호 창(시간). 대화 기록과 스크래치패드에 같이 쓰인다. `0`~`876000` 의 10진 정수 |
| `NODE_MODULES_MIN_AGE_D` | `30` | `node-modules` 의 방치 임계값(일) |
| `NODE_MODULES_ROOTS` | `$HOME/src` | `node-modules` 스캔 루트. `:` 로 여러 개. `/`·`$HOME` 은 거부 |
| `DOCKER_HOST` | (미설정) | 설정돼 있고 `unix://` 가 아니면 `docker` 모듈을 건너뛴다 |
| `CLAUDE_CODE_SESSION_ID` | (Claude Code 가 설정) | `claude-tmp` 가 현재 세션을 알아보는 값. 없으면 `CLAUDE_SESSION_ID` 를 본다 |
| `DRY_RUN` | `0` | `1` 이면 모듈과 `safe_rm` 이 지우지 않는다. `clean.sh --dry-run` 이 모듈에 넘기는 값 |
| `TMPDIR` | `/tmp` | `clean.sh` 가 결과 임시 파일을 두는 곳 |
| `TMP_BUILDS_ROOT` | `/private/tmp` | `tmp-builds` 스캔·삭제 루트. **테스트용** |
| `CLAUDE_TMP_ROOT` | `/private/tmp/claude-<uid>` | `claude-tmp` 스캔·삭제 루트(`report` 도 따른다). **테스트용** |
| `CLAUDE_CONFIG_DIR` | (미설정) | Claude Code 의 설정 디렉터리. 설정돼 있으면 `claude-tmp` 가 `$CLAUDE_CONFIG_DIR/projects` 도 대화 기록 디렉터리로 같이 본다. 기본 경로를 대신하지 않고 더한다. 절대경로가 아니면 `FAIL`, 그 아래 `projects` 가 없으면 `skip` 으로 끝나고 아무것도 지우지 않는다. `CLAUDE_TMP_PROJECTS_DIR` 를 주면 보지 않는다 |
| `CLAUDE_TMP_PROJECTS_DIR` | `$HOME/.claude/projects` | `claude-tmp` 가 대화 기록을 찾는 디렉터리. 읽기만 한다. 절대경로가 아니면 `FAIL`, 디렉터리가 없으면 `skip` 으로 끝나고 아무것도 지우지 않는다. `~/.claude/projects` 가 없는 환경(설정 디렉터리를 통째로 옮긴 경우)과 테스트에서만 바꾼다 |
| `CLEAN_SANDBOX_ROOT` | (미설정) | 설정하면 그 디렉터리 밖의 삭제를 `safe_rm` 이 전부 거부한다. 빈 값·상대경로·없는 디렉터리로 설정하면 삭제를 전부 거부한다. **테스트용** |

`TMP_BUILDS_MIN_AGE_D`·`CLAUDE_TMP_MIN_AGE_H` 는 앞자리 0 이 붙은 값(`08`, `010`)이나 범위를 넘는 값이면 모듈이 `FAIL` 로 끝난다. 보호 창이 꺼진 채 도는 일을 막으려는 것이다. `NODE_MODULES_MIN_AGE_D` 는 정수인지만 본다.

테스트용 세 값은 평소 실행에 쓰지 않는다. 루트 오버라이드(`TMP_BUILDS_ROOT`, `CLAUDE_TMP_ROOT`)는 절대경로여야 하고, `.`·`..` 성분이나 연속 슬래시(`//`)가 있으면 거부된다. `/`·`$HOME`·`$HOME/src`·`/Users`·`/Users/<사용자>` 는 글자가 같을 때뿐 아니라 같은 디렉터리를 가리킬 때도(대소문자만 다른 표기, `/System/Volumes/Data/...` 경유, 심링크) 거부된다. 거부되면 모듈이 `FAIL` 로 끝난다. 이 목록의 **하위** 디렉터리(예: `$HOME/Documents`)까지 막지는 않는다. `NODE_MODULES_ROOTS` 는 이 검사를 거치지 않고 `/`·`$HOME` 을 글자로만 비교한다. `CLAUDE_TMP_PROJECTS_DIR`·`CLAUDE_CONFIG_DIR` 는 삭제 루트가 아니라 이 검사를 거치지 않는다. 절대경로인지만 본다.

## 9. 모듈을 더할 때

1. `scripts/clean.d/NN-이름.sh` 를 쓴다. `lib.sh` 를 source 하고, `parse_dry_run_arg "$@"` 를 부르고, 삭제는 `safe_rm <대상> <허용 접두>` 로만 하고, 마지막에 `emit_result <모듈> <KB> <ok|dry|skip>` 을 정확히 한 번 낸다.
2. `scripts/clean.sh` 의 **두 곳**에 등록한다 — `MODULE_FILES` 와 `module_desc`.
3. 스캔·삭제 루트는 env 로 덮어쓸 수 있게 하고 `tests/test_clean_mac.sh` 에 샌드박스 테스트를 더한다.
4. 이 문서 §1 의 어느 세트에 넣을지 정한다. 기본 세트 명령은 모듈을 나열하므로 적지 않으면 돌지 않는다.

## 왜 이렇게 나눴나

삭제가 `rm -rfx` 라 휴지통이 없다. 회귀 시험에서 루트가 하드코딩돼 있으면 가짜 트리 대신 실제 루트를 건드릴 수 있음을 확인했다. 그래서 세 가지 안전장치를 넣었다.

- 루트를 env 로 덮어쓸 수 있게 하고(`TMP_BUILDS_ROOT`, `CLAUDE_TMP_ROOT`), `safe_rm` 에 샌드박스 가드(`CLEAN_SANDBOX_ROOT`)를 뒀다. 테스트 하네스는 조건이 하나라도 어긋나면 아무것도 실행하지 않고 멈춘다.
- 사람의 작업물에 가까운 두 모듈(`claude-tmp`, `node-modules`)을 기본 세트에서 뺐다. mtime 은 "방치됐다"의 대용일 뿐이다. `claude-tmp` 는 최근 대화한 세션도 후보가 될 수 있어 대화 기록과 디렉터리 변경까지 보게 했다. 그래도 추정인 것은 같아서 개별 확인 세트에 그대로 둔다.
- 승인 없이는 `-y` 를 붙이지 않는다는 규칙을 문서에 못 박았다.

`safe_rm` 의 나머지 검사(절대경로, `.`/`..` 거부, 위험 경로 목록, 허용 접두, 심링크는 링크만, 마운트 포인트 거부)와 `--only` 의 엄격한 매칭도 같은 식으로 생겼다. 재현된 사고(마운트 포인트를 시작점으로 한 삭제, 너무 넓은 허용 접두, 모호한 `--only` 토큰이 전체 선택으로 바뀐 것, cwd 파일명이 끼어든 글롭)는 `lib.sh`·`clean.sh` 주석에 적혀 있다.

`tmp-builds` 의 "최근 3일 보호"는 원본에서 단위 혼동(시간 값을 `find -mmin` 에 전달) 때문에 72분 보호였다. 이관하면서 고쳤고 회귀 테스트가 있다.

`tmp-builds`·`claude-tmp` 의 "최근 수정" 판정은 `find` 출력이 비었는지만 봤다. `find` 가 오류로 끝나도 출력이 비어서 후보가 됐다. 종료 상태를 보게 고쳤고 회귀 테스트가 있다.

판정 루프 둘(대화 기록, 마운트 포인트)은 목록을 here-document 로 읽었다. bash 3.2 는 here-document 를 임시 파일에 쓴다. 그 쓰기가 실패하면 루프가 한 번도 돌지 않고 "활동 없음"·"마운트 없음"으로 넘어갔다. 디스크가 꽉 찬 상태가 바로 이 스킬을 부르는 상황이다. here-document 를 없앴고 회귀 테스트가 있다.

`claude-tmp` 의 대화 기록 조회는 "못 봤다"를 "없다"로 읽는 길이 둘 더 있었다. 끊어진 심볼릭 링크인 프로젝트 디렉터리는 `find` 가 오류 없이 지나갔고, `CLAUDE_CONFIG_DIR` 로 옮긴 설정 디렉터리는 찾아보지도 않았다. 앞의 것은 모든 세션을 판정 불가로 남기고, 뒤의 것은 그 아래 `projects` 를 같이 보게 고쳤다.

## 주의

- `install.sh` 로 `~/.claude/skills/clean_mac` 심링크를 건 뒤에 쓴다. 이 문서의 경로는 전부 그 심링크를 거친다. 심링크가 없으면 명령이 `No such file` 로 끝난다.
- macOS 전용이다. `df /System/Volumes/Data`, `stat -f`, `rm -x`, `du -skx` 에 기대고, 타임아웃은 `perl` 로 구현했다. bash 3.2 에서 돈다.
- 나이 임계값(3일·24시간·30일)과 docker 정책은 스크립트를 처음 쓸 때 정한 기본값이다. 바꿀 때는 사용자에게 확인한다.
