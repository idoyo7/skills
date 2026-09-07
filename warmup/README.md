# Claude/Codex session warmup

Claude Code와 Codex의 5시간 사용 구간을 평일 08:00, 13:01, 18:02에 맞추는 운영체제 예약 작업이다. Claude 스킬이나 Codex 스킬이 아니며, 저장소 루트의 `install.sh`도 이 디렉토리를 설치하지 않는다.

## 무엇을 하는가

각 시각에 별개의 최소 요청을 보낸다.

| 서비스 | 비대화형 호출 | 상태를 저장하지 않는 옵션 |
|---|---|---|
| Claude Code | `claude -p` | `--no-session-persistence`, `--safe-mode` |
| Codex | `codex exec` | `--ephemeral`, `--ignore-user-config`, 읽기 전용 sandbox |

두 서비스의 한도와 5시간 구간은 서로 독립적이다. 이 도구는 서버의 리셋 시각을 강제로 변경하지 않는다. 예약 시각에 이전 구간이 끝난 상태에서 요청이 성공하면 그 요청을 새 구간의 기준점으로 삼는 방식이다. 그 전에 사용자가 요청을 보내거나 기존 한도가 아직 살아 있으면 시작점은 기대한 시각과 달라질 수 있다.

Claude 쪽은 기존 운용 기록에서 이 방식이 동작하는 것을 확인했다. OpenAI 공식 문서는 Codex 사용량을 5시간 단위로 안내하지만 첫 요청이 리셋 기준점을 정한다는 세부 규칙까지 보장하지는 않는다. Codex는 설치 뒤 usage 화면의 다음 리셋 시각을 며칠 확인해 실제 계정에도 같은 방식이 적용되는지 검증해야 한다.

기본 일정은 다음과 같다.

| 요청 시각 | 의도한 구간 |
|---|---|
| 08:00 | 08:00–13:00 |
| 13:01 | 13:01–18:01 |
| 18:02 | 18:02–23:02 |

## 설치

먼저 두 CLI를 평소 계정으로 로그인해 둔다.

```bash
claude --version
codex --version
codex login status
```

그다음 이 디렉토리의 설치기를 실행한다.

```bash
cd ~/src/skills/warmup
bash scripts/install.sh
```

설치기는 OS를 자동 판별한다.

- macOS: 사용자 LaunchAgent 3개(Claude, Codex, 공통 keep-awake)
- Ubuntu/Linux: systemd 사용자 service/timer 각 2개
- 공통 실행기: `~/.local/bin/ai-session-warmup.sh`
- 로그: `~/.local/log/ai-session-warmup-{claude,codex}.log`

설치 직후 실제 요청을 보내 확인하려면 다음을 실행한다. 두 서비스의 사용량을 조금 소비한다.

```bash
bash scripts/install.sh --run
tail -n 5 ~/.local/log/ai-session-warmup-claude.log
tail -n 5 ~/.local/log/ai-session-warmup-codex.log
```

등록 상태만 확인하는 명령은 실제 요청을 보내지 않는다.

```bash
bash scripts/install.sh --status
```

## macOS

`launchd`는 로그인한 사용자의 로컬 시간으로 평일 일정을 실행한다. 각 요청 2분 전에는 `caffeinate -i -t 420`을 실행해 이미 깨어 있는 Mac이 곧바로 idle sleep에 빠지는 것을 막는다.

`caffeinate`는 이미 잠든 Mac을 깨우지 못한다. 오전 자동 기상이 필요하면 별도로 다음 일정을 설정한다.

```bash
sudo pmset repeat wakeorpoweron MTWRF 07:57:00
pmset -g sched
```

`pmset repeat`는 같은 이벤트 유형에 반복 일정 하나만 지원하므로 이 예시는 오전 기상만 잡는다. 오후에도 Mac이 잠들 수 있다면 일회성 전원 일정 관리가 따로 필요하다. 노트북은 덮개와 전원 상태 등 하드웨어 조건에 따라 예약 기상이 제한될 수 있다.

## Ubuntu/Linux

systemd timer는 `Persistent=true`라서 전원이 꺼졌거나 suspend 상태여서 놓친 실행을 다음 기동 시 한 번 보충한다. 정확한 예약 시각에 suspend를 깨우지는 않는다.

