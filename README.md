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

## 스킬 추가하기

디렉토리 하나 만들고 `SKILL.md`에 frontmatter(`name`, `description`)를 채운 뒤 `install.sh`를 다시 돌린다.
