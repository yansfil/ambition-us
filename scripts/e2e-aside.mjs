// poin E2E: Aside 브라우저에서 순간 4개 발화 → 반응 → 결과 → 결제 → 회고까지 돌리고 오류 0을 확인한다.
// 실행: node scripts/e2e-aside.mjs   (개발 서버 http://localhost:3100 이 떠 있어야 함)
// 각 단계는 aside repl 한 번(120초 제한)으로 돈다. 단계마다 테스트 전용 탭(?e2e=<runId>)을 다시 찾는다.
// 감지 모드(카메라), 한글 IME 조합 입력은 검증하지 않는다.
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const BASE = process.env.POIN_URL ?? 'http://localhost:3100';
const runId = Date.now().toString(36);
const startedAt = Date.now();
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
mkdirSync(path.join(root, 'artifacts'), { recursive: true });

// 모든 단계 앞에 붙는 공통 도우미 (REPL 안에서 실행됨)
const prelude = `
const __tabsAll = await listBrowserTabs();
const __mine = __tabsAll.find((t) => (t.url || '').includes('e2e=${runId}'));
if (!__mine) throw new Error('테스트 탭 없음');
await attachBrowserTab(__mine.targetId);
const out = (o) => console.log('E2E_RESULT ' + JSON.stringify(o));
const snap = () => page.evaluate(() => {
  const s = window.__poinTest.getState();
  return {
    traces: s.traces.map((t) => ({ type: t.moment.type, status: t.status, skip: t.skipReason ?? null,
      conf: t.infer?.confidence ?? null, prompt: t.infer?.intervention.prompt ?? null,
      options: t.infer?.intervention.options.map((o) => o.id) ?? [], via: t.reaction?.via ?? null,
      outcome: t.outcome?.description ?? null, turn: t.outcome?.turnSummary ?? null, error: t.error ?? null })),
    chip: s.activeChip && { type: s.activeChip.momentType, prompt: s.activeChip.prompt, options: s.activeChip.options.map((o) => o.id) },
    busy: s.chatBusy, ended: s.sessionEnded, shown: s.interventionsShown,
  };
});
const waitFor = async (pred, ms) => {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) { const s = await snap(); if (pred(s)) return { ok: true, ms: Date.now() - t0, s }; await sleep(250); }
  return { ok: false, ms: Date.now() - t0, s: await snap() };
};
const idle = () => waitFor((s) => !s.busy, 60000);
const center = async (sel, i = 0) => { const b = await page.locator(sel).nth(i).boundingBox(); return b && { x: b.x + b.width / 2, y: b.y + b.height / 2 }; };
const shot = async (name) => { const b = await page.screenshot(); console.log('E2E_SHOT ' + name + ' ' + Buffer.from(b).toString('base64')); };
const getVp = () => page.evaluate(() => ({ width: innerWidth, height: innerHeight }));
`;