systemd 가 없거나 `systemctl --user` 가 안 뜨는 호스트(코드서버 pod 등)에서는 설치기가 타이머 대신 사용자 권한 cron 인 [supercronic](https://github.com/aptible/supercronic)(v0.2.49, sha1 검증 후 `~/.local/bin` 에 설치)을 쓴다. crontab 은 `~/.config/ai-session-warmup/crontab` 에 쓰고, `~/.workspace-init.sh` 에 `start` 블록을 넣어 pod 가 재시작될 때마다 다시 띄운다 — 바이너리·crontab·훅이 모두 홈(PVC)에 있어 이미지가 초기화돼도 살아남는다. 기동 시점에 최근 60분(`WARMUP_CATCHUP_MIN`) 안에 놓친 슬롯이 있으면 한 번 보충한다. `WARMUP_PROVIDERS="claude"` 처럼 주면 한쪽만 건다.

pod 기동 훅 환경엔 `TZ` 도 nvm 도 없다(컨테이너는 UTC). 그래서 crontab 머리에 `CRON_TZ`/`TZ`(`WARMUP_TZ` → 설치 셸의 `TZ` → Asia/Seoul)와 node 경로가 들어간 `PATH` 를 써 두고, supercronic 자체도 같은 TZ 아래 띄운다. 이게 없으면 시각표가 9시간 어긋나고 codex(`#!/usr/bin/env node`)는 `node` 를 못 찾는다.

```bash
~/.local/bin/ai-session-warmup-cron.sh status
~/.local/bin/ai-session-warmup-cron.sh restart          # crontab 을 고친 뒤
tail -n 5 ~/.local/log/ai-session-warmup-cron.log
```

서버에서 로그아웃한 뒤에도 사용자 타이머가 돌아야 한다면 한 번 설정한다.

```bash
sudo loginctl enable-linger "$USER"
```

이 명령은 사용자 서비스 실행 정책을 바꾸므로 로그아웃 상태 실행이 필요한 장비에서만 사용한다.

상태와 로그는 다음처럼 확인한다.

```bash
systemctl --user list-timers 'ai-session-warmup-*.timer'
journalctl --user -u ai-session-warmup-claude.service -n 30
journalctl --user -u ai-session-warmup-codex.service -n 30
```

## Kubernetes 워크스페이스 pod

코드서버처럼 pod 로 뜬 리눅스 환경은 cron 을 apt 로 깔아도 pod 가 재시작되면 이미지 상태로 돌아가 사라진다. 대신 같은 PVC(홈)를 마운트하는 CronJob 을 클러스터에 걸면 pod 재시작과 무관하게 돈다. pod 안에서 kubectl 이 CronJob 을 만들 권한이 있을 때 쓴다.

```bash
cd ~/src/skills/warmup
WARMUP_PROVIDERS=claude bash scripts/install-k8s.sh          # 현재 pod 에서 image·PVC·namespace 를 읽어 apply
bash scripts/install-k8s.sh --status
bash scripts/install-k8s.sh --run                              # 지금 Job 하나 띄워 확인 (사용량을 조금 쓴다)
bash scripts/install-k8s.sh --render                           # apply 없이 manifest 만 본다
bash scripts/install-k8s.sh --uninstall
```

- provider × 시각마다 CronJob 하나(`ai-session-warmup-claude-0800` 식), `timeZone` 은 `WARMUP_TZ`(기본 `TZ` → `/etc/timezone` → Asia/Seoul).
- Job pod 는 워크스페이스 pod 와 같은 노드에 붙는다(podAffinity). RWO PVC 를 나눠 쓰기 위해서라, 워크스페이스 pod 가 내려가 있으면 그 시각의 Job 은 뜨지 않는다.
- istio 사이드카 주입은 끈다(`sidecar.istio.io/inject: "false"`). 안 끄면 Job 이 끝나지 않는다.
- 실행기·로그는 PVC 의 `~/.local/bin`, `~/.local/log` 를 그대로 쓴다. Job 로그는 `kubectl logs job/<이름>` 으로도 본다.
- 이미지 태그는 설치 시점의 워크스페이스 이미지로 고정된다. 워크스페이스 이미지를 올렸으면 다시 설치한다.

## 모델과 시간 변경

Claude는 기본 `haiku`, Codex는 기본 `gpt-5.6-luna`를 사용한다. 실행 환경에서 `CLAUDE_WARMUP_MODEL`이나 `CODEX_WARMUP_MODEL`을 지정하면 바꿀 수 있다. CLI 자동 탐색에 실패하면 `CLAUDE_BIN` 또는 `CODEX_BIN`에 절대경로를 지정한다.

시간을 바꾸려면 설치 전에 다음 템플릿을 편집하고 `bash scripts/install.sh`를 다시 실행한다.

- macOS: `templates/macos/*.plist`
- Ubuntu/Linux: `templates/linux/*.timer`

Codex 호출은 OpenAI 공식 문서의 비대화형 `codex exec` 인터페이스를 사용한다. `--ephemeral`은 실행 기록을 디스크에 남기지 않고, `--ignore-user-config`는 사용자 설정을 제외하되 기존 `CODEX_HOME` 인증은 유지한다.

## 기존 Claude 전용 설정에서 옮기기

예전 `com.mont.claude-session-warmup` LaunchAgent가 남아 있으면 새 Claude 작업과 중복 호출된다. 새 설치를 검증한 뒤 기존 작업을 내린다.

```bash
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.mont.claude-session-warmup.plist
launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/com.mont.claude-session-warmup-keepawake.plist
```

기존 plist와 `~/.local/bin/claude-session-warmup.sh`는 새 설치가 정상임을 확인한 뒤 직접 보관하거나 삭제한다.

## 제거

```bash
bash scripts/install.sh --uninstall
```

예약과 공통 실행기를 제거하며 로그는 남긴다. macOS의 `pmset` 반복 기상을 별도로 설정했다면 다른 반복 전원 일정이 없는지 먼저 확인한 뒤 취소한다.

```bash
pmset -g sched
sudo pmset repeat cancel
```

## 참고

- [OpenAI Codex CLI 명령 참고](https://developers.openai.com/codex/cli/reference)
- [OpenAI Codex 인증](https://developers.openai.com/codex/auth)
- [OpenAI Codex 사용량](https://developers.openai.com/codex/pricing)
