# skills

Claude Code 개인 스킬과 부속 유틸리티 모음. 스킬은 디렉토리 하나가 단위고, 각 디렉토리의 `SKILL.md`가 본문이다.

## 설치

```bash
git clone git@github.com:idoyo7/skills.git ~/src/skills
~/src/skills/install.sh
```

`install.sh`는 `SKILL.md`를 가진 디렉토리마다 `~/.claude/skills/<이름>` 심링크를 걸어준다. 이미 같은 이름의 실디렉토리가 있으면 건너뛰고 알려주니, 수동으로 치운 뒤 다시 돌리면 된다.

스킬 밑에 `agents/` 디렉토리가 있으면 그 안의 `*.md`도 `~/.claude/agents/`에 심링크한다. 스킬이 `Agent` 도구로 부르는 서브에이전트는 거기 있어야 인식되기 때문이다. 규칙은 스킬과 같다 — 같은 이름의 실파일이 있으면 건너뛰고 알린다.

## 수록 스킬

| 디렉토리 | 호출 이름 | 설명 |
|---|---|---|
| `wwe/` | `/wwe` | 마크다운 윤문·구조 재작성·Astra high 최종 퇴고 handoff(v1.7). 한국어 명확성 지침을 모든 편집 경로에 공통 적용 |
| `jondae/` | `/jondae` | 어투를 존댓말로 맞추는 마무리 패스 (`안된다 → 안됩니다`). 종결어미만 바꾸고 구조·수치·코드는 바이트 보존, 검증은 스크립트가 강제 |

## 수록 훅

`install.sh`가 스킬 심링크에 이어 각 훅의 설치(심링크)와 `settings.json` 등록까지 처리한다. 어느 이벤트에 등록될지는 훅 디렉토리 안의 `hook.conf`가 선언한다.

| 디렉터리 | 이벤트 | 설명 |
|---|---|---|
| `hooks/reply-check/` | Stop | 마지막 assistant 메시지의 한국어 산문을 세 축(무생물 주어·반복 구절·긴 문장)으로 검사, 기준 초과 시 재작성 요청 |

훅 설치만 건너뛰려면 `install.sh --no-hooks`로 실행한다.

## 유틸리티

| 디렉토리 | 설명 |
|---|---|
| [`warmup/`](warmup/) | Claude Code와 Codex의 5시간 사용 구간을 평일 고정 시각에 맞추는 macOS launchd / Ubuntu systemd 자동화와 설치 가이드 |

## 은퇴한 스킬·훅

[`deprecated/`](deprecated/)에 보관만 하고 설치하지 않는다. `install.sh`를 다시 돌리면 예전에 걸어둔 링크와 `settings.json` 등록을 걷어낸다.

| 디렉토리 | 은퇴일 | 사유 |
|---|---|---|
| `deprecated/freeze/` | 2026-09-23 | Claude Code에 한도 리셋 후 자동 재개가 기본으로 들어와서 |
| `deprecated/hooks/workflow-arm/` | 2026-09-23 | freeze 예약을 강제하던 훅이라 freeze와 함께 은퇴 |

## 스킬 추가하기

디렉토리 하나 만들고 `SKILL.md`에 frontmatter(`name`, `description`)를 채운 뒤 `install.sh`를 다시 돌린다.