const steps = [
  {
    name: '열기',
    code: `
for (let i = 0; i < 60 && !(await page.evaluate(() => !!window.__poinTest)); i++) await sleep(250);
const vp0 = await getVp();
await page.mouse.move(vp0.width / 2, vp0.height / 2, { steps: 5 });
const s0 = await snap();
out({ ok: s0.traces.length === 0 && !s0.busy, detail: { traces: s0.traces.length } });`,
  },
  {
    name: '순간1 요구 모호 → ⌥1',
    code: `
const inp = page.locator('[data-poin-target="input"]');
await inp.click();
const ib = await inp.boundingBox();
await page.mouse.move(ib.x + 120, ib.y + ib.height + 30, { steps: 4 });
await page.keyboard.type('집들이 선물로 뭐가', { delay: 60 });
for (let i = 0; i < 5; i++) await page.keyboard.press('Backspace');
await sleep(400);
await page.keyboard.type('뭘 사면', { delay: 60 });
for (let i = 0; i < 6; i++) await page.keyboard.press('Backspace');
const c = await waitFor((s) => s.chip?.type === 'ambiguous_request', 25000);
await shot('m1-chip');
if (!c.ok) { out({ ok: false, why: '칩 안 뜸', detail: c.s.traces.slice(0, 3) }); }
else {
  await page.keyboard.press('Alt+Digit1');
  const r = await waitFor((s) => s.traces[0]?.status === 'resolved' && !s.busy && !!s.traces[0]?.turn, 50000);
  out({ ok: r.ok, chipMs: c.ms, prompt: c.s.chip.prompt, detail: r.s.traces[0] });
}`,
  },
  {
    name: '추천 받기 (텍스트 3개)',
    code: `
const inp2 = page.locator('[data-poin-target="input"]');
await inp2.click();
await page.keyboard.press('Meta+A');
await page.keyboard.press('Backspace');
await page.keyboard.type('향이나 분위기 있는 거요. 실용적이면 더 좋고, 예산은 8만 원 안에서요', { delay: 15 });
await page.keyboard.press('Enter');
await sleep(800);
const r2 = await idle();
const paras = await page.locator('[data-poin-target^="msg:"]').last().locator('p').count();
const cards = await page.locator('[data-poin-target^="product:"]').count();
out({ ok: r2.ok && paras >= 3, detail: { paras, cards, ms: r2.ms } });`,
  },
  {
    name: '순간2 비교 망설임 → ⌥2(없으면 ⌥1)',
    code: `
const last = page.locator('[data-poin-target^="msg:"]').last();
const n = await last.locator('p').count();
const pa = await last.locator('p').nth(Math.min(1, n - 1)).boundingBox();
const pb = await last.locator('p').nth(Math.min(3, n - 1)).boundingBox();
for (let i = 0; i < 3; i++) {
  await page.mouse.move(pa.x + pa.width * 0.4, pa.y + pa.height / 2, { steps: 12 }); await sleep(700);
  await page.mouse.move(pb.x + pb.width * 0.4, pb.y + pb.height / 2, { steps: 12 }); await sleep(700);
}
const c2 = await waitFor((s) => !!s.chip, 20000);
await shot('m2-chip');
if (!c2.ok) { out({ ok: false, why: '칩 안 뜸', detail: c2.s.traces.slice(0, 3) }); }
else {
  const two = c2.s.chip.options.includes('accept2');
  await page.keyboard.press(two ? 'Alt+Digit2' : 'Alt+Digit1');
  const r = await waitFor((s) => s.traces[0]?.status === 'resolved' && !s.busy && !!s.traces[0]?.turn, 50000);
  const cards2 = await page.locator('[data-poin-target^="product:"]').count();
  out({ ok: c2.s.chip.type === 'comparison_hesitation' && r.ok, firedType: c2.s.chip.type, key: two ? '⌥2' : '⌥1', chipMs: c2.ms, cards: cards2, detail: r.s.traces[0] });
}`,
  },
  {
    name: '순간3 결정 직전 → Esc(대안)',
    code: `
const cnt = await page.locator('[data-poin-target^="add:"]').count();
if (!cnt) { out({ ok: false, why: '담기 버튼 없음(카드가 안 나옴)' }); }
else {
  const ab = await page.locator('[data-poin-target^="add:"]').first().boundingBox();
  await page.mouse.move(ab.x + ab.width / 2, ab.y + ab.height / 2, { steps: 10 });
  const c3 = await waitFor((s) => !!s.chip, 20000);
  await shot('m3-chip');
  if (!c3.ok) { out({ ok: false, why: '칩 안 뜸', detail: c3.s.traces.slice(0, 3) }); }
  else {
    await page.mouse.move(ab.x + ab.width / 2 + 40, ab.y - 60, { steps: 4 });
    await page.keyboard.press('Escape');
    const r = await waitFor((s) => s.traces[0]?.status === 'resolved' && !s.busy, 50000);
    out({ ok: c3.s.chip.type === 'pre_decision' && r.ok, firedType: c3.s.chip.type, chipMs: c3.ms, detail: r.s.traces[0] });
  }
}`,
  },
  {
    name: '순간4 다음 턴 제안 → 15초 무응답',
    code: `
await idle();
const vp4 = await getVp();
await page.mouse.move(vp4.width - 120, vp4.height * 0.45, { steps: 8 });
const c4 = await waitFor((s) => !!s.chip, 30000);
await shot('m4-chip');
if (!c4.ok) { out({ ok: false, why: '칩 안 뜸', detail: c4.s.traces.slice(0, 3) }); }
else {
  const r = await waitFor((s) => s.traces[0]?.via === 'timeout', 25000);
  out({ ok: c4.s.chip.type === 'next_turn' && r.ok, firedType: c4.s.chip.type, chipMs: c4.ms, prompt: c4.s.chip.prompt, detail: r.s.traces[0] });
}`,
  },
  {
    name: '담기 → 결제 → 회고',
    code: `
await idle();
const addN = await page.locator('[data-poin-target^="add:"]').count();
if (addN) await page.locator('[data-poin-target^="add:"]').first().click();
await sleep(800);
await idle();
await page.getByRole('button', { name: /장바구니/ }).first().click();
await sleep(400);
await page.locator('[data-poin-target="checkout"]').first().click();
const e = await waitFor((s) => s.ended, 60000);
await sleep(800);
const retro = await page.getByText(/순간을 알아챘고/).count();
await shot('retro');
out({ ok: e.ok && retro > 0, detail: { ended: e.s.ended, retro, traces: e.s.traces.length } });`,
  },
  {
    name: '클라이언트 로그 점검',
    code: `
const bad = await page.evaluate(() => window.__poinTest.logs().filter((l) => l.level === 'warn' || l.level === 'error').map((l) => l.level + ' [' + l.cat + '] ' + l.msg));
const fin = await snap();
out({ ok: !bad.some((b) => b.startsWith('error')), warnings: bad, traces: fin.traces.map((t) => t.type + ':' + t.status + (t.via ? '(' + t.via + ')' : '') + (t.skip ? '[' + t.skip + ']' : '')) });
await closeTab(page);`,
  },
];

