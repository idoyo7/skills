+++
title = "TOML 프론트매터 테스트"
description = "플러스 기호 세 개로 감싼 프론트매터, 한글 값 포함"
date = 2026-08-06T09:00:00+09:00
draft = false
weight = 7

[taxonomies]
tags = ["러스트", "toml", "정적사이트"]
categories = ["개발노트"]

[extra]
author = "이영희"
comment = "따옴표 안에 한글, 그리고 = 기호도 있다 x = y"
+++

# TOML frontmatter 문서

이 파일은 `+++`로 감싼 TOML frontmatter를 사용한다. Hugo나 Zola 같은 정적 사이트 생성기에서 흔히 쓰는 형식이다.

frontmatter 블록은 `+++`로 시작해서 다음 `+++`로 끝나는 구간 전체를 가리키며, 안에 등장하는 `[taxonomies]`, `[extra]` 같은 TOML 섹션 헤더나 `=` 기호가 마크다운 문법으로 오해되면 안 된다.

## 본문

본문은 평범한 한글 문단이다. 이 문서의 목적은 마스킹 로직이 `---` frontmatter뿐 아니라 `+++` frontmatter도 동일하게 하나의 블록으로 인식하는지 확인하는 것이다.
