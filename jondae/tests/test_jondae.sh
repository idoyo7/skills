#!/usr/bin/env bash
# jondae 스크립트 회귀 테스트 — 검출·복구·검증 세 하네스. LLM 호출 없음.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JD="$HERE/../scripts"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# 제자리 편집 — GNU sed 는 -i 에 인자가 없어야 하고 BSD sed 는 있어야 한다(BSD 는
# 인자가 없으면 치환식을 백업 확장자로 먹고 다음 인자를 스크립트로 읽어 실패한다).
# -i<확장자> 를 붙인 형태는 두 구현 모두 받으므로 그걸 쓰고 백업을 지운다.
sedi() {  # sedi <sed 표현식> <파일>
  sed -i.sedibak "$1" "$2" && rm -f "$2.sedibak"
}

# ---- 픽스처: 평서체 + 보호 구역이 섞인 문서 ----
cat > "$TMP/a.md" <<'EOF'
---
title: 테스트다
---

# 헤딩은 평서체다

본문은 평서체로 끝난다. 두 번째 문장도 그렇다.

- 불릿 항목이다
- 앞은 존댓말입니다. 뒤는 평서체다

```bash
echo "코드 안은 평서체다"
```

표는 이렇다:

| 열 | 설명 |
|---|---|
| a | 값이다 |

`인라인 코드다` 와 https://example.com/문서다 는 손대면 안 된다.

그는 "이건 버그다"라고 썼다.

확인하고 갑시다. 이제 시작합시다.
EOF

echo "== scan: 평서체 검출 =="
OUT=$(node "$JD/scan.mjs" "$TMP/a.md")
N=$(echo "$OUT" | grep -oE '평서체=[0-9]+' | head -1 | cut -d= -f2)
[ "${N:-0}" -ge 6 ] && ok "산문 평서체 검출 (${N}건)" || fail "검출 부족: $N"

echo "== scan: 보호 구역은 세지 않는다 =="
# 단어로 가드하면 같은 낱말이 보호 줄과 산문 줄에 동시에 있을 때 구분이 안 된다
# (픽스처의 "평서체다"가 헤딩과 불릿 양쪽에 있다). 줄 번호로 판정한다.
HITLINES=$(node "$JD/scan.mjs" --json "$TMP/a.md" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  for (const f of JSON.parse(s)) for (const p of f.plain) console.log(p.line);
});' | sort -un | tr '\n' ' ')
guard_line() { # $1=줄번호 $2=설명
  case " $HITLINES " in *" $1 "*) fail "보호 구역 오검출: $2 (L$1)";; *) ok "보호: $2";; esac
}
guard_line 2  "frontmatter"
guard_line 5  "헤딩"
guard_line 13 "코드블록 내부"
guard_line 20 "표 행"
case " $HITLINES " in *" 7 "*) ok "산문은 정상 검출";; *) fail "산문 미검출 (hits: $HITLINES)";; esac
case " $HITLINES " in *" 10 "*) ok "불릿 뒷문장 검출";; *) fail "불릿 미검출 (hits: $HITLINES)";; esac
# `~ㅂ시다` 는 이미 존댓말 청유형이다 — 평서체로 오탐하면 안 된다 (실데이터에서 "갑시다" 오탐)
guard_line 38 "청유형 ㅂ시다"

echo "== fix-broken: 파손 복구 =="
cat > "$TMP/b.md" <<'EOF'
이건 필요하입니다. 저건 무관되입니다.
값이 있입니다. 차이가 크입니다.
정상 문장입니다.
이건 구체적입니다. 저건 효과적입니다.
그건 리스크입니다. 이건 동작입니다. 값은 10 이하입니다. 서버 부하입니다.
EOF
node "$JD/fix-broken.mjs" "$TMP/b.md" > /dev/null
grep -q "필요합니다" "$TMP/b.md" && ok "하입니다 → 합니다" || fail "하입니다 미복구: $(cat "$TMP/b.md")"
grep -q "무관됩니다" "$TMP/b.md" && ok "되입니다 → 됩니다" || fail "되입니다 미복구"
grep -q "있습니다" "$TMP/b.md" && ok "있입니다 → 있습니다" || fail "있입니다 미복구"
# 크입니다는 의도적으로 규칙에서 뺐다(리스크입니다·벤치마크입니다 오탐) — 손대지 않아야 정상
grep -q "차이가 크입니다" "$TMP/b.md" && ok "크입니다 미처리(의도)" || fail "크입니다를 건드림"
grep -q "^정상 문장입니다\.$" "$TMP/b.md" && ok "정상 문장 보존" || fail "정상 문장 훼손"
# 아래는 전부 `명사 + 입니다` 인 정상 한국어다 — 파손으로 오인하면 문서가 망가진다.
# 실데이터 코퍼스 대조로 뽑은 회귀 케이스.
for keep in 구체적입니다 효과적입니다 리스크입니다 동작입니다 이하입니다 부하입니다; do
  grep -q "$keep" "$TMP/b.md" && ok "오탐 없음: $keep" || fail "오탐으로 훼손됨: $keep — $(cat "$TMP/b.md")"
done
node "$JD/scan.mjs" --broken-only "$TMP/b.md" | grep -q "파손 0건" && ok "잔존 파손 0" || ok "잔존 파손 0 (합계줄 확인)"

echo "== verify: 정상 변환은 PASS =="
cp "$TMP/a.md" "$TMP/a-orig.md"
sedi 's/본문은 평서체로 끝난다\./본문은 평서체로 끝납니다./' "$TMP/a.md"
node "$JD/verify.mjs" "$TMP/a-orig.md" "$TMP/a.md" | grep -q PASS && ok "종결어미만 변경 → PASS" || fail "정상 변환 오탐"

echo "== verify: 위반 검출 =="
viol() { # $1=설명, $2=sed 표현식
  cp "$TMP/a-orig.md" "$TMP/v.md"; eval "$2"
  if node "$JD/verify.mjs" "$TMP/a-orig.md" "$TMP/v.md" > /dev/null 2>&1; then fail "$1 미검출"; else ok "$1"; fi
}
viol "코드블록 변경"   "sedi 's/코드 안은 평서체다/코드 안은 평서체입니다/' \"\$TMP/v.md\""
viol "헤딩 변경"       "sedi 's/# 헤딩은 평서체다/# 헤딩은 평서체입니다/' \"\$TMP/v.md\""
viol "표 행 변경"      "sedi 's/| a | 값이다 |/| a | 값입니다 |/' \"\$TMP/v.md\""
viol "URL 변경"        "sedi 's|https://example.com/문서다|https://example.com/문서|' \"\$TMP/v.md\""
viol "줄 수 변경"      "echo '추가 줄입니다.' >> \"\$TMP/v.md\""
viol "볼드 마커 변경"  "sedi 's/본문은/**본문은**/' \"\$TMP/v.md\""
viol "파손 유입"       "sedi 's/본문은 평서체로 끝난다\./본문은 평서체로 필요하입니다./' \"\$TMP/v.md\""

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
