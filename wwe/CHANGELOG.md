# CHANGELOG

## 1.3.0 — 2026-08-23

작성자 반복 구절 검출·시드 기반 제거·보존 warn 판독표를 더했다.

`scripts/author_repeat.py` 신설 — build(코퍼스 프로필 생성)/scan(문서 검사, 보고 전용)/suggest(시드 자동 갱신)/gen-block(시드→윤문 지침 블록) 네 하위 명령. verb·adv·ngram 우선, 주제 명사 0.3배 가중, 약한 어미 2단계 확인.

`references/author-tics.txt` 신설 — 장르별 섹션(에세이 12개/기술 게시글 15개), `표현 => 대체 지시문` 형식. Phase 4에서 gen-block이 이 파일을 읽어 윤문 지침 블록을 만들고, Phase 7 게이트 C 옆에서 scan이 시드 잔존 여부를 검사해 `author_repeat_seed.txt`에 기록한다(exit에는 영향 없음).

`references/author-repeat-stop.txt` 신설 — 검출 시 걸러낼 불용어 목록.

`tests/test_author_repeat.py` 신설 — 41개 회귀 테스트.

게이트 B 판독표에 보존 warn 행(`entity_lost`·`number_dropped`, action=none) 추가. humanize-korean 플러그인의 P5 보존 축(feat/entity-lost-gate 브랜치, PR 전)과 짝을 맞춘 것으로, 플러그인이 합쳐지기 전까지 이 행은 무해하다.

## 1.2.0

경제 모드(파일당 LLM 1콜 상한)를 기본값으로, 이어서/재개로 중단 없이 이어가기, 헤딩 편집·축약 옵션을 추가했다. 게이트 D(헤딩 앵커 무결성)와 `scripts/heading_anchor.py`를 신설했다.
