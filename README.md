# skills

Claude Code 개인 스킬 모음. 스킬 하나가 디렉토리 하나고, 각 디렉토리의 `SKILL.md`가 본문이다.

## 설치

```bash
git clone git@github.com:idoyo7/skills.git ~/src/skills
~/src/skills/install.sh
```

`install.sh`는 `SKILL.md`를 가진 디렉토리마다 `~/.claude/skills/<이름>` 심링크를 걸어준다. 이미 같은 이름의 실디렉토리가 있으면 건너뛰고 알려주니, 수동으로 치운 뒤 다시 돌리면 된다.

## 수록 스킬

| 디렉토리 | 호출 이름 | 설명 |
|---|---|---|
| `wwe/` | `/wwe` | 마크다운 문서의 AI 티 제거 (문장 축 + 레이아웃 지문 축). humanize-korean 플러그인 필요 |
| `freeze/` | `/freeze` | 얼음! — 5시간 한도에 걸리면 handoff 를 남기고, 땡(리셋 시각)에 같은 세션을 헤드리스로 자동 재개하는 세션 예약 |
| `jondae/` | `/jondae` | 어투를 존댓말로 맞추는 마무리 패스 (`안된다 → 안됩니다`). 종결어미만 바꾸고 구조·수치·코드는 바이트 보존, 검증은 스크립트가 강제 |

## 수록 훅

`install.sh`가 스킬 심링크에 이어 Stop 훅 설치와 `settings.json` 등록까지 처리한다.

| 디렉터리 | 이벤트 | 설명 |
|---|---|---|
| `hooks/reply-check/` | Stop | 마지막 assistant 메시지의 한국어 산문을 세 축(무생물 주어·반복 구절·긴 문장)으로 검사, 기준 초과 시 재작성 요청 |

훅 설치만 건너뛰려면 `install.sh --no-hooks`로 실행한다.

## 스킬 추가하기

디렉토리 하나 만들고 `SKILL.md`에 frontmatter(`name`, `description`)를 채운 뒤 `install.sh`를 다시 돌린다.
