# 링크 종합 테스트

## 인라인 링크

이 문서는 [한글 링크 텍스트가 있는 링크](https://example.com/ko/문서)를 포함한다. 링크 텍스트는 산문에 남아야 하지만 목적지 URL은 토큰으로 치환되어야 한다.

제목 속성이 있는 링크도 있다: [제목 속성 링크](https://example.com/page "이것은 제목입니다").

## 참조 링크

이건 [참조 스타일 링크][ref1]이고, 이건 [축약형 참조][]다.

문단 끝에 참조 정의가 몰려 있다.

[ref1]: https://example.com/reference-one "참조 제목"
[축약형 참조]: https://example.com/shorthand

## 자동 링크와 맨 URL

자동 링크는 이렇게 생겼다: <https://example.com/autolink>. 그리고 아무 장식 없는 맨 URL도 있다: https://example.com/bare/url?query=1&other=2 처럼 그냥 텍스트 중간에 등장하기도 한다.

이메일 자동 링크도 있다: <someone@example.com>.

## 이미지

![대체 텍스트, 한글도 포함](https://example.com/images/그림.png "이미지 제목")

참조 스타일 이미지: ![참조 이미지][img-ref]

[img-ref]: https://example.com/images/ref-image.png

## 각주

본문에 각주 참조가 있다[^1]. 그리고 이름이 있는 각주도 있다[^named-note].

[^1]: 이것은 첫 번째 각주의 내용이다. 각주 정의 줄 전체가 하나의 블록으로 취급되어야 한다.
[^named-note]: 이름이 붙은 각주의 내용, https://example.com/footnote-link 같은 URL도 포함할 수 있다.

## 한글 앵커 링크

같은 문서 안의 [가 나 다 섹션](#가-나-다-섹션)으로 이동하는 링크와, [자동 생성 앵커](#한글-앵커-링크)로 이동하는 링크가 있다.

### 가 나 다 섹션

한글 헤딩 텍스트로부터 생성된 앵커를 가리키는 링크가 위에 있었다. 이 헤딩 텍스트 자체는 절대 바뀌면 안 된다.

## 커스텀 ID가 붙은 헤딩 {#custom-anchor-id}

이 헤딩에는 `{#custom-anchor-id}` 형태의 커스텀 앵커가 붙어있다. [이 앵커를 가리키는 링크](#custom-anchor-id)도 있다.
