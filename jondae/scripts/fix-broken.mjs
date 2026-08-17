#!/usr/bin/env node
// fix-broken — 어투 전환이 남긴 문법 파손(`필요하입니다` 류)을 결정적으로 복구한다. LLM 콜 없음.
// 사용: node fix-broken.mjs [--dry] <파일|디렉토리>...
import fs from 'fs';
import path from 'path';
import { fixBroken, findBroken } from './lib.mjs';

const args = process.argv.slice(2);
const dry = args.includes('--dry');
const targets = args.filter(a => !a.startsWith('--'));
if (!targets.length) { console.error('사용: node fix-broken.mjs [--dry] <파일|디렉토리>...'); process.exit(2); }

function walk(p, acc = []) {
  const st = fs.statSync(p);
  if (st.isDirectory()) {
    for (const e of fs.readdirSync(p)) {
      if (e === 'node_modules' || e === '.git' || e === '_workspace') continue;
      walk(path.join(p, e), acc);
    }
  } else if (p.endsWith('.md')) acc.push(p);
  return acc;
}

let total = 0, touched = 0;
for (const f of targets.flatMap(t => walk(t))) {
  const text = fs.readFileSync(f, 'utf8');
  const before = findBroken(text).length;
  if (!before) continue;
  const { text: out, count } = fixBroken(text);
  total += count; touched++;
  console.log(`${dry ? '[dry] ' : ''}${f} — ${count}건`);
  if (!dry) fs.writeFileSync(f, out);
}
console.log(`${dry ? '[dry] ' : ''}합계 ${total}건 / ${touched}파일`);
