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
