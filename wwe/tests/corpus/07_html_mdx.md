# HTML과 MDX 테스트

## HTML 블록

<div class="warning">
  <p>이것은 HTML 블록이다. 안에 <strong>한글</strong>과 태그가 섞여 있다.</p>
  <ul>
    <li>항목 하나</li>
    <li>항목 둘</li>
  </ul>
</div>

HTML 블록 다음에 이어지는 평범한 마크다운 문단이다.

## 인라인 HTML 태그

이 문장에는 <mark>강조된 부분</mark>과 <sub>아래첨자</sub>, <sup>위첨자</sup>가 섞여 있다. 그리고 줄바꿈을 위한 <br/> 태그도 있다.

## details/summary 접기 블록

<details>
<summary>클릭해서 펼치기 (한글 요약)</summary>

이 안에는 마크다운이 들어갈 수도 있다.

- 리스트 항목
- 하나 더

```bash
echo "details 안의 코드블록"
```

</details>

## MDX 컴포넌트

<Callout type="warning">
  이것은 MDX 컴포넌트다. React 컴포넌트처럼 생겼지만 이 문서에서는 그냥 HTML 블록으로 취급되어야 한다.
</Callout>

<Tabs>
  <Tab label="한글 탭">
    탭 안의 내용, 한글 포함.
  </Tab>
  <Tab label="영어 탭">
    English content inside a tab.
  </Tab>
</Tabs>

self-closing 컴포넌트도 있다: <Divider className="my-4" />

## 자기 줄 단독이 아닌 인라인 HTML

이 문단 중간에 <span style="color:red">빨간 글씨</span>가 인라인으로 섞여 있고, 문장은 계속 이어진다.
