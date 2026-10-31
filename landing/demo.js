(() => {
  'use strict';

  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ---------------- scroll reveal ---------------- */
  const revealer = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      e.target.classList.add('in');
      revealer.unobserve(e.target);
    });
  }, { threshold: 0.15, rootMargin: '0px 0px -40px 0px' });
  $$('.reveal').forEach((el) => revealer.observe(el));

  /* 150 dots, one lit: 3,482 of ~530,000 kiosks */
  const dots = $('.dots');
  if (dots) dots.innerHTML = Array.from({ length: 150 }, (_, i) => `<i${i === 0 ? ' class="hit"' : ''}></i>`).join('');

  /* ---------------- kiosk simulation ---------------- */
  const screen = $('#screen');
  if (!screen) return;

  const MENU = [
    { id: 'americano', name: '아메리카노', price: 4500, c: '#3b2519', hot: true },
    { id: 'latte', name: '카페라떼', price: 5000, c: '#c8996a', hot: true },
    { id: 'yuja', name: '유자차', price: 5500, c: '#f2b530', hot: true },
    { id: 'grapefruit', name: '자몽에이드', price: 6000, c: '#f07a68', ice: true },
    { id: 'vanilla', name: '바닐라라떼', price: 5500, c: '#e6cb9c', hot: true },
    { id: 'greentea', name: '녹차라떼', price: 5500, c: '#8db65a', hot: true },
  ];
  const won = (n) => `${n.toLocaleString('ko-KR')}원`;
  const cup = ({ c, hot, ice }) => `
    <svg viewBox="0 0 64 64" aria-hidden="true">
      ${hot ? '<path class="steam" d="M27 12c-2.2-2.4 2.2-4.2 0-7M37 12c-2.2-2.4 2.2-4.2 0-7"/>' : ''}
      <ellipse cx="32" cy="57.5" rx="15" ry="2.6" fill="rgba(60,40,20,.10)"/>
      <path d="M18.5 19h27l-3.1 33.2a4 4 0 0 1-4 3.6H25.6a4 4 0 0 1-4-3.6z" fill="#fff" stroke="#e4dccf" stroke-width="1.2"/>
      <path d="M20.3 27.5h23.4l-2.3 24.9a2.8 2.8 0 0 1-2.8 2.5H25.4a2.8 2.8 0 0 1-2.8-2.5z" fill="${c}"/>
      ${ice ? '<rect x="25" y="31" width="6" height="6" rx="1.4" fill="rgba(255,255,255,.7)" transform="rotate(-12 28 34)"/><rect x="33" y="35" width="6" height="6" rx="1.4" fill="rgba(255,255,255,.55)" transform="rotate(14 36 38)"/>' : ''}
      <rect x="16" y="15" width="32" height="5" rx="2.5" fill="#eae3d7"/>
    </svg>`;

  const grid = $('#kGrid');
  grid.innerHTML = MENU.map((m) => `
    <div class="k-item" data-id="${m.id}">${cup(m)}<b>${m.name}</b><span>${won(m.price)}</span><i class="k-badge"></i></div>`).join('');

  const ui = $('#kUI');
  const gaze = $('#gaze');
  const agent = $('#agent');
  const agentTag = $('#agentTag');
  const bubble = $('#bubble');
  const tapEl = $('#tap');
  const hes = $('#hes');
  const sheet = $('#sheet');
  const confirmEl = $('#confirm');
  const cardStep = $('#cardStep');
  const done = $('#done');
  const caps = $('#captions');
  const logList = $('#logList');
  const playBtn = $('#playBtn');
  const replayBtn = $('#replayBtn');
  const byId = (id) => document.getElementById(id);
  const item = (id) => grid.querySelector(`[data-id="${id}"]`);
  const resolve = (t) => (typeof t === 'string' ? item(t) : t);

  /* ---- timing: cancellable, pausable sleeps on a demo clock ---- */
  let token = 0;
  let paused = false;
  let running = false;
  let clock = 0;
  class Cancel extends Error {}

  function sleep(ms, tk) {
    return new Promise((res, rej) => {
      let left = ms;
      let last = performance.now();
      const tick = (now) => {
        if (tk !== token) { rej(new Cancel()); return; }
        const d = Math.min(now - last, 64);
        last = now;
        if (!paused) { left -= d; clock += d; }
        if (left <= 0) res(); else requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });
  }

  /* ---- geometry relative to the kiosk screen ---- */
  function rel(el) {
    const s = screen.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    return { x: r.left - s.left, y: r.top - s.top, w: r.width, h: r.height };
  }

  let gazeTarget = null;
  let frameTarget = 'screen';
  let tags = [];

  /* ---- gaze motion ----
     A webcam gaze estimate is never still: it overshoots on a saccade, shakes
     around a fixation and drifts. A damped spring carries the glass toward the
     target, and two Ornstein–Uhlenbeck processes add fast tremor and slow drift.
     Shake is large while the customer is lost and small once they settle. */
  const G = { x: 0, y: 0, vx: 0, vy: 0, tx: 0, ty: 0, omega: 10, zeta: 0.75, shake: 0.006, fx: 0, fy: 0, dx: 0, dy: 0, last: 0, raf: 0 };
  const gauss = () => {
    let u = 0;
    while (!u) u = Math.random();
    return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * Math.random());
  };
  // stationary std of each process equals `sigma`
  const ou = (n, tau, sigma, dt) => n - (n / tau) * dt + sigma * Math.sqrt((2 * dt) / tau) * gauss();

  function renderGaze() {
    const half = gaze.offsetWidth / 2;
    gaze.style.transform = `translate3d(${G.x + G.fx + G.dx - half}px, ${G.y + G.fy + G.dy - half}px, 0)`;
  }

  function gazeTick(now) {
    G.raf = requestAnimationFrame(gazeTick);
    const dt = Math.min((now - (G.last || now)) / 1000, 1 / 30);
    G.last = now;
    if (paused || dt <= 0) return;
    const w2 = G.omega * G.omega;
    const damp = 2 * G.zeta * G.omega;
    G.vx += (w2 * (G.tx - G.x) - damp * G.vx) * dt;
    G.vy += (w2 * (G.ty - G.y) - damp * G.vy) * dt;
    G.x += G.vx * dt;
    G.y += G.vy * dt;
    const amp = reduceMotion ? 0 : G.shake * screen.clientWidth;
    G.fx = ou(G.fx, 0.07, amp, dt);
    G.fy = ou(G.fy, 0.07, amp, dt);
    G.dx = ou(G.dx, 0.9, amp * 1.6, dt);
    G.dy = ou(G.dy, 0.9, amp * 1.6, dt);
    renderGaze();
  }
  const startGaze = () => { if (!G.raf) G.raf = requestAnimationFrame(gazeTick); };
  const gazeShake = (level) => { G.shake = level; };

  // `dur` ≈ settle time (ms); lower `zeta` = more overshoot
  function look(target, dur = 520, jitter = 0, zeta = 0.75) {
    gazeTarget = target;
    const r = rel(resolve(target));
    G.tx = r.x + r.w / 2 + (Math.random() - 0.5) * jitter;
    G.ty = r.y + r.h / 2 + (Math.random() - 0.5) * jitter;
    if (dur <= 0 || reduceMotion) {
      G.x = G.tx;
      G.y = G.ty;
      G.vx = 0;
      G.vy = 0;
      renderGaze();
      return;
    }
    G.zeta = zeta;
    G.omega = 4 / (zeta * (dur / 1000));
  }

  function frame(target, pad) {
    frameTarget = target;
    let r;
    if (target === 'screen') {
      const w = screen.clientWidth;
      const m = w * 0.02;
      r = { x: m, y: m, w: w - m * 2, h: screen.clientHeight - m * 2 };
      pad = 0;
      agent.classList.add('full');
    } else {
      r = rel(resolve(target));
      pad = pad ?? screen.clientWidth * 0.014;
      agent.classList.remove('full');
    }
    agent.style.left = `${r.x - pad}px`;
    agent.style.top = `${r.y - pad}px`;
    agent.style.width = `${r.w + pad * 2}px`;
    agent.style.height = `${r.h + pad * 2}px`;
  }

  const agentState = (text, mode = '') => { agentTag.textContent = text; agent.dataset.mode = mode; };
  const restart = (el, cls) => { el.classList.remove(cls); void el.offsetWidth; el.classList.add(cls); };
  const agentClick = () => restart(agent, 'click');

  async function press(el, tk) {
    el.classList.add('pressed');
    await sleep(200, tk);
    el.classList.remove('pressed');
  }

  function userTap(el) {
    const r = rel(el);
    tapEl.style.left = `${r.x + r.w / 2}px`;
    tapEl.style.top = `${r.y + r.h / 2}px`;
    restart(tapEl, 'go');
  }

  function say(text, anchor) {
    bubble.classList.remove('on');
    bubble.innerHTML = `<b>키오</b>${text}`;
    const r = rel(anchor);
    const W = screen.clientWidth;
    const H = screen.clientHeight;
    const m = W * 0.04;
    const gap = W * 0.035;
    const bw = bubble.offsetWidth;
    const bh = bubble.offsetHeight;
    let top = r.y + r.h + gap;
    if (top + bh > H - m) top = r.y - bh - gap;
    top = Math.max(top, m);
    const left = Math.min(Math.max(r.x + r.w / 2 - bw / 2, m), W - bw - m);
    bubble.style.left = `${left}px`;
    bubble.style.top = `${top}px`;
    requestAnimationFrame(() => bubble.classList.add('on'));
  }
  const hush = () => bubble.classList.remove('on');

  function placeTag(t) {
    const r = rel(item(t.id));
    t.el.style.left = `${r.x + r.w - t.el.offsetWidth - r.w * 0.06}px`;
    t.el.style.top = `${r.y - screen.clientWidth * 0.035}px`;
  }
  function tag(id, text, time) {
    const el = document.createElement('div');
    el.className = 'tag';
    el.innerHTML = `${text}<small>${time}</small>`;
    ui.append(el);
    const t = { id, el };
    tags.push(t);
    placeTag(t);
    requestAnimationFrame(() => el.classList.add('on'));
  }

  /* ---- captions ---- */
  function line(who) {
    const el = document.createElement('div');
    el.className = `cap ${who === '키오' ? 'is-agent' : 'is-user'}`;
    el.innerHTML = `<span class="who">${who}</span><p></p>`;
    caps.append(el);
    while (caps.children.length > 2) caps.firstElementChild.remove();
    return el.lastElementChild;
  }
  function word(p, text, cls) {
    const s = document.createElement('span');
    s.className = cls ? `w ${cls}` : 'w';
    s.textContent = text;
    p.append(s, ' ');
    return s;
  }
  async function speak(p, text, tk, gap = 85) {
    for (const t of text.split(' ')) {
      word(p, t);
      await sleep(gap, tk);
    }
  }

  /* ---- event log ---- */
  const fmt = (ms) => {
    const s = ms / 1000;
    return `${String(Math.floor(s / 60)).padStart(2, '0')}:${(s % 60).toFixed(2).padStart(5, '0')}`;
  };
  function ev(type, msg) {
    const li = document.createElement('li');
    li.dataset.type = type;
    li.innerHTML = `<time>${fmt(clock)}</time><b>${type}</b><span>${msg}</span>`;
    logList.append(li);
    while (logList.children.length > 8) logList.firstElementChild.remove();
  }

  /* ---- rail ---- */
  const STEPS = ['observe', 'hesitate', 'offer', 'understand', 'act', 'confirm'];
  function step(name) {
    const i = STEPS.indexOf(name);
    $$('.rail li').forEach((li, j) => {
      li.classList.toggle('active', j === i);
      li.classList.toggle('done', name === 'end' || (i > -1 && j < i));
    });
  }

  /* ---- cart ---- */
  let cart = [];
  function renderCart() {
    const count = cart.reduce((a, c) => a + c.qty, 0);
    const total = cart.reduce((a, c) => a + c.qty * c.price, 0);
    byId('cartCount').textContent = count ? `담은 메뉴 ${count}개` : '담은 메뉴 없음';
    byId('cartTotal').textContent = won(total);
    $$('.k-item', grid).forEach((el) => {
      const c = cart.find((x) => x.id === el.dataset.id);
      el.classList.toggle('in-cart', Boolean(c));
      el.querySelector('.k-badge').textContent = c ? c.qty : '';
    });
    byId('confirmList').innerHTML = cart
      .map((c) => `<li><span>${c.name} <em>${c.opt}</em></span><b>${won(c.price * c.qty)}</b></li>`)
      .join('');
    byId('confirmTotal').textContent = won(total);
  }
  function addToCart(id, opt) {
    const m = MENU.find((x) => x.id === id);
    cart.push({ id, name: m.name, price: m.price, qty: 1, opt });
    renderCart();
    restart(byId('kCart'), 'bump');
  }

  function reset() {
    cart = [];
    renderCart();
    ui.classList.remove('dim', 'observing');
    [sheet, confirmEl, cardStep, done].forEach((el) => el.classList.remove('on'));
    $$('.k-opt', ui).forEach((o) => o.classList.remove('sel'));
    tags.forEach((t) => t.el.remove());
    tags = [];
    caps.innerHTML = '';
    logList.innerHTML = '';
    hush();
    hes.className = 'hes';
    gaze.classList.remove('on', 'speaking');
    gazeTarget = null;
    gazeShake(0.005);
    agent.className = 'agent idle';
    agentState('듣는 중');
    frame('screen');
    clock = 0;
    step(null);
  }

  /* ---------------- the scenario ---------------- */
  async function run(tk) {
    reset();
    await sleep(700, tk);

    // 01 관찰
    step('observe');
    ev('system', '손님 감지 · 화면 앞 0.6m');
    look('americano', 0);
    gaze.classList.add('on');
    await sleep(500, tk);
    ev('gaze', '추적 시작 · 터치 위치로 자동 보정');
    const wander = ['grapefruit', 'greentea', 'latte', 'americano', 'vanilla', 'grapefruit', 'latte', 'greentea'];
    const start = clock;
    gazeShake(0.009);
    for (let i = 0; i < wander.length; i++) {
      look(wander[i], 560, screen.clientWidth * 0.1, 0.6);
      await sleep(660 + Math.random() * 300, tk);
      hes.innerHTML = `<span>터치 없음 <b>${((clock - start) / 1000 + 1.4).toFixed(1)}s</b></span><span>시선 이동 <b>${i + 1}회</b></span>`;
      hes.classList.add('on');
      ui.classList.add('observing');
    }

    // 02 망설임 감지
    step('hesitate');
    gazeShake(0.007);
    hes.classList.add('alert');
    hes.innerHTML = '<span>망설임 감지</span><span><b>0.82</b></span>';
    ev('intent', '망설임 0.82 · 터치 없음 · 시선 반복 이동');
    await sleep(1000, tk);

    // 03 먼저 말 걸기
    step('offer');
    hes.classList.remove('on');
    ui.classList.remove('observing');
    agent.classList.remove('idle');
    agentState('안내 중');
    frame(byId('kHint'));
    await sleep(700, tk);
    say('천천히 하셔도 돼요. 드시고 싶은 걸 보면서 말씀해 주세요.', byId('kHint'));
    let p = line('키오');
    ev('act', '음성 안내 · 말로 주문 제안');
    await speak(p, '천천히 하셔도 돼요. 드시고 싶은 걸 보면서 말씀해 주세요.', tk);
    await sleep(1700, tk);
    hush();
    agent.classList.add('idle');
    agentState('듣는 중');
    frame('screen');

    // 04 시선과 말 연결
    step('understand');
    gazeShake(0.004);
    look('yuja', 680, 0, 0.7);
    await sleep(750, tk);
    ev('gaze', '응시 · 유자차 0.42s');
    gaze.classList.add('speaking');
    ev('speech', '발화 시작 · 화면 앞 손님 입 움직임 일치');
    p = line('손님');
    word(p, '응,');
    await sleep(380, tk);
    word(p, '이거', 'dx');
    tag('yuja', '이거', '0.62s');
    ev('bind', '“이거” → 유자차 · 0.94');
    await sleep(440, tk);
    word(p, '하나');
    await sleep(330, tk);
    word(p, '따뜻한');
    await sleep(360, tk);
    word(p, '걸로');
    await sleep(420, tk);
    gaze.classList.remove('speaking');
    ev('intent', '담기 · 유자차 · 따뜻하게 · 1잔');
    await sleep(300, tk);

    // 05 대신 누르기
    step('act');
    agent.classList.remove('idle');
    agentState('누르는 중');
    frame('yuja');
    await sleep(780, tk);
    agentClick();
    press(item('yuja'), tk);
    ev('act', 'press · 유자차');
    await sleep(380, tk);
    ui.classList.add('dim');
    sheet.classList.add('on');
    await sleep(620, tk);
    look(byId('optHot'), 450);
    frame(byId('optHot'));
    await sleep(720, tk);
    agentClick();
    byId('optHot').classList.add('sel');
    ev('act', '옵션 · 따뜻하게');
    await sleep(520, tk);
    frame(byId('addBtn'));
    await sleep(680, tk);
    agentClick();
    press(byId('addBtn'), tk);
    await sleep(320, tk);
    sheet.classList.remove('on');
    ui.classList.remove('dim');
    addToCart('yuja', '따뜻하게');
    ev('act', '장바구니 · 유자차 1 · 5,500원');
    agent.classList.add('idle');
    agentState('듣는 중');
    frame('screen');
    await sleep(900, tk);

    look('americano', 560);
    await sleep(700, tk);
    gaze.classList.add('speaking');
    p = line('손님');
    word(p, '아,');
    await sleep(300, tk);
    word(p, '저거도', 'dx');
    tag('americano', '저거도', '2.45s');
    ev('bind', '“저거도” → 아메리카노 · 0.91');
    await sleep(440, tk);
    word(p, '똑같이');
    await sleep(340, tk);
    word(p, '하나');
    await sleep(420, tk);
    gaze.classList.remove('speaking');
    ev('intent', '“똑같이” → 따뜻하게 · 앞 주문 참조');
    agent.classList.remove('idle');
    agentState('누르는 중');
    frame('americano');
    await sleep(780, tk);
    agentClick();
    press(item('americano'), tk);
    addToCart('americano', '따뜻하게');
    ev('act', '장바구니 · 아메리카노 1 · 4,500원');
    await sleep(800, tk);

    // 06 손님 확인
    step('confirm');
    frame(byId('payBtn'));
    await sleep(720, tk);
    agentClick();
    press(byId('payBtn'), tk);
    await sleep(260, tk);
    ui.classList.add('dim');
    confirmEl.classList.add('on');
    await sleep(600, tk);
    ev('policy', '결제 → 자동 실행 차단 · 손님 확인 필요');
    agentState('손님 확인 대기', 'wait');
    frame(byId('confirmPay'));
    look(byId('confirmList'), 600);
    say('맞으면 <u>결제하기</u>를 직접 눌러 주세요.', byId('confirmPay'));
    p = line('키오');
    await speak(p, '유자차 한 잔, 아메리카노 한 잔. 모두 따뜻하게, 만 원입니다.', tk);
    await sleep(800, tk);
    look(byId('confirmPay'), 500);
    await sleep(1000, tk);
    userTap(byId('confirmPay'));
    press(byId('confirmPay'), tk);
    hush();
    ev('act', '손님 터치 · 결제 승인');
    await sleep(550, tk);
    confirmEl.classList.remove('on');
    ui.classList.remove('dim');
    cardStep.classList.add('on');
    agentState('안내 중');
    frame(byId('cardArrow'));
    look(byId('cardArrow'), 500);
    p = line('키오');
    await speak(p, '카드를 화면 아래 투입구에 넣어 주세요.', tk);
    await sleep(1700, tk);
    cardStep.classList.remove('on');
    done.classList.add('on');
    byId('doneTime').textContent = `말로 주문 · 터치 1번 · ${Math.round(clock / 1000)}초`;
    ev('system', '주문 완료 · 주문번호 37');
    gaze.classList.remove('on');
    agent.classList.add('idle');
    agentState('완료');
    frame('screen');
    step('end');
    await sleep(4500, tk);
  }

  /* ---------------- controls ---------------- */
  function syncControls() {
    const playing = running && !paused;
    playBtn.classList.toggle('is-playing', playing);
    playBtn.setAttribute('aria-pressed', String(playing));
    playBtn.querySelector('span').textContent = playing ? '일시정지' : '재생';
    screen.classList.toggle('paused', paused);
  }

  async function loop() {
    const tk = ++token;
    running = true;
    startGaze();
    paused = false;
    syncControls();
    try {
      for (;;) await run(tk);
    } catch (e) {
      if (!(e instanceof Cancel)) {
        console.error(e);
        running = false;
        syncControls();
      }
    }
  }

  playBtn.addEventListener('click', () => {
    if (!running) { loop(); return; }
    paused = !paused;
    syncControls();
  });
  replayBtn.addEventListener('click', loop);
  $$('[data-replay]').forEach((a) => a.addEventListener('click', () => loop()));

  let resizeRaf = 0;
  window.addEventListener('resize', () => {
    cancelAnimationFrame(resizeRaf);
    resizeRaf = requestAnimationFrame(() => {
      if (gazeTarget) look(gazeTarget, 0);
      frame(frameTarget);
      tags.forEach(placeTag);
    });
  });

  reset();
  syncControls();

  if (!reduceMotion) {
    const starter = new IntersectionObserver(([e]) => {
      if (e.isIntersecting && !running) { loop(); starter.disconnect(); }
    }, { threshold: 0.3 });
    starter.observe(screen);
  }
})();
