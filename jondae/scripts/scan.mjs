#!/usr/bin/env node
// scan — 대상 파일에서 평서체 종결과 문법 파손을 센다. LLM 콜 없음.
// 사용: node scan.mjs [--json] [--broken-only] <파일|디렉토리>...
import fs from 'fs';
import path from 'path';
import { findPlainEndings, findBroken } from './lib.mjs';

const args = process.argv.slice(2);
const asJson = args.includes('--json');
const brokenOnly = args.includes('--broken-only');
const targets = args.filter(a => !a.startsWith('--'));

if (!targets.length) {
  console.error('사용: node scan.mjs [--json] [--broken-only] <파일|디렉토리>...');
  process.exit(2);
}

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

const files = targets.flatMap(t => walk(t));
const report = [];
for (const f of files) {
  const text = fs.readFileSync(f, 'utf8');
  const broken = findBroken(text);
  const plain = brokenOnly ? [] : findPlainEndings(text);
  if (broken.length || plain.length) report.push({ file: f, broken, plain });
}

if (asJson) {
  console.log(JSON.stringify(report, null, 2));
} else {
  let tb = 0, tp = 0;
  for (const r of report) {
    tb += r.broken.length; tp += r.plain.length;
    console.log(`${r.file}  파손=${r.broken.length}  평서체=${r.plain.length}`);
    for (const b of r.broken.slice(0, 3)) console.log(`  파손 L${b.line}: ${b.word} — ${b.text}`);
    for (const p of r.plain.slice(0, 3)) console.log(`  평서 L${p.line}: ${p.word} — ${p.text}`);
  }
  console.log(`\n합계 — 파일 ${report.length}개 / 파손 ${tb}건 / 평서체 ${tp}건 (스캔 ${files.length}파일)`);
}
