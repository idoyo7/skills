# deprecated

더는 쓰지 않는 스킬과 훅을 기록용으로 남겨둔 곳이다. `install.sh`는 이 디렉토리를 설치하지 않는다. 오히려 예전에 설치된 링크와 `settings.json` 훅 등록을 찾아 지운다.

스킬 본문은 `SKILL.md`에서 `SKILL.deprecated.md`로 이름을 바꿔 두었다. 누가 손으로 링크를 걸어도 Claude Code가 스킬로 읽지 않는다.

## freeze (2026-09-23 은퇴)

5시간 사용량 한도에 걸리면 handoff를 남기고 리셋 시각에 헤드리스로 재개하던 스킬이다. Claude Code가 한도 리셋 후 자동 재개를 기본 기능으로 갖추면서 필요가 없어졌다. 스크립트, 테스트, CHANGELOG는 그대로 두었다.

## hooks/workflow-arm (2026-09-23 은퇴)

freeze 예약 없이 큰 Workflow를 부르면 한 번 막고 `freeze.sh arm`을 안내하던 PreToolUse 훅이다. freeze가 은퇴하면서 안내할 대상이 사라져 함께 뺐다.