const results = [];
// REPL이 연 탭은 그 호출이 끝나면 닫히므로, 테스트 탭은 Aside 앱에 직접 연다(단계마다 붙음)
execFileSync('open', ['-a', 'Aside', `${BASE}/?e2e=${runId}`]);
execFileSync('sleep', ['3']);
const only = Number(process.env.POIN_E2E_STEPS ?? steps.length);
for (const step of steps.slice(0, only)) {
  const t0 = Date.now();
  let raw = '';
  try {
    raw = execFileSync('aside', ['repl', prelude + step.code], { cwd: root, encoding: 'utf8', timeout: 125_000, maxBuffer: 64 * 1024 * 1024 });
  } catch (e) {
    raw = String(e.stdout ?? '') + String(e.stderr ?? '') + String(e.message ?? '');
  }
  for (const l of raw.split('\n').filter((x) => x.startsWith('E2E_SHOT '))) {
    const [, name, b64] = l.split(' ');
    writeFileSync(path.join(root, 'artifacts', `e2e-${runId}-${name}.png`), Buffer.from(b64, 'base64'));
  }
  const line = raw.split('\n').find((l) => l.includes('E2E_RESULT '));
  const res = line ? JSON.parse(line.slice(line.indexOf('E2E_RESULT ') + 11)) : { ok: false, why: '결과 없음', raw: raw.slice(-600) };
  res.sec = ((Date.now() - t0) / 1000).toFixed(1);
  results.push({ step: step.name, ...res });
  console.log(`${res.ok ? 'PASS' : 'FAIL'}  ${step.name}  (${res.sec}s)`);
  if (!res.ok) console.log('      ', JSON.stringify(res).slice(0, 700));
  if (step.name === '열기' && !res.ok) break;
}

// 서버 로그(같은 JSONL)에서 이번 실행 구간의 warn/error
const logDir = path.join(root, 'logs');
const serverBad = readdirSync(logDir).filter((f) => f.endsWith('.jsonl')).flatMap((f) =>
  readFileSync(path.join(logDir, f), 'utf8').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } })
).filter((e) => e && e.t >= startedAt && (e.level === 'warn' || e.level === 'error'));

console.log('\n── 요약 ──');
for (const r of results) {
  const extra = [r.firedType && `발화=${r.firedType}`, r.chipMs != null && `칩까지 ${r.chipMs}ms`, r.prompt && `"${r.prompt}"`].filter(Boolean).join(' · ');
  console.log(`${r.ok ? '✓' : '✗'} ${r.step}${extra ? '  ' + extra : ''}`);
}
const last = results.at(-1);
if (last?.traces) console.log('트레이스:', last.traces.join(' | '));
if (last?.warnings?.length) console.log('클라이언트 warn/error:', last.warnings);
console.log(`서버 warn/error ${serverBad.length}건`, serverBad.map((e) => `${e.level} [${e.cat}] ${e.msg}`));
console.log(`스크린샷: artifacts/e2e-${runId}-*.png`);
const failed = results.filter((r) => !r.ok).length + serverBad.filter((e) => e.level === 'error').length;
console.log(failed ? `\n결과: 실패 ${failed}` : '\n결과: 전부 통과');
process.exit(failed ? 1 : 0);
