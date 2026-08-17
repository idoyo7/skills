// jondae 공용 — 마크다운 마스킹과 종결어미 판정.
// 어투 변환은 산문 줄에서만 일어나야 한다. 코드·표·링크·frontmatter 는 판정 대상에서 아예 뺀다.

// 손대면 안 되는 줄인지 — 코드펜스 내부, frontmatter, 표 행, 헤딩.
// 반환: 줄 인덱스 → true(보호) 배열
export function protectedLines(text) {
  const lines = text.split('\n');
  const prot = new Array(lines.length).fill(false);
  let inFence = false, fenceMark = '';
  let inFront = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const t = line.trim();

    // frontmatter: 첫 줄이 --- 이면 다음 --- 까지
    if (i === 0 && t === '---') { inFront = true; prot[i] = true; continue; }
    if (inFront) { prot[i] = true; if (t === '---') inFront = false; continue; }

    const fence = t.match(/^(```+|~~~+)/);
    if (fence) {
      if (!inFence) { inFence = true; fenceMark = fence[1][0]; }
      else if (fence[1][0] === fenceMark) { inFence = false; }
      prot[i] = true;
      continue;
    }
    if (inFence) { prot[i] = true; continue; }

    if (/^\s{4,}\S/.test(line) && !/^\s*[-*+]\s/.test(line)) { prot[i] = true; continue; } // 들여쓰기 코드블록
    if (/^\s*#{1,6}\s/.test(line)) { prot[i] = true; continue; }                            // 헤딩
    if (/^\s*\|/.test(line)) { prot[i] = true; continue; }                                  // 표 행
  }
  return prot;
}

// 한 줄 안에서 손대면 안 되는 조각(인라인 코드·URL·shortcode·링크 타깃)을 가린다.
// 종결어미 검출이 이런 조각 안의 한글을 잡지 않게 하는 용도.
export function maskInline(line) {
  return line
    .replace(/`[^`]*`/g, m => ' '.repeat(m.length))
    .replace(/\{\{[<%][\s\S]*?[>%]\}\}/g, m => ' '.repeat(m.length))
    .replace(/\]\([^)]*\)/g, m => ' '.repeat(m.length))
    .replace(/https?:\/\/\S+/g, m => ' '.repeat(m.length));
}

// 평서체 종결 — "~다" 로 문장이 끝나는 자리. 존댓말(~니다)은 제외.
// 문장 끝 = 마침표/느낌표/물음표/말줄임표 또는 줄 끝.
const PLAIN_END = /([가-힣]{1,10}다)(?=([.!?…]|$))/g;

// "~다" 지만 평서체 종결이 아닌 것들 — 연결어미·관형형이라 바꾸면 문법이 깨진다.
const NOT_ENDING = /(니다|습니다|ㅂ니다|겠다는|다는|다면|다가|다고|다며|다시|보다|아니다만)$/;

export function findPlainEndings(text) {
  const lines = text.split('\n');
  const prot = protectedLines(text);
  const hits = [];
  for (let i = 0; i < lines.length; i++) {
    if (prot[i]) continue;
    const masked = maskInline(lines[i]);
    let m;
    PLAIN_END.lastIndex = 0;
    while ((m = PLAIN_END.exec(masked)) !== null) {
      const word = m[1];
      if (NOT_ENDING.test(word)) continue;
      hits.push({ line: i + 1, col: m.index + 1, word, text: lines[i].trim().slice(0, 120) });
    }
  }
  return hits;
}

// 어투 전환이 남기는 문법 파손 — `~하다`를 통째로 `~입니다`에 이어붙인 형태.
// 과거 실측(study-hugo, 2026-08): 90건/58파일. 구조 검증으로는 안 걸리므로 전용 검출이 필요하다.
// 어간을 캡처에 넣지 않는다 — 넣으면 치환문에서 어간이 중복된다(필요하 + 합니다 = 필요하합니다).
//
// 규칙 선정은 실데이터(study-hugo·jekyll·nextra-blog 코퍼스) 대조로 정했다. `명사 + 입니다`와
// 충돌하는 것은 전부 뺐다 — 오탐 한 건이 곧 문서 훼손이라, 놓치는 쪽이 망가뜨리는 쪽보다 낫다.
//   제외: 적입니다(구체적·효과적), 크입니다(리스크·벤치마크), 작입니다(동작·재시작)
const BROKEN = [
  [/하입니다/g, '합니다'],     // 필요하입니다 → 필요합니다 (아래 HA_NOUN 예외 적용)
  [/되입니다/g, '됩니다'],     // 무관되입니다 → 무관됩니다
  [/있입니다/g, '있습니다'],
  [/없입니다/g, '없습니다'],
  [/같입니다/g, '같습니다'],
  [/맞입니다/g, '맞습니다'],
  [/좋입니다/g, '좋습니다'],
  [/많입니다/g, '많습니다'],
  [/쉽입니다/g, '쉽습니다'],
  [/어렵입니다/g, '어렵습니다'],
];

// `~하` 로 끝나는 명사 — "이하입니다"·"부하입니다"는 정상이므로 하입니다 규칙에서 뺀다.
// `~하다` 용언은 수천 개라 열거가 불가능하지만, 이쪽 명사는 목록이 짧고 닫혀 있다.
const HA_NOUN = /(이하|부하|은하|영하|지하|산하|문하|휘하|각하|폐하|천하|치하|수하|누하)입니다/;

function isFalsePositive(text, index) {
  // 매치 앞 두 글자까지 포함해 명사 예외인지 본다
  const around = text.slice(Math.max(0, index - 2), index + 5);
  return HA_NOUN.test(around);
}

export function findBroken(text) {
  const lines = text.split('\n');
  const hits = [];
  for (let i = 0; i < lines.length; i++) {
    for (const [re] of BROKEN) {
      re.lastIndex = 0;
      let m;
      while ((m = re.exec(lines[i])) !== null) {
        if (isFalsePositive(lines[i], m.index)) continue;
        hits.push({ line: i + 1, word: m[0], text: lines[i].trim().slice(0, 120) });
      }
    }
  }
  return hits;
}

export function fixBroken(text) {
  let out = text, count = 0;
  for (const [re, rep] of BROKEN) {
    re.lastIndex = 0;
    out = out.replace(re, (match, offset, whole) => {
      if (isFalsePositive(whole, offset)) return match;
      count++;
      return rep;
    });
  }
  return { text: out, count };
}
