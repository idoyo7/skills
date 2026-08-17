---
title: "Hugo/Jekyll 쇼트코드 테스트"
---

# 정적 사이트 생성기 쇼트코드

## Hugo 쇼트코드 (자기 줄 단독)

{{< figure src="/images/그림.png" alt="한글 대체 텍스트" caption="캡션도 한글" >}}

{{< youtube dQw4w9WgXcQ >}}

## Hugo 인라인 쇼트코드

이 문장 중간에 {{< ref "다른-문서.md" >}} 같은 인라인 쇼트코드가 섞여 있다. 그리고 {{% notice warning %}} 스타일도 있다.

## Jekyll/Liquid 태그

{% raw %}
이 블록 안의 {{ variable }}은 렌더링되지 않는 리터럴 텍스트여야 한다.
{% endraw %}

{% highlight python %}
def 함수():
    return "이건 jekyll highlight 태그 안의 코드다"
{% endhighlight %}

## Liquid 변수 인라인

안녕하세요 {{ user.name }}님, 오늘 날짜는 {{ "now" | date: "%Y-%m-%d" }} 입니다. 이 변수들은 문장 중간에 인라인으로 등장한다.

## include 태그

{% include 알림배너.html title="공지" %}

## 조건문 태그

{% if page.draft %}
이 문서는 초안입니다.
{% endif %}

쇼트코드와 태그들이 섞인 마지막 문단이다. {{< param 사이트이름 >}}이라는 값을 이 문장 안에서 참조하고 있다.
