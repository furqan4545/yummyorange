/* YummyOrange website. No framework, no build step.
   Sections: helpers · springs · wheel geometry (ported from WheelGeometry.swift) · Wheel · data · playground ·
   explorer · Clothesline · editors · video · small bits. All operations on the page are simulated. */
(() => {
  'use strict';

  // ---------- Helpers ----------
  const cfg = window.DROPWHEEL || {};
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const SVGNS = 'http://www.w3.org/2000/svg';
  const svgEl = (tag, attrs = {}, parent) => {
    const e = document.createElementNS(SVGNS, tag);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  };
  const clamp = (x, a, b) => Math.min(Math.max(x, a), b);
  const TAU = Math.PI * 2;
  const mqReduce = matchMedia('(prefers-reduced-motion: reduce)');
  let RM = mqReduce.matches;
  mqReduce.addEventListener?.('change', (e) => { RM = e.matches; });
  const mqDark = matchMedia('(prefers-color-scheme: dark)');
  const coarse = matchMedia('(pointer: coarse)').matches;
  const capture = (el, id) => { try { el.setPointerCapture(id); } catch (_) { /* a pointer that is already gone */ } };
  const announce = (el, text) => { el.textContent = ''; requestAnimationFrame(() => { el.textContent = text; }); };

  // Release details from config.js (the one place to change them)
  $$('[data-config-text]').forEach((e) => { const v = cfg[e.dataset.configText]; if (v) e.textContent = v; });
  $$('[data-if-config]').forEach((e) => { e.hidden = !cfg[e.dataset.ifConfig]; });
  $$('[data-unless-config]').forEach((e) => { e.hidden = !!cfg[e.dataset.unlessConfig]; });
  $$('[data-config-mailto]').forEach((a) => { const v = cfg[a.dataset.configMailto]; if (v) { a.href = `mailto:${v}`; a.hidden = false; } });

  // Download buttons. Until config.js names a DMG they read "Coming soon" and link nowhere (CSS keys off the
  // data-release attribute config.js sets). On a phone or tablet a disk image is no use, so the button shares the
  // page's link instead, to open later on the Mac.
  const handheld = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1);
  $$('[data-download]').forEach((a) => {
    if (!cfg.dmgURL) { a.removeAttribute('href'); a.setAttribute('aria-disabled', 'true'); return; }
    a.href = cfg.dmgURL;
    if (!handheld) return;
    const label = a.querySelector('.dl-ready');
    const text = a.classList.contains('btn-small') ? 'Share link' : 'Send the link to your Mac';
    label.textContent = text;
    a.addEventListener('click', async (e) => {
      e.preventDefault();
      const url = location.href.split('#')[0];
      try {
        if (navigator.share) { await navigator.share({ title: 'YummyOrange', text: 'YummyOrange, a file wheel for the Mac', url }); return; }
      } catch (err) { if (err && err.name === 'AbortError') return; }
      try {
        await navigator.clipboard.writeText(url);
        label.textContent = 'Link copied';
        setTimeout(() => { label.textContent = text; }, 2000);
      } catch (_) { location.href = cfg.dmgURL; }
    });
  });

  // Smooth scrolling only for clicks on in-page links: a deep link (/#faq) lands at once instead of gliding 9,000 px.
  addEventListener('load', () => requestAnimationFrame(() => document.documentElement.classList.add('smooth-scroll')));
  // A link to a question opens it.
  const openDetails = (id) => { const t = id && document.getElementById(id); if (t && t.tagName === 'DETAILS') t.open = true; };
  document.addEventListener('click', (e) => { const a = e.target.closest('a[href^="#"]'); if (a) openDetails(a.getAttribute('href').slice(1)); });
  openDetails(decodeURIComponent(location.hash.slice(1)));

  // Top bar hairline once the page scrolls
  const topbar = $('.topbar');
  const onScroll = () => topbar.classList.toggle('scrolled', scrollY > 8);
  addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  // ---------- Frame loop and springs ----------
  // One requestAnimationFrame loop; tasks return false when they are done, and the loop stops when none are left.
  const loop = {
    tasks: new Set(), raf: 0, last: 0,
    add(fn) {
      this.tasks.add(fn);
      if (!this.raf) { this.last = performance.now(); this.raf = requestAnimationFrame(this.tick); }
    },
    tick: (now) => {
      const dt = Math.min((now - loop.last) / 1000, 1 / 20);
      loop.last = now;
      for (const fn of [...loop.tasks]) if (fn(dt) === false) loop.tasks.delete(fn);
      loop.raf = loop.tasks.size ? requestAnimationFrame(loop.tick) : 0;
    },
  };

  // Apple's two designer-friendly parameters: response (seconds) and damping ratio (1 = no overshoot).
  // Always continues from the current value and velocity, so every animation is interruptible.
  class Spring {
    constructor(x = 0, { response = 0.3, damping = 1, eps = 0.001 } = {}) {
      this.x = x; this.v = 0; this.target = x; this.response = response; this.damping = damping; this.eps = eps;
    }
    set(target, velocity) { this.target = target; if (velocity !== undefined) this.v = velocity; }
    snap(x) { this.x = this.target = x; this.v = 0; }
    step(dt) {
      const w = TAU / this.response, k = w * w, c = 2 * this.damping * w;
      let t = dt;
      while (t > 1e-6) {
        const h = Math.min(t, 1 / 240);
        this.v += (-k * (this.x - this.target) - c * this.v) * h;
        this.x += this.v * h;
        t -= h;
      }
      if (this.done) { this.x = this.target; this.v = 0; }
    }
    get done() { return Math.abs(this.x - this.target) < this.eps && Math.abs(this.v) < this.eps * 10; }
  }

  // Pointer velocity from a short history (px/s)
  const velocityOf = (hist) => {
    if (hist.length < 2) return { vx: 0, vy: 0 };
    const a = hist[0], b = hist[hist.length - 1], dt = (b.t - a.t) / 1000;
    if (dt <= 0) return { vx: 0, vy: 0 };
    return { vx: (b.x - a.x) / dt, vy: (b.y - a.y) / dt };
  };
  const pushHist = (hist, x, y) => {
    const t = performance.now();
    hist.push({ x, y, t });
    while (hist.length > 2 && t - hist[0].t > 80) hist.shift();
  };

  // ---------- Petal sound and haptics ----------
  // The app ticks each time the highlighted petal changes (ThemeSound.swift › PetalFeedback). The page plays the same
  // Pop, made here sample for sample from the app's recipe, when the pointer moves onto a key cap and when the
  // highlight moves to a new petal, at the app's level (peak −19.6 dBFS) and with its sweep rule: faster sweeps run
  // up to 1.3× higher and a fifth quieter. Only on those events and on the same frame as the highlight (apple-motion
  // §13); never on load, on scroll, while the tab is hidden, or twice for one entry; at most one tick per 35 ms, so a
  // fast sweep trills instead of machine-gunning. Browsers allow sound only after a gesture, so the one AudioContext
  // is made on the first press or key press anywhere; until then hovering is silent. The Sound buttons beside the keys
  // turn it on and off (kept in localStorage when the browser allows). Haptics only where navigator.vibrate exists
  // (Android), only for a finger on a key cap or a petal, never for a hover. Reduce Motion leaves the sound on: it is
  // feedback, not motion (apple-motion §14), and the Sound button is the way to turn it off.
  const feedback = (() => {
    const KEY = 'yummyorange.sound';
    const RATE = 48000;    // the app's synthesis rate; the browser resamples to the device
    const GAP = 0.035;     // s, the closest two ticks may start
    const LATE = 150;      // ms; a tick that would start later than this is dropped (PetalSound.maximumDelay)
    const IDLE = 4000;     // ms of quiet before the audio device is let go (PetalSound.idleStop)
    const CROSSED = 3;     // most ticks for one move across several petals: 35 ms apart, inside the app's 100 ms spread
    let on = true;
    try { on = localStorage.getItem(KEY) !== 'off'; } catch (_) { /* storage blocked: on, for this visit */ }
    let ctx = null, out = null, pop = null, lastAt = 0, lastChange = 0, idleTimer = 0, lastActive = 0, lastBuzz = 0;
    let faded = false, hushId = 0, waking = null;
    const live = new Set(); // ticks playing or waiting to start
    const toggles = [];
    const zones = [$('#scene'), $('.explorer')].filter(Boolean);
    const wanted = () => on && document.visibilityState === 'visible';

    // PetalSound.samples(.pop): a sine falling from 1.9 to 0.9 kHz with a breath of tilted noise at its start, a 2 ms
    // end fade, peak 0.14 × 0.75. The noise uses the app's generator (a 64-bit LCG, hence BigInt), so it matches.
    function popSamples() {
      const n = Math.floor(0.04 * RATE), out = new Float64Array(n);
      let phase = 0;
      for (let i = 0; i < n; i++) {
        const t = i / RATE;
        phase += (2 * Math.PI * (900 + 1000 * Math.exp(-t / 0.004))) / RATE;
        out[i] = (t < 0.001 ? t / 0.001 : 1) * Math.exp(-t / 0.008) * Math.sin(phase);
      }
      // (BigInt() calls, not 123n literals: an older browser without BigInt still parses the page, and gets plain noise.)
      let white = () => Math.random() * 2 - 1;
      if (typeof BigInt === 'function') {
        const A = BigInt('6364136223846793005'), C = BigInt('1442695040888963407'), M = BigInt('0xFFFFFFFFFFFFFFFF'), S11 = BigInt(11);
        let seed = BigInt('0x5EEDD1A1');
        white = () => { seed = (seed * A + C) & M; return (Number(seed >> S11) / 2 ** 53) * 2 - 1; };
      }
      let prev = white();
      const burst = 0.0005, len = Math.min(n, Math.floor(burst * 7 * RATE));
      for (let i = 0; i < len; i++) {
        const t = i / RATE, w = white(), d = (w - prev) * 0.7;
        prev = w;
        const ramp = t < burst ? Math.sin(((Math.PI / 2) * t) / burst) ** 2 : 1;
        out[i] += 0.2 * d * Math.exp(-t / burst) * ramp;
      }
      const fade = Math.floor(0.002 * RATE);
      for (let i = 0; i < Math.min(fade, n); i++) out[n - 1 - i] *= i / fade;
      let top = 0;
      for (let i = 0; i < n; i++) top = Math.max(top, Math.abs(out[i]));
      const level = Math.fround(0.14) * 0.75;
      return Float32Array.from(out, (v) => (v / (top || 1)) * level);
    }

    // What the pointer really did. When the page scrolls under a still pointer, browsers send hover events at the
    // same spot; a tick needs the pointer itself to have moved (or pressed), and a moment's calm after any scroll.
    // (`kind` says whether the last pointer event was a move, a press or a lift: only a move can cross petals.)
    const ptr = { x: NaN, y: NaN, type: '', moved: false, kind: '' };
    let input = '', scrolledAt = -1e9;
    const opts = { capture: true, passive: true };
    addEventListener('pointermove', (e) => {
      ptr.moved = e.clientX !== ptr.x || e.clientY !== ptr.y;
      ptr.x = e.clientX; ptr.y = e.clientY; ptr.type = e.pointerType; ptr.kind = 'move'; input = 'pointer';
    }, opts);
    const pressed = (kind) => (e) => { ptr.x = e.clientX; ptr.y = e.clientY; ptr.type = e.pointerType; ptr.moved = true; ptr.kind = kind; input = 'pointer'; };
    addEventListener('pointerdown', pressed('down'), opts);
    addEventListener('pointerup', pressed('up'), opts);
    addEventListener('keydown', () => { input = 'key'; }, opts);
    addEventListener('scroll', () => { scrolledAt = performance.now(); }, opts);
    addEventListener('wheel', () => { scrolledAt = performance.now(); }, opts);
    const calm = () => performance.now() - scrolledAt > 120;

    // The context is made inside a gesture only, so the browser lets it start. Ambient: the page's ticks mix with
    // other audio and follow the silent switch (playing-audio.md › Ambient), where the browser offers the choice.
    function unlock() {
      if (!wanted()) return false;
      if (!ctx) {
        if (navigator.userActivation && !navigator.userActivation.isActive) return false;
        const AC = window.AudioContext || window.webkitAudioContext;
        if (!AC) return false;
        try { if (navigator.audioSession) navigator.audioSession.type = 'ambient'; } catch (_) { /* not offered */ }
        try { ctx = new AC({ latencyHint: 'interactive' }); } catch (_) { return false; }
        out = ctx.createGain(); // every tick goes through here, so a stop can fade instead of cutting
        out.connect(ctx.destination);
        const s = popSamples();
        pop = ctx.createBuffer(1, s.length, RATE);
        pop.getChannelData(0).set(s);
        // However the context comes to run (a resume that lands after Sound was turned off or the tab was hidden, or
        // the system ending an interruption), it stays running only while it is wanted, and then only until idle.
        // A tick still queued when it stops running would play, stale, on the next resume: it goes.
        ctx.onstatechange = () => {
          if (ctx.state === 'running') { if (wanted()) idle(); else hush(); return; }
          live.forEach((s) => { try { s.stop(); } catch (_) { /* already stopped */ } });
          lastAt = 0;
        };
      }
      if (ctx.state !== 'running') wake().catch(() => {});
      idle();
      return true;
    }
    // One resume at a time, however many moves and ticks ask for it while the device wakes.
    function wake() { return waking || (waking = ctx.resume().finally(() => { waking = null; })); }
    // (Not for the Sound button itself: turning sound off shouldn't wake the audio device, and turning it on unlocks.)
    ['pointerdown', 'pointerup', 'touchend', 'keydown', 'click'].forEach((t) => addEventListener(t, (e) => {
      if (!on || (e.target && e.target.closest && e.target.closest('[data-sound-toggle]'))) return;
      if (!ctx || (ctx.state !== 'running' && zones.some((z) => z.contains(e.target)))) unlock();
    }, opts));

    // The audio device is let go after IDLE of quiet (no tick, and no pointer moving over a demo), and at once when
    // the tab is hidden or Sound is turned off. A mouse moving over a demo warms it again: that takes a few ms, so
    // the next tick is still on time.
    function idle() {
      lastActive = performance.now();
      if (!idleTimer) idleTimer = setTimeout(idleCheck, IDLE);
    }
    function idleCheck() {
      idleTimer = 0;
      if (!ctx || ctx.state !== 'running') return; // suspended or interrupted: onstatechange re-arms on running
      const left = IDLE - (performance.now() - lastActive);
      if (left > 0) idleTimer = setTimeout(idleCheck, left);
      else hush();
    }
    zones.forEach((z) => {
      const warm = (e) => {
        if (!ctx || e.pointerType === 'touch') return; // a finger's press unlocks; its moves are mostly scrolls
        lastActive = performance.now();
        if (ctx.state === 'running') { if (!idleTimer) idle(); } else if (ctx.state !== 'closed' && wanted()) wake().catch(() => {});
      };
      z.addEventListener('pointerenter', warm, { passive: true });
      z.addEventListener('pointermove', warm, { passive: true });
    });
    document.addEventListener('visibilitychange', () => { if (document.visibilityState !== 'visible') hush(); });

    // Stops every tick that is playing or waiting (a suspended context keeps them, and would play them, stale, on its
    // next resume), fading one that is sounding over 5 ms so it doesn't click, then lets the audio device go.
    function hush() {
      clearTimeout(idleTimer);
      idleTimer = 0;
      lastAt = 0;
      if (!ctx || ctx.state === 'closed') return;
      const sounding = ctx.state === 'running' && live.size > 0, t = ctx.currentTime, end = sounding ? t + 0.005 : 0;
      if (sounding) {
        out.gain.cancelScheduledValues(t);
        out.gain.setValueAtTime(out.gain.value, t);
        out.gain.linearRampToValueAtTime(0, end);
        faded = true;
      }
      live.forEach((s) => { try { s.stop(end); } catch (_) { /* already stopped */ } });
      const id = ++hushId, letGo = () => { if (id === hushId && ctx.state !== 'closed') ctx.suspend().catch(() => {}); };
      if (sounding) setTimeout(letGo, 25); else letGo();
    }

    function start(rate, volume, force, count = 1) {
      const now = ctx.currentTime;
      if (!force && lastAt > now) return false; // one is already waiting: drop this one
      hushId++; // a pending hush's suspend no longer applies
      if (faded) { out.gain.cancelScheduledValues(now); out.gain.setValueAtTime(1, now); faded = false; }
      let at = Math.max(now, lastAt + GAP);
      for (let k = 0; k < count; k++, at += GAP) {
        const src = ctx.createBufferSource();
        src.buffer = pop;
        src.playbackRate.value = rate;
        let node = src;
        if (volume !== 1) { node = ctx.createGain(); node.gain.value = volume; src.connect(node); }
        node.connect(out);
        live.add(src);
        src.onended = () => { live.delete(src); src.disconnect(); if (node !== src) node.disconnect(); };
        src.start(at);
        lastAt = at;
      }
      idle();
      return true;
    }
    function play(rate = 1, volume = 1, force = false, count = 1) {
      if (!ctx || !wanted()) return false;
      if (ctx.state === 'running') return start(rate, volume, force, count);
      const asked = performance.now();
      wake().then(() => {
        // Sound may have been turned off, or the tab hidden, while the device woke; and a late tick reads as noise.
        if (wanted() && ctx.state === 'running' && (force || performance.now() - asked <= LATE)) start(rate, volume, force, count);
      }, () => {});
      return true;
    }
    // A finger only (never a hover), after the page has been tapped once, at most every 50 ms.
    function buzz() {
      const t = performance.now();
      if (!on || !navigator.vibrate || !navigator.userActivation || !navigator.userActivation.hasBeenActive || t - lastBuzz < 50) return;
      lastBuzz = t;
      try { navigator.vibrate(10); } catch (_) { /* not allowed here */ }
    }

    // `sample`: play one tick to hear what was turned on (not when another tab made the change).
    function set(value, sample) {
      on = value;
      toggles.forEach((b) => b.setAttribute('aria-pressed', String(on)));
      if (!on) { hush(); return; }
      if (sample && unlock()) play(1, 1, true);
    }
    $$('[data-sound-toggle]').forEach((b) => {
      toggles.push(b);
      b.setAttribute('aria-pressed', String(on));
      b.addEventListener('click', () => {
        set(!on, true);
        try { localStorage.setItem(KEY, on ? 'on' : 'off'); } catch (_) { /* not kept: the choice lasts this visit */ }
      });
    });
    addEventListener('storage', (e) => { if (e.key === KEY) set(e.newValue !== 'off', false); });

    // Key caps: a tick when the pointer moves onto one; a finger gets its tick (and a tap) when the tap lands, so a
    // touch that turns into a scroll stays silent.
    $$('.keybtn').forEach((b) => {
      let type = '';
      b.addEventListener('pointerenter', (e) => {
        if (e.pointerType === 'touch' || !calm() || (e.clientX === ptr.x && e.clientY === ptr.y)) return;
        play();
      });
      b.addEventListener('pointerdown', (e) => { type = e.pointerType; });
      b.addEventListener('click', (e) => {
        if (type === 'touch' && e.detail !== 0) { play(); buzz(); }
        type = '';
      });
    });

    return {
      // The highlight moved by `steps` petals. As in PetalSound.plan: 5 petals/s or slower plays as made; the rate
      // rises smoothly to 1.3× at 20/s, and the level eases off by up to a fifth.
      // A move that crossed petals ticks for each, as the app does (up to three here, so they keep the 35 ms gap and
      // stay inside the app's 100 ms spread); a tap, a click or a key that jumps plays one, as nothing was crossed.
      petal(steps = 1) {
        if (input === 'pointer' && (!ptr.moved || !calm())) return;
        const t = performance.now(), interval = lastChange ? (t - lastChange) / 1000 : 1, n = Math.max(1, steps);
        lastChange = t;
        const x = clamp((n / Math.max(interval, 1e-3) - 5) / 15, 0, 1), eased = x * x * (3 - 2 * x);
        play(1 + 0.3 * eased, 1 - 0.2 * eased, false, input === 'pointer' && ptr.kind === 'move' ? Math.min(n, CROSSED) : 1);
        if (input === 'pointer' && ptr.type === 'touch') buzz();
      },
    };
  })();

  // ---------- Wheel geometry (WheelGeometry.swift, in points) ----------
  const WM = { inner: 48.64, outer: 119.52, gap: 5, bdInner: 42.24, bdOuter: 125.92, intro: 50.4,
    labelBase: 40, labelFrac: 0.56, cornerEdge: 20.16, capW: 70, capH: 36, single: 8, secondW: 66 };
  WM.secondInner = WM.outer + WM.gap;
  WM.secondOuter = WM.secondInner + WM.secondW;
  WM.labelR = WM.labelBase + (WM.outer - WM.labelBase) * WM.labelFrac;
  const innerCount = (n) => {
    if (n <= WM.single) return n;
    const im = (WM.inner + WM.outer) / 2, om = (WM.secondInner + WM.secondOuter) / 2;
    return clamp(Math.round((n * im) / (im + om)), 3, n - 3);
  };
  const backdropOuter = (n) => (n > WM.single ? WM.secondOuter + (WM.bdOuter - WM.outer) : WM.bdOuter);
  const R_TWO_RINGS = backdropOuter(16) + 10;

  function wheelLayout(n) {
    const k = innerCount(n), rings = [];
    if (k > 0) rings.push({ first: 0, count: k, inner: WM.inner, outer: WM.outer });
    if (n > k) rings.push({ first: k, count: n - k, inner: WM.secondInner, outer: WM.secondOuter });
    rings.forEach((r) => { r.sector = TAU / r.count; });
    const ringOf = (i) => (rings[1] && i >= rings[1].first ? rings[1] : rings[0]);
    // Petal 0 at 12 o'clock (9 o'clock for a lone ring of three), the rest clockwise.
    const base = (r) => (r.count === 3 && rings.length === 1 ? Math.PI : Math.PI / 2);
    const centerAngle = (i) => { const r = ringOf(i); return base(r) - (i - r.first) * r.sector; };
    return { n, rings, ringOf, base, centerAngle, bdOuter: backdropOuter(n) };
  }

  const f2 = (v) => Math.round(v * 100) / 100;
  // One petal: an annular sector with a constant-width gap on each side, quadratic corners whose control point
  // sits on the sharp corner, and arcs along the inner and outer edge. y points down.
  function petalPath(ca, sector, gap, ri, ro, ce) {
    const start = ca - sector / 2, end = ca + sector / 2, hg = Math.max(gap / 2, 0);
    const half = (r) => Math.asin(Math.min(hg / Math.max(hg + 0.01, r), 0.95));
    const P = (r, a) => `${f2(r * Math.cos(a))} ${f2(-r * Math.sin(a))}`;
    const iS = start + half(ri), iE = end - half(ri);
    const ac = Math.min((iE - iS) * 0.18, 0.18);
    const rC = ri / Math.max(Math.cos(ac), 0.01);
    const rA = ri * Math.tan(ac) + rC;
    const rB = Math.max(ro - ce, 0);
    const oS = start + half(ro), oE = end - half(ro);
    const oc = Math.min((oE - oS) * 0.24, 0.15);
    const bigO = oE - oc - (oS + oc) > Math.PI ? 1 : 0;
    const bigI = iE - ac - (iS + ac) > Math.PI ? 1 : 0;
    return `M${P(rA, start + half(rA))}L${P(rB, start + half(rB))}Q${P(ro, oS)} ${P(ro, oS + oc)}` +
      `A${f2(ro)} ${f2(ro)} 0 ${bigO} 0 ${P(ro, oE - oc)}Q${P(ro, oE)} ${P(rB, end - half(rB))}` +
      `L${P(rA, end - half(rA))}Q${P(rC, end - half(rC))} ${P(ri, iE - ac)}` +
      `A${f2(ri)} ${f2(ri)} 0 ${bigI} 1 ${P(ri, iS + ac)}Q${P(rC, start + half(rC))} ${P(rA, start + half(rA))}Z`;
  }
  const annulusPath = (ri, ro) =>
    `M${f2(ro)} 0A${f2(ro)} ${f2(ro)} 0 1 0 ${f2(-ro)} 0A${f2(ro)} ${f2(ro)} 0 1 0 ${f2(ro)} 0Z` +
    (ri > 0.5 ? `M${f2(ri)} 0A${f2(ri)} ${f2(ri)} 0 1 1 ${f2(-ri)} 0A${f2(ri)} ${f2(ri)} 0 1 1 ${f2(ri)} 0Z` : '');

  // ---------- Wheel ----------
  const measureText = (() => {
    const ctx = document.createElement('canvas').getContext('2d');
    let font = '';
    return (text, px) => {
      if (!font) font = getComputedStyle(document.documentElement).getPropertyValue('--font').trim() || 'system-ui, sans-serif';
      ctx.font = `500 ${px}px ${font}`;
      return ctx.measureText(text).width;
    };
  })();
  const HYPHEN = {
    Background: ['Back-', 'ground'], Metadata: ['Meta-', 'data'], Password: ['Pass-', 'word'], Normalize: ['Normal-', 'ize'],
    Snapshot: ['Snap-', 'shot'], Channels: ['Chan-', 'nels'], Annotate: ['Anno-', 'tate'], Compress: ['Com-', 'press'],
    Organize: ['Organ-', 'ize'], Visualize: ['Visual-', 'ize'], Terminal: ['Termi-', 'nal'], Extract: ['Ex-', 'tract'],
  };
  // A live SVG wheel. Items: { label, title, icon?, kind: 'format' | 'name', id }.
  let wheelCount = 0;
  class Wheel {
    constructor(host, { role = 'menu', minLabelPx = 11, onHighlight, onPick, onClose } = {}) {
      this.uid = `w${++wheelCount}`;
      this.host = host;
      this.el = document.createElement('div');
      this.el.className = 'wheel';
      this.el.setAttribute('role', role);
      this.el.tabIndex = -1;
      this.role = role;
      host.appendChild(this.el);
      this.bloom = new Spring(0, { response: 0.3, damping: 1 });
      this.minLabelPx = minLabelPx;
      this.scale = 1;
      this.items = [];
      this.hl = -1;
      this.isOpen = false;
      this.onHighlight = onHighlight; this.onPick = onPick; this.onClose = onClose;
      this.task = (dt) => {
        this.bloom.step(dt);
        this.render();
        if (this.bloom.done) {
          if (this.bloom.target === 0) { this.el.hidden = true; this.el.classList.remove('open'); }
          return false;
        }
      };
    }

    setItems(items, { title = '', label = '' } = {}) {
      this.items = items;
      this.title = title;
      this.el.setAttribute('aria-label', label);
      this.hl = -1;
      this.build();
      this.render();
    }

    setScale(s) {
      if (Math.abs(s - this.scale) < 0.01 && this.svg) return;
      this.scale = s;
      if (this.items.length) { this.build(); this.render(); }
      this.size();
    }

    size() {
      const d = 2 * this.R * this.scale;
      this.el.style.width = `${d}px`;
      this.el.style.height = `${d}px`;
    }

    place(cx, cy) {
      this.cx = cx; this.cy = cy;
      const r = this.R * this.scale;
      this.el.style.transform = `translate(${cx - r}px, ${cy - r}px)`;
    }

    build() {
      const n = this.items.length;
      const L = (this.L = wheelLayout(n));
      const R = (this.R = L.bdOuter + 10);
      const id = this.uid;
      this.el.textContent = '';
      const svg = (this.svg = svgEl('svg', { class: 'wheel-svg', viewBox: `${-R} ${-R} ${2 * R} ${2 * R}`, 'aria-hidden': 'true' }));
      const defs = svgEl('defs', {}, svg);
      L.rings.forEach((r, k) => {
        const g = svgEl('radialGradient', { id: `${id}-f${k}`, gradientUnits: 'userSpaceOnUse', cx: 0, cy: 0, r: r.outer }, defs);
        svgEl('stop', { offset: (r.inner / r.outer).toFixed(3), class: 'stop-in' }, g);
        svgEl('stop', { offset: 1, class: 'stop-out' }, g);
        const h = svgEl('radialGradient', { id: `${id}-h${k}`, gradientUnits: 'userSpaceOnUse', cx: 0, cy: 0, r: r.outer }, defs);
        const at = (x) => (r.inner / r.outer + (1 - r.inner / r.outer) * x).toFixed(3);
        // The app's highlight: accentHighlight @0.98 at 0.2, accent @0.96 at 0.56, accentDeep @0.94 at 1.0
        svgEl('stop', { offset: at(0.2), 'stop-color': '#EEA6D7', 'stop-opacity': 0.98 }, h);
        svgEl('stop', { offset: at(0.56), 'stop-color': '#E266BA', 'stop-opacity': 0.96 }, h);
        svgEl('stop', { offset: at(1), 'stop-color': '#A74086', 'stop-opacity': 0.94 }, h);
      });
      const sh = svgEl('filter', { id: `${id}-sh`, x: '-30%', y: '-30%', width: '160%', height: '160%' }, defs);
      svgEl('feDropShadow', { dx: 0, dy: 5, stdDeviation: 9, 'flood-color': '#20161B', 'flood-opacity': 0.2 }, sh);
      const csh = svgEl('filter', { id: `${id}-csh`, x: '-40%', y: '-60%', width: '180%', height: '220%' }, defs);
      svgEl('feDropShadow', { dx: 0, dy: 1, stdDeviation: 2, 'flood-color': '#000', 'flood-opacity': 0.14 }, csh);

      this.ringPath = svgEl('path', { class: 'w-ring', 'fill-rule': 'evenodd', filter: `url(#${id}-sh)` }, svg);
      this.ringEdge = svgEl('circle', { class: 'w-ring-edge', r: L.bdOuter - 0.5 }, svg);
      this.hole = svgEl('circle', { class: 'w-hole', r: WM.bdInner }, svg);
      const petals = svgEl('g', {}, svg);
      this.petals = this.items.map((_, i) => {
        const k = L.rings.indexOf(L.ringOf(i));
        return svgEl('path', { class: 'w-petal', fill: `url(#${id}-f${k})`, 'fill-rule': 'evenodd', 'data-ring': k }, petals);
      });
      this.labelsG = svgEl('g', {}, svg);
      this.labels = this.fitLabels();
      this.capG = svgEl('g', { class: 'w-capsule' }, svg);
      this.capRect = svgEl('rect', { class: 'w-cap', x: -WM.capW / 2, y: -WM.capH / 2, width: WM.capW, height: WM.capH, rx: WM.capH / 2, filter: `url(#${id}-csh)` }, this.capG);
      this.capText = svgEl('text', { class: 'w-cap-text', 'text-anchor': 'middle' }, this.capG);
      svgEl('circle', { class: 'wheel-focus-ring', r: L.bdOuter + 4 }, svg);
      this.el.appendChild(svg);

      // Accessible items (the SVG is decorative to assistive technology)
      const list = document.createElement('div');
      list.className = 'visually-hidden';
      this.itemEls = this.items.map((item, i) => {
        const d = document.createElement('div');
        d.id = `${id}-i${i}`;
        d.setAttribute('role', this.role === 'menu' ? 'menuitem' : 'option');
        if (this.role !== 'menu') d.setAttribute('aria-selected', 'false');
        d.textContent = item.title;
        list.appendChild(d);
        return d;
      });
      this.el.appendChild(list);
      this.setCapsule(this.title);
      this.size();
    }

    // Labels are 11 px or more on screen. On a small wheel a long name can be wider than its petal (the side petals
    // of the outer ring are only as wide as the ring is deep), so each wheel tries, in order: the app's capitals;
    // upper and lower case without tracking (narrower); the same with just the labels that still don't fit broken
    // into words and at hyphen points; the same without the petal icons. Each try is measured with the page's font
    // against the petal's real shape. Only if none fits (a 320 px phone) are the names made smaller, all alike, and
    // never under 10 px.
    labelLayout(item, i, st, fs) {
      const L = this.L, r = L.ringOf(i), a = L.centerAngle(i);
      const rad = r === L.rings[0] ? WM.labelR : (r.inner + r.outer) / 2;
      const n1 = L.n === 1;
      const x = n1 ? 0 : rad * Math.cos(a), y = n1 ? -(WM.inner + WM.outer) / 2 : -rad * Math.sin(a);
      const icon = item.icon && !st.noIcon;
      const lh = fs * 1.16, is = icon ? fs * 1.45 : 0, gapI = icon ? fs * 0.35 : 0;
      const track = st.upper ? 0.05 * fs : 0;
      const tryLines = (lines) => {
        if (st.upper) lines = lines.map((ln) => ln.toUpperCase());
        const top = -(is + gapI + lines.length * lh) / 2;
        // Each row's ink: capitals from the baseline up 0.72 em (plus descenders in lower case); the icon's stroke.
        const rows = lines.map((ln, k) => {
          const b = top + is + gapI + lh * k + fs * 0.86;
          return { w: measureText(ln, fs) + track * Math.max(ln.length - 1, 0), y0: b - fs * 0.72, y1: b + (st.upper ? 0 : fs * 0.2) };
        });
        if (icon) rows.unshift({ w: is * 0.8, y0: top + is * 0.1, y1: top + is * 0.9 });
        const fits = n1 || rows.every((row) => [row.y0, row.y1].every((dy) => this.room(i, x, y + dy) >= row.w + 2));
        return { x, y, lines, fs, lh, is, gapI, top, fits, icon };
      };
      const plainLines = String(item.label).split('\n');
      let lay = tryLines(plainLines);
      // Only a label that doesn't fit is broken further: a long line into its words, a long word at its hyphen point.
      if (!lay.fits && st.hyph && item.kind !== 'format') {
        const broken = plainLines.flatMap((ln) => (ln.includes(' ') && ln.length > 7 ? ln.split(' ') : [ln]))
          .flatMap((w) => (HYPHEN[w] && !w.includes(' ') ? HYPHEN[w] : [w]));
        lay = tryLines(broken);
      }
      return lay;
    }

    // Horizontal room (twice the nearer side) inside petal i on the row through (x, y), in wheel units.
    room(i, x, y) {
      const L = this.L, r = L.ringOf(i), ca = L.centerAngle(i);
      const inside = (px) => {
        const d = Math.hypot(px, y);
        if (d < r.inner + 2 || d > r.outer - 2) return false;
        if (r.count === 1) return true;
        const diff = Math.abs((((Math.atan2(-y, px) - ca) % TAU) + TAU + Math.PI) % TAU - Math.PI);
        return diff <= r.sector / 2 - (WM.gap / 2 + 1.5) / d;
      };
      if (!inside(x)) return 0;
      let left = 0, right = 0;
      while (left < 260 && inside(x - left - 1)) left += 1;
      while (right < 260 && inside(x + right + 1)) right += 1;
      return 2 * Math.min(left, right);
    }

    fitLabels() {
      const base = (item) => Math.max(item.kind === 'format' ? 10.5 : 8.25, this.minLabelPx / this.scale);
      const tries = [{ upper: true }, { upper: false }, { upper: false, hyph: true }, { upper: false, hyph: true, noIcon: true }];
      let pick = null;
      for (const st of tries) {
        const lay = this.items.map((item, i) => this.labelLayout(item, i, st, base(item)));
        if (lay.every((l) => l.fits)) { pick = { st, lay }; break; }
      }
      if (!pick) {
        const st = tries[3], floor = 10 / this.scale;
        let k = 1, lay;
        do {
          lay = this.items.map((item, i) => this.labelLayout(item, i, st, Math.max(base(item) * k, item.kind === 'format' ? 0 : floor)));
          k -= 0.04;
        } while (!lay.every((l) => l.fits) && base(this.items[0]) * k > floor);
        pick = { st, lay };
      }
      this.labelStyle = pick.st;
      return pick.lay.map((l, i) => {
        const item = this.items[i];
        const g = svgEl('g', { class: `w-label${pick.st.upper ? '' : ' plain'}`, transform: `translate(${f2(l.x)} ${f2(l.y)})` }, this.labelsG);
        let top = l.top;
        if (l.icon) {
          svgEl('use', { href: `#i-${item.icon}`, x: f2(-l.is / 2), y: f2(top), width: f2(l.is), height: f2(l.is) }, g);
          top += l.is + l.gapI;
        }
        const t = svgEl('text', { 'text-anchor': 'middle', 'font-size': f2(l.fs) }, g);
        l.lines.forEach((ln, k) => {
          const sp = svgEl('tspan', { x: 0, y: f2(top + l.lh * k + l.fs * 0.86) }, t);
          sp.textContent = ln;
        });
        return g;
      });
    }

    // The centre capsule names the wheel, or the highlighted petal. Never below 10 px on screen: it widens up to the
    // hole's size, and a name still too long in capitals is set in upper and lower case, which is narrower.
    setCapsule(text) {
      const words = String(text || '').split(' ');
      const lines = [];
      words.forEach((w) => {
        const last = lines[lines.length - 1];
        if (last && (last + ' ' + w).length <= 10) lines[lines.length - 1] = last + ' ' + w; else lines.push(w);
      });
      const show = lines.slice(0, 2);
      const fs = Math.max(show.length > 1 ? 7.6 : 8.6, 10 / this.scale);
      const longest = Math.max(1, ...show.map((l) => l.length));
      const room = 2 * WM.bdInner - 8;
      let width = longest * fs * 0.7 + fs * 1.3;
      const plain = width > room;
      if (plain) width = longest * fs * 0.56 + fs * 1.1;
      const w = clamp(width, WM.capW, room), h = Math.max(WM.capH, show.length * fs * 1.12 + fs * 1.15);
      this.capRect.setAttribute('x', f2(-w / 2)); this.capRect.setAttribute('width', f2(w));
      this.capRect.setAttribute('y', f2(-h / 2)); this.capRect.setAttribute('height', f2(h));
      this.capRect.setAttribute('rx', f2(Math.min(h, WM.capH) / 2));
      this.capText.classList.toggle('plain', plain);
      this.capText.textContent = '';
      this.capText.setAttribute('font-size', f2(fs));
      show.forEach((ln, k) => {
        const sp = svgEl('tspan', { x: 0, y: f2((k - (show.length - 1) / 2) * fs * 1.12 + fs * 0.36) }, this.capText);
        sp.textContent = ln;
      });
    }

    render() {
      if (!this.svg) return;
      const t = clamp(this.bloom.x, 0, 1.15), L = this.L;
      this.ringPath.setAttribute('d', annulusPath(WM.bdInner * t, WM.intro + (L.bdOuter - WM.intro) * t));
      this.ringEdge.setAttribute('r', f2(Math.max(WM.intro + (L.bdOuter - WM.intro) * t - 0.5, 0)));
      this.hole.setAttribute('r', f2(WM.bdInner * t));
      this.petals.forEach((p, i) => {
        const r = L.ringOf(i), ro = WM.intro + (r.outer - WM.intro) * t, ri = r.inner * t;
        p.setAttribute('d', L.n === 1 ? annulusPath(ri, ro) : petalPath(L.centerAngle(i), r.sector, WM.gap * t, ri, ro, WM.cornerEdge));
      });
      const lo = clamp((t - 0.5) * 2, 0, 1);
      this.labelsG.style.opacity = lo;
      this.capG.style.opacity = clamp(t * 1.6, 0, 1);
      this.el.style.opacity = clamp(t * 4, 0, 1);
    }

    open({ animate = true } = {}) {
      this.el.hidden = false;
      this.el.classList.add('open');
      this.isOpen = true;
      if (!animate || RM) { this.bloom.snap(1); this.render(); return; }
      // The app starts the bloom with a small push so it is quick off the mark.
      this.bloom.set(1, this.bloom.x < 0.05 ? 2 : undefined);
      loop.add(this.task);
    }

    reopen() {
      // Switching wheels: shrink a little and bloom again from wherever the petals are.
      if (RM) { this.bloom.snap(1); this.render(); return; }
      this.bloom.x = Math.min(this.bloom.x, 0.35);
      this.bloom.set(1, 2);
      loop.add(this.task);
    }

    close({ animate = true } = {}) {
      this.isOpen = false;
      this.el.classList.remove('open');
      if (!animate || RM) { this.bloom.snap(0); this.render(); this.el.hidden = true; return; }
      this.bloom.set(0);
      loop.add(this.task);
    }

    highlight(i, { quiet = false } = {}) {
      if (i === this.hl) return;
      if (!quiet && i >= 0 && this.petals[i]) {
        // A tick for the new petal; a jump within one ring counts the petals it crossed (it sets the tick's rate).
        const L = this.L, from = this.hl, r = L.ringOf(i);
        const d = from >= 0 && L.ringOf(from) === r ? Math.abs(i - from) : 1;
        feedback.petal(Math.max(1, Math.min(d, r.count - d)));
      }
      if (this.hl >= 0 && this.petals[this.hl]) {
        const p = this.petals[this.hl];
        p.classList.remove('hl');
        p.setAttribute('fill', `url(#${this.uid}-f${p.dataset.ring})`);
        this.labels[this.hl].classList.remove('hl');
        if (this.role !== 'menu') this.itemEls[this.hl].setAttribute('aria-selected', 'false');
      }
      this.hl = i;
      if (i >= 0 && this.petals[i]) {
        const p = this.petals[i];
        p.classList.add('hl');
        p.setAttribute('fill', `url(#${this.uid}-h${p.dataset.ring})`);
        this.labels[i].classList.add('hl');
        this.setCapsule(this.items[i].title);
        this.el.setAttribute('aria-activedescendant', this.itemEls[i].id);
        if (this.role !== 'menu') this.itemEls[i].setAttribute('aria-selected', 'true');
      } else {
        this.setCapsule(this.title);
        this.el.removeAttribute('aria-activedescendant');
      }
      if (!quiet && this.onHighlight) this.onHighlight(i, i >= 0 ? this.items[i] : null);
    }

    // The petal under a point in client coordinates, or -1.
    indexAt(clientX, clientY) {
      if (!this.svg || !this.items.length) return -1;
      const rect = this.svg.getBoundingClientRect();
      const k = rect.width / (2 * this.R);
      const x = (clientX - (rect.left + rect.width / 2)) / k, y = (clientY - (rect.top + rect.height / 2)) / k;
      const d = Math.hypot(x, y), L = this.L, last = L.rings[L.rings.length - 1];
      const ring = L.rings.find((r) => d >= r.inner - 2.5 && d <= r.outer + (r === last ? 8 : 2.5));
      if (!ring) return -1;
      if (ring.count === 1) return ring.first;
      const theta = Math.atan2(-y, x);
      let a = (L.base(ring) - theta) % TAU;
      if (a < 0) a += TAU;
      return ring.first + (Math.round(a / ring.sector) % ring.count);
    }

    step(delta) {
      const n = this.items.length;
      if (!n) return;
      this.highlight(this.hl < 0 ? (delta > 0 ? 0 : n - 1) : (this.hl + delta + n) % n);
    }
  }

  // ---------- Data (from the app's `--targets` output on sample files) ----------
  // Result names follow the app's outputURL(for:ext:suffix:) calls: "<name><suffix>.<ext>" beside the original, and
  // "<name> 2.<ext>" only when that name is taken. `suffix` and `ext` (per kind of file, or a function of the input's
  // extension) say what each tool writes; `save` describes what an editor window's Save writes.
  const keepLossy = (e) => (['jpg', 'jpeg', 'heic', 'avif'].includes(e) ? e : 'jpg');
  const TOOLS = {
    'Compress': { icon: 'compress', desc: 'A smaller copy, at a little lower quality. If it wouldn’t be smaller, nothing is kept.', suffix: ' compressed', ext: { images: keepLossy, video: 'mp4', audio: (e) => (e === 'mp3' ? 'mp3' : 'm4a') } },
    'Strip Metadata': { icon: 'metadata', label: 'Strip\nMetadata', desc: 'A copy without location, camera and other hidden details.', suffix: ' clean' },
    'Half Size': { icon: 'half', desc: 'Half the width and half the height.', suffix: ' half' },
    'Rotate 90°': { icon: 'rotate', desc: 'A quarter turn.', suffix: ' rotated' },
    'Extract Text': { icon: 'text', label: 'Extract\nText', desc: 'Reads the text, scanned or typed, into a text file.', ext: 'txt' },
    'Resize…': { icon: 'resize', desc: 'To a width, a height or a percentage.', suffix: ' resized' },
    'Add Frame…': { icon: 'frame', label: 'Add\nFrame', desc: 'A frame around the picture.', suffix: ' framed' },
    'Read QR Code': { icon: 'qr', label: 'Read\nQR Code', desc: 'Reads any QR code or barcode in the picture into a text file.', suffix: ' codes', ext: 'txt' },
    'Adjust…': { icon: 'adjust', desc: 'Exposure, contrast and more, with a live preview.', editor: true, suffix: ' adjusted' },
    'Annotate…': { icon: 'annotate', desc: 'Arrows, shapes, pen, highlighter and text.', editor: true, suffix: ' annotated' },
    'Crop…': { icon: 'crop', desc: 'Aspect presets and quarter turns.', editor: 'crop', suffix: ' cropped' },
    'Redact…': { icon: 'redact', desc: 'Black, blurred or pixelated boxes; Find Text and Find Faces suggest where. The copy keeps no hidden details.', editor: true, suffix: ' redacted' },
    'Add Background…': { icon: 'background', label: 'Add\nBackground', desc: 'Fills behind transparency, on a square, 4:5, 9:16 or 16:9 canvas.', suffix: ' background' },
    'Compress to…': { icon: 'gauge', label: 'Compress\nTo', desc: 'Down to a size you choose, in MB.', suffix: ' compressed', ext: { images: keepLossy, video: 'mp4', audio: 'm4a' } },
    'Mute': { icon: 'mute', desc: 'The same video without its sound.', suffix: ' muted' },
    'Extract Audio': { icon: 'note', label: 'Extract\nAudio', desc: 'The soundtrack as its own file.', ext: 'm4a' },
    'Normalize': { icon: 'wave', desc: 'Evens out the loudness.', suffix: ' normalized' },
    'Trim…': { icon: 'trim', desc: 'A film strip or waveform with in and out handles; cuts stay in the file’s own format.', editor: 'trim', suffix: ' trimmed' },
    'Snapshot…': { icon: 'camera', desc: 'The exact frame you pick, as a full-size PNG.', editor: true, save: () => 'the frame as a PNG' },
    'Bleep…': { icon: 'bleep', desc: 'A tone or silence over ranges you mark.', editor: true, suffix: ' bleeped' },
    'Speed…': { icon: 'speed', desc: '0.25× to 4×, with the pitch kept.', editor: true, save: (b, e) => `${b} 2x.${e} (at 2×)` },
    'Split…': { icon: 'split', desc: 'Put splits on the timeline with the scissors or ⌘B, or split evenly.', editor: 'split', save: (b, e) => `${b} part 1.${e}, ${b} part 2.${e} and so on` },
    'Channels…': { icon: 'channels', desc: 'Mono, stereo, swap, left or right.', editor: true, save: (b, e) => `${b} mono.${e} (for Mono)` },
    'Visualize…': { icon: 'bars', desc: 'A waveform, spectrum or bars as a video.', editor: true, suffix: ' visualized', ext: 'mp4' },
    'Split Pages': { icon: 'pages', label: 'Split\nPages', desc: 'One PDF per page, in a folder of their own.', folder: ' pages' },
    'Add Password': { icon: 'lock', label: 'Add\nPassword', desc: 'Locks the PDF with a password.', suffix: ' protected' },
    'Organize…': { icon: 'grid', desc: 'A page grid: reorder, rotate, duplicate, delete, insert.', editor: true, suffix: ' organized' },
    'PDF/A': { icon: 'archive', desc: 'A copy in the kind of PDF made for keeping for years.', suffix: ' PDFA' },
    'Edit PDF…': { icon: 'editpdf', label: 'Edit PDF', desc: 'Change a line’s text in place, in its own font, or add text.', editor: 'pdf', suffix: ' edited' },
    'Slide Text': { icon: 'slide', label: 'Slide\nText', desc: 'The text of every slide in one file.', ext: 'txt' },
    'Extract': { icon: 'extract', desc: 'Unpacks it into a folder beside it.', folder: '' },
  };
  const KIND_DESC = {
    video: { 'Crop…': 'A crop frame over the picture.', 'Redact…': 'Blurred, pixelated or black boxes, each for a stretch of time.' },
    pdf: { 'Rotate 90°': 'Turns the pages a quarter turn.', 'Extract Text': 'The text of every page in a text file; scanned pages are read too.' },
  };
  const ACTIONS = [
    ['Copy', 'copy', 'On the clipboard, to paste into another folder or an email'],
    ['Copy Path', 'link', 'Its location as text, for a message or Terminal'],
    ['Reveal', 'folder', 'Shown in its Finder window'],
    ['Terminal', 'terminal', 'A Terminal window opens in its folder'],
    ['AirDrop', 'airdrop', 'Sent to a Mac or iPhone nearby'],
    ['Move To…', 'move', 'Moved to a folder you pick'],
    ['Zip', 'zip', 'Packed into a zip next to it'],
    ['Float', 'float', 'Parked on a shelf above your windows'],
  ];
  const IMAGE_TOOLS = ['Compress', 'Strip Metadata', 'Half Size', 'Rotate 90°', 'Extract Text', 'Resize…', 'Add Frame…', 'Read QR Code', 'Adjust…', 'Annotate…', 'Crop…', 'Redact…', 'Add Background…', 'Compress to…'];
  const VIDEO_TOOLS = ['Compress', 'Strip Metadata', 'Mute', 'Extract Audio', 'Normalize', 'Compress to…', 'Trim…', 'Crop…', 'Redact…', 'Snapshot…', 'Bleep…', 'Speed…', 'Split…', 'Channels…'];
  const AUDIO_TOOLS = ['Compress', 'Strip Metadata', 'Normalize', 'Compress to…', 'Trim…', 'Bleep…', 'Speed…', 'Split…', 'Channels…', 'Visualize…'];
  const PDF_TOOLS = ['Compress', 'Strip Metadata', 'Rotate 90°', 'Split Pages', 'Extract Text', 'Add Password', 'Organize…', 'PDF/A', 'Compress to…', 'Edit PDF…'];
  // Ordered by how often people reach for each kind; folders sit next to archives.
  const QS = '<a href="#faq-extras">see Questions</a>';
  const KINDS = {
    images: { tab: 'Images', file: 'lake.png', convert: 'jpg heic webp tiff avif gif bmp pdf pptx', tools: IMAGE_TOOLS, thumb: 'assets/lake.webp',
      opens: 'JPG, PNG, HEIC, WebP, TIFF, AVIF, GIF, BMP', becomes: 'Each other, PDF, or PPTX with one slide per picture', note: `Saving as WebP may use ffmpeg, which YummyOrange downloads once if your Mac doesn’t have it; ${QS}.` },
    pdf: { tab: 'PDF', file: 'estimate.pdf', convert: 'png jpg svg docx txt md epub pptx xlsx', tools: PDF_TOOLS,
      opens: 'PDF', becomes: 'PNG, JPG, SVG, DOCX, TXT, Markdown, EPUB, PPTX, XLSX', note: 'TXT and Markdown keep just the text, in reading order; scanned pages are read too.' },
    documents: { tab: 'Documents', file: 'letter.docx', convert: 'pdf rtf html txt md odt epub', tools: [],
      opens: 'DOCX, DOC, RTF, HTML, TXT, Markdown, ODT', becomes: 'PDF, EPUB and each other' },
    video: { tab: 'Video', file: 'sunset.mp4', convert: 'mov mkv webm gif mp3 m4a wma avi wmv', tools: VIDEO_TOOLS, thumb: 'assets/sunset.webp',
      opens: 'MP4, MOV, MKV, WebM, AVI, WMV', becomes: 'Each other, an animated GIF, or just the sound as MP3, M4A or WMA', note: `Uses ffmpeg, which YummyOrange downloads once (about 12 MB) if your Mac doesn’t have it; ${QS}.` },
    audio: { tab: 'Audio', file: 'interview.wav', convert: 'mp3 m4a flac ogg opus aiff wma', tools: AUDIO_TOOLS,
      opens: 'MP3, M4A, WAV, FLAC, OGG, Opus, AIFF, WMA', becomes: 'Each other', note: `Uses ffmpeg, which YummyOrange downloads once (about 12 MB) if your Mac doesn’t have it; ${QS}.` },
    spreadsheets: { tab: 'Spreadsheets', file: 'budget.xlsx', convert: 'ods csv tsv pdf', tools: [],
      opens: 'XLSX, XLS, ODS, CSV, TSV', becomes: 'Each other and PDF' },
    slides: { tab: 'Slides', file: 'pitch.pptx', convert: 'pdf png jpg', tools: ['Slide Text'],
      opens: 'PPTX, PPT', becomes: 'PDF, PNG, JPG, and PPTX from PPT' },
    ebooks: { tab: 'Ebooks', file: 'novel.epub', convert: 'pdf docx txt md html', tools: [],
      opens: 'EPUB, Pages', becomes: 'PDF, DOCX, TXT, Markdown, HTML, RTF, EPUB' },
    subtitles: { tab: 'Subtitles', file: 'episode.srt', convert: 'vtt txt', tools: [],
      opens: 'SRT, VTT', becomes: 'Each other and TXT' },
    folders: { tab: 'Folders', file: 'Trip', convert: 'zip tar gz', tools: [], folder: true,
      opens: 'Folders, and any mix of files', becomes: 'ZIP, TAR, GZIP' },
    archives: { tab: 'Archives', file: 'project.tgz', convert: '', tools: ['Extract'],
      opens: 'ZIP, TAR, TGZ, BZ2, XZ, 7Z, RAR', becomes: 'A folder, with ⌘ Extract', note: 'RAR can be opened, not created.' },
  };
  const FORMAT_NOTE = {
    pdf: { txt: 'Just the text, in reading order; scanned pages are read too.', md: 'The text as Markdown; scanned pages are read too.', png: 'Every page, one image each.', jpg: 'Every page, one image each.' },
    images: { pptx: 'One slide per image.', pdf: 'One page per image.' },
    video: { gif: 'An animated GIF.', mp3: 'Just the sound.', m4a: 'Just the sound.', wma: 'Just the sound.' },
    folders: { zip: 'The folder, packed.' },
  };
  const FILES = {
    lake: { name: 'lake.png', kind: 'images' },
    sunset: { name: 'sunset.mp4', kind: 'video' },
    interview: { name: 'interview.wav', kind: 'audio' },
    estimate: { name: 'estimate.pdf', kind: 'pdf' },
    letter: { name: 'letter.docx', kind: 'documents' },
    budget: { name: 'budget.xlsx', kind: 'spreadsheets' },
    novel: { name: 'novel.epub', kind: 'ebooks' },
    trip: { name: 'Trip', kind: 'folders', folder: true },
  };
  const splitName = (name, folder) => {
    if (folder) return { base: name, ext: '' };
    const i = name.lastIndexOf('.');
    return i > 0 ? { base: name.slice(0, i), ext: name.slice(i + 1) } : { base: name, ext: '' };
  };
  // What a tool writes for `file` of `kind`: { name, folder } for a tool that saves at once, { save } for an editor.
  const toolResult = (tool, kind, file) => {
    const d = TOOLS[tool] || {}, { base, ext } = splitName(file);
    if (d.save) return { save: d.save(base, ext), prose: true };
    if (d.folder !== undefined) return { name: `${base}${d.folder}`, folder: true };
    let e = d.ext && typeof d.ext === 'object' ? d.ext[kind] : d.ext;
    if (typeof e === 'function') e = e(ext);
    const name = `${base}${d.suffix || ''}.${e || ext}`;
    return d.editor ? { save: name } : { name };
  };
  const convertName = (file, folder, fmt) => `${splitName(file, folder).base}.${fmt === 'gz' ? 'tar.gz' : fmt}`;
  const formatItems = (kind) => (KINDS[kind].convert ? KINDS[kind].convert.split(' ') : []).map((f, i) => ({
    id: f, kind: 'format', label: f === 'gz' ? 'GZIP' : f.toUpperCase(), title: f === 'gz' ? 'GZIP' : f.toUpperCase(), fmt: f, i,
  }));
  const toolItems = (kind) => KINDS[kind].tools.map((t) => {
    const d = TOOLS[t] || {};
    const plain = t.replace('…', '');
    return { id: t, kind: 'name', label: d.label || plain, title: plain, icon: d.icon, desc: (KIND_DESC[kind] || {})[t] || d.desc, tool: t, editor: d.editor };
  });
  const actionItems = () => ACTIONS.map(([t, icon, note]) => ({ id: t, kind: 'name', label: t.replace('…', ''), title: t.replace('…', ''), icon, note, action: t }));
  const LABEL_FIX = { 'Copy Path': 'Copy\nPath', 'Move To': 'Move\nTo' };
  const actionsList = actionItems().map((a) => ({ ...a, label: LABEL_FIX[a.label] || a.label }));

  // ---------- Playground ----------
  const scene = $('#scene');
  if (scene) {
    const layer = $('#wheel-layer');
    const noteText = $('#scene-note-text');
    const note = $('.scene-note');
    const live = $('#pg-live');
    const shelf = $('#result-shelf');
    const keybtns = $$('.keybtn', scene);
    const MODES = { convert: 'Convert', tools: 'Tools', actions: 'Actions' };
    const pg = { drag: null, mode: null, file: null, fileEl: null, at: null, via: null, selected: null, pending: null };

    const wheel = new Wheel(layer, {
      role: 'menu',
      onHighlight: (i, item) => { if (item && pg.via === 'keyboard') announce(live, item.title); },
    });
    wheel.el.hidden = true;

    const setNote = (text) => {
      if (noteText.textContent === text) return;
      noteText.textContent = text;
      noteText.classList.remove('swap');
      void noteText.offsetWidth;
      noteText.classList.add('swap');
    };
    const idleNote = coarse ? 'Drag a file, or tap one' : 'Grab a file and drag';
    const setState = (s) => {
      scene.dataset.state = s;
      if (s === 'idle') setNote(idleNote);
      if (s === 'dragging') setNote(coarse ? 'Now tap a key below' : 'Now tap ⇧, ⌘ or ⌥');
      if (s === 'selected') setNote('Now tap a key below');
      if (s === 'open') setNote(pg.via === 'keyboard' ? 'Pick a petal, then press Return' : pg.mode === 'convert' ? 'Let go on a format' : 'Let go on a petal');
    };
    setState('idle');

    const itemsFor = (mode, fileKey) => {
      const f = FILES[fileKey];
      if (mode === 'convert') return formatItems(f.kind);
      if (mode === 'tools') return toolItems(f.kind);
      return actionsList;
    };

    const sceneRect = () => scene.getBoundingClientRect();
    const fileCenter = (el) => {
      const r = el.querySelector('.file-icon').getBoundingClientRect(), s = sceneRect();
      return { x: r.left + r.width / 2 - s.left, y: r.top + r.height / 2 - s.top };
    };

    function markKeys() {
      keybtns.forEach((b) => b.classList.toggle('on', wheel.isOpen && b.dataset.mode === pg.mode));
    }

    function openWheel(mode, at, via) {
      const fileKey = pg.file;
      if (!fileKey) return;
      let items = itemsFor(mode, fileKey);
      const f = FILES[fileKey];
      if (!items.length) {
        // A wheel with nothing to offer: say so instead of opening an empty ring.
        setNote(mode === 'convert' ? `${f.name} has nothing to convert` : `No ⌘ tools for ${f.name}`);
        announce(live, mode === 'convert' ? `${f.name} has nothing to convert. Try Tools or Actions.` : `There are no tools for ${f.name}. Try Convert or Actions.`);
        return;
      }
      const switching = wheel.isOpen;
      pg.mode = mode;
      pg.via = via;
      hideShelf();
      wheel.setItems(items, { title: MODES[mode], label: `${MODES[mode]} wheel for ${f.name}` });
      const s = sceneRect();
      const availH = s.height - 84; // keep the key caps free
      const maxD = Math.min(s.width - 16, availH - 16);
      const scale = Math.min(1.3, maxD / (2 * wheel.R));
      wheel.setScale(scale);
      const from = switching && pg.at ? pg.at : at;
      const r = wheel.R * scale;
      // On a narrow scene the wheel fills the width: centre it below the note instead of on the pointer.
      pg.at = s.width > 2 * r + 16
        ? { x: clamp(from.x, r + 8, s.width - r - 8), y: availH > 2 * r + 16 ? clamp(from.y, r + 8, availH - r - 8) : availH / 2 }
        : { x: s.width / 2, y: clamp(availH / 2 + 20, r + 8, Math.max(r + 8, availH - r - 4)) };
      wheel.place(pg.at.x, pg.at.y);
      if (pg.drag && pg.drag.el) pg.drag.el.parentElement.classList.add('under-wheel');
      if (switching) wheel.reopen(); else wheel.open();
      setState('open');
      markKeys();
      if (via === 'keyboard') {
        wheel.el.focus({ preventScroll: true });
        wheel.highlight(0);
      } else if (pg.drag && pg.drag.last) {
        wheel.highlight(wheel.indexAt(pg.drag.last.x, pg.drag.last.y), { quiet: true });
      }
      announce(live, `${MODES[mode]} wheel, ${items.length} ${mode === 'convert' ? 'formats' : 'petals'}${via === 'keyboard' ? '. Arrow keys to choose, Return to apply, Escape to close.' : ''}`);
    }

    function closeWheel({ returnFocus = true } = {}) {
      if (!wheel.isOpen) return;
      const hadFocus = wheel.el.contains(document.activeElement) || document.activeElement === wheel.el;
      wheel.highlight(-1, { quiet: true });
      wheel.close();
      pg.at = null;
      $$('.files > li.under-wheel', scene).forEach((li) => li.classList.remove('under-wheel'));
      markKeys();
      if (hadFocus && returnFocus && pg.fileEl) pg.fileEl.focus({ preventScroll: true });
    }

    function select(btn) {
      $$('.file.selected', scene).forEach((b) => b.classList.remove('selected'));
      if (btn) btn.classList.add('selected');
      pg.selected = btn;
      pg.fileEl = btn;
      pg.file = btn ? btn.dataset.file : null;
    }

    // The result: a new shelf near the pointer, like the app's results shelf.
    function hideShelf() { shelf.hidden = true; shelf.textContent = ''; }
    function showShelf(html, at) {
      shelf.innerHTML = html;
      shelf.hidden = false;
      const s = sceneRect(), w = shelf.offsetWidth, h = shelf.offsetHeight;
      const x = clamp(at.x + 28, 12, s.width - w - 12), y = clamp(at.y - h / 2, 12, s.height - h - 84);
      shelf.style.left = `${x}px`;
      shelf.style.top = `${y}px`;
      shelf.querySelector('.r-close')?.addEventListener('click', () => { hideShelf(); (pg.fileEl || scene).focus?.({ preventScroll: true }); });
      if (!RM) shelf.animate([{ opacity: 0, transform: 'scale(0.94) translateY(6px)' }, { opacity: 1, transform: 'none' }], { duration: 260, easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)' });
    }
    const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
    function thumbFor(kind, ext) {
      if (['png', 'jpg', 'heic', 'webp', 'tiff', 'avif', 'bmp', 'gif'].includes(ext) && (kind === 'images' || kind === 'pdf')) {
        return kind === 'images' ? '<img src="assets/lake.webp" alt="">' : `<span class="r-ext">${ext.toUpperCase()}</span>`;
      }
      if (kind === 'video' && ['mp4', 'mov', 'mkv', 'webm', 'avi', 'wmv', 'gif'].includes(ext)) return '<img src="assets/sunset.webp" alt="">';
      if (kind === 'images' && ext === 'png') return '<img src="assets/lake.webp" alt="">';
      return `<span class="r-ext">${(ext || 'DIR').toUpperCase()}</span>`;
    }

    function apply(item, at) {
      const f = FILES[pg.file];
      const { base, ext } = splitName(f.name, f.folder);
      let name, note, thumb, live1, link = '';
      if (pg.mode === 'convert') {
        name = `${base}.${item.fmt === 'gz' ? 'tar.gz' : item.fmt}`;
        note = (FORMAT_NOTE[f.kind] || {})[item.fmt] || `Saved next to ${f.name}`;
        thumb = thumbFor(f.kind, item.fmt);
        live1 = `Saved ${name} next to ${f.name}`;
        setNote('Your copy, right beside it');
      } else if (pg.mode === 'tools') {
        const r = toolResult(item.tool, f.kind, f.name);
        if (item.editor) {
          name = `${item.title}: ${f.name}`;
          note = `Opens in its own window. Save writes ${r.save} beside ${f.name}.`;
          thumb = `<svg class="ic" aria-hidden="true"><use href="#i-${item.icon}"/></svg>`;
          link = typeof item.editor === 'string' ? `<a class="r-link" href="#editors" data-editor-link="${item.editor}">See the ${item.title} window</a>` : '<a class="r-link" href="#editors">See the editors</a>';
          live1 = `${item.title} opens a window for ${f.name}`;
          setNote('Some tools open a window');
        } else {
          name = r.name;
          note = item.tool === 'Split Pages' ? `A folder with ${base} page 1.pdf, ${base} page 2.pdf and so on.` : item.desc;
          thumb = r.folder ? '<svg class="ic" aria-hidden="true"><use href="#i-folder"/></svg>' : thumbFor(f.kind, splitName(r.name).ext);
          live1 = `${item.title}: saved ${name} next to ${f.name}`;
          setNote('Your copy, right beside it');
        }
      } else {
        const zip = item.action === 'Zip';
        name = zip ? `${base}.zip` : item.action === 'Float' ? f.name : `${item.title}`;
        note = item.note;
        thumb = zip ? '<span class="r-ext">ZIP</span>' : item.action === 'Float' ? thumbFor(f.kind, ext) : `<svg class="ic" aria-hidden="true"><use href="#i-${item.icon}"/></svg>`;
        live1 = `${item.title}: ${item.note}`;
        setNote(zip ? 'Your copy, right beside it' : 'Done. Try another key');
      }
      const isNew = pg.mode === 'convert' || (pg.mode === 'tools' && !item.editor) || item.action === 'Zip';
      showShelf(
        `<span class="r-thumb">${thumb}</span>` +
        `<span class="r-name"><span class="r-file">${esc(name)}</span>${isNew ? '<span class="r-new">New</span>' : ''}</span>` +
        `<button class="r-close" type="button" aria-label="Close the shelf"><svg class="ic" aria-hidden="true"><use href="#i-close"/></svg></button>` +
        `<span class="r-note">${esc(note)}</span>${link}`, at);
      announce(live, live1 + '.');
      scene.dataset.state = 'done';
    }

    // Files: drag 1:1 from where they were grabbed; spring home (with the release velocity) when let go.
    const homes = new Map();
    function returnHome(btn, vel = { vx: 0, vy: 0 }) {
      const h = homes.get(btn);
      if (!h) return;
      if (RM) { h.x.snap(0); h.y.snap(0); btn.style.transform = ''; btn.classList.remove('returning'); btn.parentElement.style.zIndex = ''; return; }
      btn.classList.add('returning');
      h.x.set(0, vel.vx); h.y.set(0, vel.vy);
      if (!h.running) {
        h.running = true;
        loop.add((dt) => {
          h.x.step(dt); h.y.step(dt);
          btn.style.transform = `translate(${h.x.x}px, ${h.y.x}px)`;
          if (h.x.done && h.y.done) { btn.style.transform = ''; btn.classList.remove('returning'); btn.parentElement.style.zIndex = ''; h.running = false; return false; }
        });
      }
    }

    // ⌥ (Alt) opens Actions, as in the app; ⌃ still works as a stand-in, but the page only ever names ⌥.
    const modeFromKey = (key) => (key === 'Shift' ? 'convert' : key === 'Meta' ? 'tools' : key === 'Alt' || key === 'Control' ? 'actions' : null);
    const modeFromEvent = (e) => (e.shiftKey ? 'convert' : e.metaKey ? 'tools' : e.altKey || e.ctrlKey ? 'actions' : null);
    // A lone ⌥ would also show the browser's menu bar on Windows and Linux and take focus from the wheel; while the
    // playground uses the key, it keeps it.
    const ownAlt = (e) => { if (e.key === 'Alt' && (pg.drag || scene.contains(document.activeElement))) e.preventDefault(); };

    $$('.file', scene).forEach((btn) => {
      homes.set(btn, { x: new Spring(0, { response: 0.42, damping: 0.9, eps: 0.05 }), y: new Spring(0, { response: 0.42, damping: 0.9, eps: 0.05 }), running: false });
      btn.addEventListener('pointerdown', (e) => {
        if (e.pointerType === 'mouse' && e.button !== 0) return;
        if (pg.drag) return;
        e.preventDefault();
        btn.focus({ preventScroll: true });
        if (wheel.isOpen) closeWheel({ returnFocus: false });
        hideShelf();
        select(btn);
        const h = homes.get(btn);
        capture(btn, e.pointerId);
        pg.drag = { id: e.pointerId, el: btn, sx: e.clientX - h.x.x, sy: e.clientY - h.y.x, started: false, hist: [], held: modeFromEvent(e), last: { x: e.clientX, y: e.clientY }, type: e.pointerType };
        h.x.v = 0; h.y.v = 0; h.x.target = h.x.x; h.y.target = h.y.x;
      });
      btn.addEventListener('pointermove', (e) => {
        const d = pg.drag;
        if (!d || d.id !== e.pointerId) return;
        d.last = { x: e.clientX, y: e.clientY };
        const dx = e.clientX - d.sx, dy = e.clientY - d.sy;
        if (!d.started) {
          if (Math.hypot(dx, dy) < 6) return;
          d.started = true;
          btn.classList.add('dragging');
          btn.parentElement.style.zIndex = 45;
          btn.classList.remove('returning');
          homes.get(btn).running = false;
          setState('dragging');
          const held = d.held || modeFromEvent(e);
          if (held) openWheel(held, toScene(e), 'pointer');
        }
        const h = homes.get(btn);
        h.x.snap(dx); h.y.snap(dy);
        btn.style.transform = `translate(${dx}px, ${dy}px)`;
        pushHist(d.hist, e.clientX, e.clientY);
        if (wheel.isOpen) wheel.highlight(wheel.indexAt(e.clientX, e.clientY));
      });
      const end = (e, cancelled) => {
        const d = pg.drag;
        if (!d || d.id !== e.pointerId) return;
        pg.drag = null;
        btn.classList.remove('dragging');
        if (!d.started) {
          // A tap or click selects the file; the keys below then open its wheels.
          if (!wheel.isOpen) setState('selected');
          return;
        }
        const vel = velocityOf(d.hist);
        if (wheel.isOpen && !cancelled && wheel.hl >= 0) {
          const item = wheel.items[wheel.hl];
          const at = toScene(e);
          closeWheel({ returnFocus: false });
          apply(item, at);
        } else {
          if (wheel.isOpen) closeWheel({ returnFocus: false });
          setState('idle');
        }
        returnHome(btn, vel);
      };
      btn.addEventListener('pointerup', (e) => end(e, false));
      btn.addEventListener('pointercancel', (e) => end(e, true));
      btn.addEventListener('keydown', (e) => {
        if ((e.key === 'Enter' || e.key === ' ') && !wheel.isOpen) {
          e.preventDefault();
          select(btn);
          openWheel('convert', fileCenter(btn), 'keyboard');
        }
      });
      btn.addEventListener('focus', () => { if (!pg.drag) select(btn); });
    });
    scene.addEventListener('contextmenu', (e) => e.preventDefault());
    const toScene = (e) => { const s = sceneRect(); return { x: e.clientX - s.left, y: e.clientY - s.top }; };

    // On-screen keys: a second finger can tap one mid-drag; otherwise they open the selected file's wheel.
    keybtns.forEach((b) => {
      b.addEventListener('pointerdown', (e) => {
        b.classList.add('pressed');
        if (pg.drag && pg.drag.started && e.pointerId !== pg.drag.id) {
          e.preventDefault();
          openWheel(b.dataset.mode, { x: pg.drag.last.x - sceneRect().left, y: pg.drag.last.y - sceneRect().top }, 'pointer');
          b.dataset.skipClick = '1';
        }
      });
      const unpress = () => b.classList.remove('pressed');
      b.addEventListener('pointerup', unpress);
      b.addEventListener('pointerleave', unpress);
      b.addEventListener('pointercancel', unpress);
      b.addEventListener('click', (e) => {
        if (b.dataset.skipClick) { delete b.dataset.skipClick; return; }
        if (!pg.file) select($('.file[data-file="lake"]', scene));
        const via = e.detail === 0 ? 'keyboard' : 'tap';
        const at = pg.at || fileCenter(pg.fileEl);
        if (wheel.isOpen && pg.mode === b.dataset.mode) { closeWheel(); setState('selected'); return; }
        openWheel(b.dataset.mode, at, via);
      });
    });

    // Tapping a petal (no drag): highlight on press, apply on release over the same petal.
    wheel.el.addEventListener('pointerdown', (e) => {
      if (pg.drag) return;
      const i = wheel.indexAt(e.clientX, e.clientY);
      wheel.highlight(i);
      capture(wheel.el, e.pointerId);
      wheel.el.dataset.press = String(i);
    });
    wheel.el.addEventListener('pointermove', (e) => {
      if (pg.drag) return;
      if (e.pointerType === 'mouse' || wheel.el.dataset.press !== undefined) wheel.highlight(wheel.indexAt(e.clientX, e.clientY));
    });
    wheel.el.addEventListener('pointerup', (e) => {
      if (pg.drag || wheel.el.dataset.press === undefined) return;
      delete wheel.el.dataset.press;
      const i = wheel.indexAt(e.clientX, e.clientY);
      if (i >= 0) {
        const item = wheel.items[i], at = toScene(e);
        closeWheel({ returnFocus: false });
        apply(item, at);
      } else if (Math.hypot(e.clientX - (sceneRect().left + wheel.cx), e.clientY - (sceneRect().top + wheel.cy)) > wheel.R * wheel.scale) {
        closeWheel(); setState('selected');
      }
    });
    scene.addEventListener('pointerdown', (e) => {
      // A press outside the wheel closes it, as in the app.
      // (The Sound button sits in the key bar: pressing it changes nothing in the demo.)
      if (wheel.isOpen && !pg.drag && !wheel.el.contains(e.target) && !e.target.closest('.keybar') && !e.target.closest('.file')) {
        closeWheel(); setState('idle');
      }
      if (!e.target.closest('.file') && !e.target.closest('.keybar') && !e.target.closest('.result-shelf') && !wheel.isOpen) {
        select(null); hideShelf(); setState('idle');
      }
    });

    // Keyboard: modifier keys open or switch wheels mid-drag; a lone tap of one opens it on the focused file.
    wheel.el.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowRight' || e.key === 'ArrowDown') { e.preventDefault(); wheel.step(1); }
      else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') { e.preventDefault(); wheel.step(-1); }
      else if (e.key === 'Home') { e.preventDefault(); wheel.highlight(0); }
      else if (e.key === 'End') { e.preventDefault(); wheel.highlight(wheel.items.length - 1); }
      else if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        if (wheel.hl >= 0) {
          const item = wheel.items[wheel.hl], at = { x: wheel.cx, y: wheel.cy };
          closeWheel();
          apply(item, at);
        }
      } else if (e.key === 'Tab') { closeWheel({ returnFocus: false }); setState('idle'); }
    });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        if (wheel.isOpen) { e.preventDefault(); closeWheel(); setState(pg.drag ? 'dragging' : 'idle'); return; }
        if (!shelf.hidden && scene.contains(document.activeElement)) { hideShelf(); setState('idle'); }
        if (pg.drag && pg.drag.started) {
          const d = pg.drag; pg.drag = null;
          d.el.classList.remove('dragging');
          try { d.el.releasePointerCapture(d.id); } catch (_) { /* already released */ }
          returnHome(d.el); setState('idle');
        }
        return;
      }
      const mode = modeFromKey(e.key);
      if (!mode) { pg.pending = null; return; }
      ownAlt(e);
      // (A held key repeats on Windows and Linux, and ⌃ stands in for ⌥: neither re-blooms the wheel that's up.)
      if (e.repeat) return;
      if (pg.drag && pg.drag.started) {
        if (wheel.isOpen && pg.mode === mode) return;
        const s = sceneRect();
        openWheel(mode, { x: pg.drag.last.x - s.left, y: pg.drag.last.y - s.top }, 'pointer');
        return;
      }
      const focusIn = scene.contains(document.activeElement);
      if ((wheel.isOpen && focusIn) || (focusIn && document.activeElement.classList.contains('file'))) {
        pg.pending = { mode, key: e.key, t: performance.now() };
      }
    });
    document.addEventListener('keyup', (e) => {
      ownAlt(e);
      const p = pg.pending;
      pg.pending = null;
      if (!p || p.key !== e.key || performance.now() - p.t > 800) return;
      if (wheel.isOpen) { if (p.mode !== pg.mode) openWheel(p.mode, pg.at, 'keyboard'); return; }
      const btn = document.activeElement;
      if (btn && btn.classList.contains('file')) { select(btn); openWheel(p.mode, fileCenter(btn), 'keyboard'); }
    });

    // Shelf links jump to an editor tab
    shelf.addEventListener('click', (e) => {
      const a = e.target.closest('[data-editor-link]');
      if (a) window.dispatchEvent(new CustomEvent('dw:editor', { detail: a.dataset.editorLink }));
    });

    // Notes draw themselves when they come into view
    const drawObs = new IntersectionObserver((entries) => {
      entries.forEach((en) => { if (en.isIntersecting) { en.target.classList.add('drawn'); drawObs.unobserve(en.target); } });
    }, { threshold: 0.6 });
    drawObs.observe(note);
    const sn = $('#screen-note');
    if (sn) drawObs.observe(sn);
  }

  // ---------- Tabs helper (WAI-ARIA tabs, automatic activation) ----------
  function tabs(list, onSelect) {
    const all = () => $$('[role="tab"]', list);
    const selectTab = (t, focus) => {
      all().forEach((x) => { const on = x === t; x.setAttribute('aria-selected', on); x.tabIndex = on ? 0 : -1; });
      if (focus) t.focus();
      t.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: RM ? 'auto' : 'smooth' });
      onSelect(t);
    };
    list.addEventListener('click', (e) => { const t = e.target.closest('[role="tab"]'); if (t) selectTab(t, false); });
    list.addEventListener('keydown', (e) => {
      const ts = all(), i = ts.indexOf(document.activeElement);
      if (i < 0) return;
      let j = -1;
      if (e.key === 'ArrowRight' || e.key === 'ArrowDown') j = (i + 1) % ts.length;
      if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') j = (i - 1 + ts.length) % ts.length;
      if (e.key === 'Home') j = 0;
      if (e.key === 'End') j = ts.length - 1;
      if (j >= 0) { e.preventDefault(); selectTab(ts[j], true); }
    });
    return selectTab;
  }

  // ---------- Explorer: every kind of file, one wheel at a time ----------
  // The kinds are a vertical tab list (a row on narrow screens); the key caps switch the wheel, as the keys do in the
  // app, and a lone tap of ⇧, ⌘ or ⌥ (or ⌃, its stand-in) does the same while focus is in the explorer.
  const esc2 = (s) => String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  const kindTabs = $('#kind-tabs');
  if (kindTabs) {
    const host = $('#ex-wheel'), cap = $('#ex-caption'), facts = $('#ex-facts'), panel = $('#explorer');
    const explorer = kindTabs.closest('.explorer');
    const keys = $$('#ex-keys .keybtn');
    const NAMES = { convert: 'Convert', tools: 'Tools', actions: 'Actions' };
    let kind = 'images', mode = 'convert';

    const itemsNow = () => (mode === 'convert' ? formatItems(kind) : mode === 'tools' ? toolItems(kind) : actionsList);
    const defaultCaption = () => {
      const k = KINDS[kind], n = itemsNow().length;
      if (mode === 'convert') return `${n} formats for <b>${esc2(k.file)}</b>. Point at one.`;
      if (mode === 'tools') return `${n} ${n === 1 ? 'tool' : 'tools'} for <b>${esc2(k.file)}</b>. Point at one.`;
      return 'The same eight actions for any file or folder. Point at one.';
    };
    const mono = (t) => `<span class="mono">${esc2(t)}</span>`;
    const captionFor = (item) => {
      if (!item) return defaultCaption();
      const k = KINDS[kind];
      if (mode === 'convert') {
        const extra = (FORMAT_NOTE[kind] || {})[item.fmt];
        return `<b>${item.title}</b> · saves ${mono(convertName(k.file, k.folder, item.fmt))} beside ${esc2(k.file)}.${extra ? ` ${extra}` : ''}`;
      }
      if (mode === 'tools') {
        const r = toolResult(item.tool, kind, k.file);
        const out = r.save ? ` Opens a window; Save writes ${r.prose ? esc2(r.save) : mono(r.save)}.`
          : r.folder ? ` Saves the folder ${mono(r.name)}.` : ` Saves ${mono(r.name)}.`;
        return `<b>${esc2(item.title)}</b> · ${esc2(item.desc || '')}${out}`;
      }
      return `<b>${esc2(item.title)}</b> · ${esc2(item.note)}.`;
    };

    const w = new Wheel(host, { role: 'listbox', onHighlight: (i, item) => { cap.innerHTML = captionFor(item); } });
    w.el.tabIndex = 0;
    // Two-ring wheels fill the box; a single ring is drawn a little larger, but not so much that its labels balloon.
    const fit = () => {
      if (!w.items.length) return;
      const box = host.clientWidth, base = box / (2 * R_TWO_RINGS), R = backdropOuter(w.items.length) + 10;
      w.setScale(Math.min(box / (2 * R), base * 1.22));
    };
    new ResizeObserver(fit).observe(host);
    w.el.addEventListener('pointermove', (e) => { if (e.pointerType === 'mouse') w.highlight(w.indexAt(e.clientX, e.clientY)); });
    // A finger picks a petal when it lifts on the one it pressed, so a swipe that starts on the wheel scrolls the page
    // (touch-action in site.css) and stays silent; the highlight, the tick and the tap land together on the lift.
    let tap = null;
    w.el.addEventListener('pointerdown', (e) => {
      if (e.pointerType === 'touch') { tap = { id: e.pointerId, i: w.indexAt(e.clientX, e.clientY) }; return; }
      w.highlight(w.indexAt(e.clientX, e.clientY));
    });
    w.el.addEventListener('pointerup', (e) => {
      const t = tap;
      tap = null;
      if (t && t.id === e.pointerId && t.i >= 0 && w.indexAt(e.clientX, e.clientY) === t.i) w.highlight(t.i);
    });
    w.el.addEventListener('pointercancel', () => { tap = null; });
    w.el.addEventListener('pointerleave', (e) => { if (e.pointerType === 'mouse') w.highlight(-1); });
    w.el.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowRight' || e.key === 'ArrowDown') { e.preventDefault(); w.step(1); }
      if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') { e.preventDefault(); w.step(-1); }
      if (e.key === 'Home') { e.preventDefault(); w.highlight(0); }
      if (e.key === 'End') { e.preventDefault(); w.highlight(w.items.length - 1); }
      if (e.key === 'Escape') w.highlight(-1);
    });
    w.el.addEventListener('blur', () => w.highlight(-1));

    const empty = (text) => {
      let e = host.querySelector('.wheel-empty');
      if (!e) { e = document.createElement('p'); e.className = 'wheel-empty'; host.appendChild(e); }
      e.textContent = text;
      e.hidden = !text;
    };
    const showFacts = () => {
      const k = KINDS[kind];
      facts.innerHTML = `<div><dt>Works on</dt><dd>${esc2(k.opens)}</dd></div><div><dt>Becomes</dt><dd>${esc2(k.becomes)}</dd></div>` +
        (k.note ? `<div><dt>Good to know</dt><dd class="note">${k.note}</dd></div>` : '');
    };
    const show = (animate) => {
      const k = KINDS[kind], items = itemsNow();
      keys.forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.mode === mode)));
      if (items.length) {
        w.el.hidden = false;
        w.setItems(items, { title: NAMES[mode], label: `${NAMES[mode]} wheel for ${k.file}` });
        fit();
        if (animate && !RM) { w.bloom.x = Math.min(w.bloom.x, 0.55); w.open(); } else w.open({ animate: false });
        empty('');
        cap.innerHTML = defaultCaption();
      } else {
        w.el.hidden = true;
        w.isOpen = false;
        empty(mode === 'tools' ? `${k.tab} have no ⌘ Tools wheel. ⇧ converts them, and ⌥ Actions work on any file.` : `${k.tab} don’t convert. ⌘ Extract unpacks them.`);
        cap.innerHTML = '';
      }
      showFacts();
      panel.setAttribute('aria-labelledby', `kind-tab-${kind}`);
    };
    const setMode = (m) => { if (m && m !== mode) { mode = m; show(true); } };

    Object.entries(KINDS).forEach(([key, k], i) => {
      const b = document.createElement('button');
      b.type = 'button'; b.setAttribute('role', 'tab'); b.id = `kind-tab-${key}`;
      b.setAttribute('aria-controls', 'explorer'); b.setAttribute('aria-selected', i === 0); b.tabIndex = i === 0 ? 0 : -1;
      b.dataset.kind = key;
      b.innerHTML = `<span class="k-name">${k.tab}</span><span class="k-file">${esc2(k.file)}</span>`;
      kindTabs.appendChild(b);
    });
    tabs(kindTabs, (t) => { if (t.dataset.kind !== kind) { kind = t.dataset.kind; show(true); } });
    const narrow = matchMedia('(max-width: 960px)');
    const orient = () => kindTabs.setAttribute('aria-orientation', narrow.matches ? 'horizontal' : 'vertical');
    narrow.addEventListener?.('change', orient);
    orient();

    keys.forEach((b) => {
      b.addEventListener('pointerdown', () => b.classList.add('pressed'));
      ['pointerup', 'pointerleave', 'pointercancel'].forEach((t) => b.addEventListener(t, () => b.classList.remove('pressed')));
      b.addEventListener('click', () => setMode(b.dataset.mode));
    });
    let pending = null;
    // (A lone ⌥ would also show the browser's menu bar on Windows and Linux and take focus from the wheel; while the
    // explorer uses the key, it keeps it.)
    const ownAlt = (e) => { if (e.key === 'Alt' && explorer.contains(document.activeElement)) e.preventDefault(); };
    document.addEventListener('keydown', (e) => {
      ownAlt(e);
      if (e.repeat) return;
      const m = e.key === 'Shift' ? 'convert' : e.key === 'Meta' ? 'tools' : e.key === 'Alt' || e.key === 'Control' ? 'actions' : null;
      pending = m && explorer.contains(document.activeElement) ? { m, key: e.key, t: performance.now() } : null;
    });
    document.addEventListener('keyup', (e) => {
      ownAlt(e);
      const p = pending;
      pending = null;
      if (p && p.key === e.key && performance.now() - p.t < 800) setMode(p.m);
    });
    show(false);
  }

  // ---------- Clothesline ----------
  const screen = $('#screen');
  if (screen) {
    const notch = $('#notch');
    const ul = $('#line-cards');
    const stringPath = $('#string-path'), glowPath = $('#string-glow-path');
    const live = $('#cl-live');
    const deskFile = $('#desk-file');
    const shotBtn = $('#shot-btn');
    const ICONS = { pdf: '#C44848', xlsx: '#2E7D52', docx: '#3C67B8', epub: '#A85A12', md: '#5E5A5C', txt: '#5E5A5C' };
    const thumbHTML = (c) => {
      if (c.kind === 'image') return `<img src="${c.img}" alt="">`;
      if (c.kind === 'video') return `<img src="${c.img}" alt=""><span class="dur">${c.dur || '0:12'}</span>`;
      if (c.kind === 'audio') return '<span class="wave-mini"></span>';
      if (c.kind === 'shot') return '<span class="shot-mini"><img src="assets/sunset.webp" alt=""></span>';
      return `<span class="doc-mini"></span><span class="ext" style="background:${ICONS[c.ext] || '#6B6468'}">${c.ext.toUpperCase()}</span>`;
    };
    const START = [
      { name: 'lake.png', kind: 'image', img: 'assets/lake.webp' },
      { name: 'sunset.mp4', kind: 'video', img: 'assets/sunset.webp' },
      { name: 'estimate.pdf', kind: 'doc', ext: 'pdf' },
      { name: 'interview.wav', kind: 'audio' },
      { name: 'budget.xlsx', kind: 'doc', ext: 'xlsx' },
      { name: 'letter.docx', kind: 'doc', ext: 'docx' },
      { name: 'novel.epub', kind: 'doc', ext: 'epub' },
      { name: 'estimate.txt', kind: 'doc', ext: 'txt' },
    ];
    const G = {};
    const geom = () => {
      G.W = screen.clientWidth; G.H = screen.clientHeight; G.cx = G.W / 2;
      G.top = 46; G.notchBottom = 32;
      G.sag = clamp(G.W * 0.045, 18, 52);
      G.cw = clamp(G.W * 0.094, 84, 112);
      G.pitch = G.cw + clamp(G.W * 0.018, 10, 20);
      G.start = clamp(G.W * 0.045, 18, 56) + G.cw / 2;
      G.cardH = G.cw * 0.75 + 12 + 24;
      G.lineBottom = G.top + G.sag + G.cardH + 30;
      screen.style.setProperty('--cw', `${G.cw}px`);
      screen.style.setProperty('--line-bottom', `${Math.round(G.lineBottom)}px`);
    };
    geom();

    const drop = new Spring(0, { response: 0.55, damping: 0.78 });
    // Sideways scroll of a long line (two-finger scroll or a drag on the string), with rubber-banding at the ends.
    const scroll = new Spring(0, { response: 0.4, damping: 1, eps: 0.05 });
    const rubber = (o, dim, k = 0.55) => (o * dim * k) / (dim + k * Math.abs(o));
    const project = (v, d = 0.998) => ((v / 1000) * d) / (1 - d);
    // Cards are damped pendulums driven by their pin's acceleration. Damping ratio about 0.41 (C / 2ω with
    // ω = 2π / 1.15 s): a swing or two, settled in under two seconds. Neighbours that only make room feel a third of
    // the push; a card that was just hung, thrown or carried feels all of it (`lively`). Past SOFT radians the swing
    // meets a progressively stiffer spring, so it slows before LIM instead of hitting a wall.
    const K = Math.pow(TAU / 1.15, 2), C = 4.5, PEND_L = 96, SOFT = 0.32, LIM = 0.6, WALL = 400;
    const CALM_DRIVE = 0.35, LIVELY_MS = 900;
    const liven = (c) => { c.lively = performance.now() + LIVELY_MS; };
    let cards = [];
    let out = false, uid = 0, ghost = null, dragCard = null, selected = null, undo = null;
    let hideTimer = 0, armTimer = 0, shownAt = 0;

    function makeCard(data) {
      const c = { ...data, id: ++uid, theta: 0, omega: 0, ppx: null, pvx: 0, x: new Spring(0, { response: 0.32, damping: 1, eps: 0.05 }), yOff: new Spring(0, { response: 0.4, damping: 0.75, eps: 0.05 }), alpha: 1 };
      const li = document.createElement('li');
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'card';
      b.innerHTML = `<span class="pin" aria-hidden="true"></span><span class="card-thumb" aria-hidden="true">${thumbHTML(c)}</span><span class="card-name">${c.name}</span>`;
      li.appendChild(b);
      c.li = li; c.el = b;
      wireCard(c);
      return c;
    }
    const slotX = (i) => G.start + i * G.pitch;
    const layoutSlots = (snap) => {
      const list = cards.filter((c) => c !== dragCard);
      let i = 0;
      const ghostAt = ghost ? ghost.index : -1;
      list.forEach((c) => {
        if (i === ghostAt) i++;
        c.slot = i;
        if (snap) c.x.snap(slotX(i)); else c.x.set(slotX(i));
        i++;
      });
      if (dragCard) dragCard.slot = dragCard.index ?? 0;
    };
    const ends = (d) => {
      const dd = clamp(d, 0, 1);
      return { x0: G.cx - dd * (G.cx + 24), x1: G.cx + dd * (G.W - G.cx + 24), y: G.notchBottom - 8 + d * (G.top - G.notchBottom + 8), sag: G.sag * d };
    };
    const stringY = (x, d) => {
      const e = ends(d), half = (e.x1 - e.x0) / 2 || 1;
      const u = clamp((x - G.cx) / half, -1, 1);
      return e.y + e.sag * (1 - u * u);
    };

    function render(dt) {
      const d = RM ? (out ? 1 : 0) : drop.x;
      const dd = clamp(d, 0, 1);
      const e = ends(RM ? 1 : d);
      const pathD = `M${f2(e.x0)} ${f2(e.y)}Q${f2(G.cx)} ${f2(e.y + 2 * e.sag)} ${f2(e.x1)} ${f2(e.y)}`;
      stringPath.setAttribute('d', pathD);
      glowPath.setAttribute('d', pathD);
      const vis = RM ? (out ? 1 : 0) : dd;
      stringPath.style.opacity = vis > 0.01 ? 1 : 0;
      glowPath.style.opacity = vis > 0.01 ? 0.75 : 0;
      const all = ghost ? [...cards, ghost.card] : cards;
      all.forEach((c) => {
        let pinX, pinY;
        if (c.flight) {
          pinX = c.fx; pinY = c.fy;
        } else if (c === dragCard && c.free) {
          pinX = c.freeX; pinY = c.freeY;
        } else {
          const sx = c.x.x - scroll.x;
          pinX = RM ? sx : G.cx + (sx - G.cx) * dd;
          pinY = stringY(pinX, RM ? 1 : d) + c.yOff.x;
        }
        // Damped pendulum driven by the pin's acceleration (the card lags, then swings back).
        if (c.flight) {
          c.theta = 0.3 * (1 - c.flight.t); c.omega = 0; c.ppx = pinX; c.pvx = 0;
        } else if (!RM && dt > 0) {
          if (c.ppx === null) { c.ppx = pinX; c.pvx = 0; c.axs = 0; }
          const vx = (pinX - c.ppx) / dt;
          // The pin's acceleration, smoothed over a few frames so an uneven frame or a jerky pointer doesn't kick.
          const raw = clamp((vx - c.pvx) / dt, -6000, 6000);
          c.axs = (c.axs || 0) + (raw - (c.axs || 0)) * Math.min(1, dt * 25);
          const ax = c.axs;
          c.ppx = pinX; c.pvx = vx;
          const drive = c === dragCard || (c.lively || 0) > performance.now() ? 1 : CALM_DRIVE;
          let t = dt;
          while (t > 1e-6) {
            const h = Math.min(t, 1 / 240);
            let acc = -K * Math.sin(c.theta) - C * c.omega + drive * (ax / PEND_L) * Math.cos(c.theta);
            const over = Math.abs(c.theta) - SOFT;
            if (over > 0) acc -= Math.sign(c.theta) * WALL * over;
            c.omega += acc * h;
            c.theta += c.omega * h;
            if (Math.abs(c.theta) > LIM) {
              c.theta = Math.sign(c.theta) * LIM;
              if (Math.sign(c.omega) === Math.sign(c.theta)) c.omega = 0;
            }
            t -= h;
          }
        } else { c.theta = 0; c.omega = 0; }
        const s = RM || c.flight ? 1 : 0.4 + 0.6 * dd;
        const op = c.flight ? 1 : (RM ? (out ? 1 : 0) : clamp(dd * 2.4 - 0.2, 0, 1)) * (c.alpha ?? 1);
        c.el.style.transform = `translate(${f2(pinX - G.cw / 2)}px, ${f2(pinY + 2)}px) rotate(${(c.theta * 57.2958).toFixed(2)}deg) scale(${s.toFixed(3)})`;
        c.el.style.opacity = op.toFixed(3);
        c.pinX = pinX; c.pinY = pinY;
      });
    }

    function settled() {
      if (!drop.done || !scroll.done) return false;
      const all = ghost ? [...cards, ghost.card] : cards;
      return all.every((c) => c.x.done && c.yOff.done && Math.abs(c.theta) < 0.002 && Math.abs(c.omega) < 0.02 && c !== dragCard && !c.flight);
    }
    let running = false;
    const task = (dt) => {
      drop.step(dt);
      if (!pan) scroll.step(dt);
      (ghost ? [...cards, ghost.card] : cards).forEach((c) => {
        if (RM) { c.x.snap(c.x.target); c.yOff.snap(c.yOff.target); } else { c.x.step(dt); c.yOff.step(dt); }
        if (c.flight) stepFlight(c, dt);
      });
      render(dt);
      if (settled() && !dragCard) { running = false; if (!out) ul.inert = true; return false; }
    };
    let pan = null;
    const maxScroll = () => Math.max(0, G.start + (cards.length - 1) * G.pitch + G.cw / 2 + 16 - G.W);
    screen.addEventListener('pointerdown', (e) => {
      if (!out || e.target.closest('.card, .notch, .desk-file, .shot-btn')) return;
      const r = screen.getBoundingClientRect(), y = e.clientY - r.top;
      if (y < G.top - 12 || y > G.lineBottom) return;
      capture(screen, e.pointerId);
      pan = { id: e.pointerId, x0: e.clientX, s0: scroll.x, hist: [] };
      scroll.v = 0;
    });
    screen.addEventListener('pointermove', (e) => {
      if (!pan || pan.id !== e.pointerId) return;
      pushHist(pan.hist, e.clientX, e.clientY);
      const raw = pan.s0 - (e.clientX - pan.x0), max = maxScroll();
      scroll.snap(raw < 0 ? -rubber(-raw, G.W) : raw > max ? max + rubber(raw - max, G.W) : raw);
      clearTimeout(hideTimer);
      kick();
    });
    const panEnd = (e) => {
      if (!pan || pan.id !== e.pointerId) return;
      const v = -velocityOf(pan.hist).vx;
      pan = null;
      // Land where the flick was heading (Apple's projection), then let the spring carry the velocity there.
      const target = clamp(scroll.x + project(v), 0, maxScroll());
      if (RM) scroll.snap(target); else scroll.set(target, v);
      kick();
    };
    screen.addEventListener('pointerup', panEnd);
    screen.addEventListener('pointercancel', panEnd);
    let wheelRaw = null, wheelIdle = 0;
    screen.addEventListener('wheel', (e) => {
      if (!out || Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
      e.preventDefault();
      const max = maxScroll();
      if (wheelRaw === null) wheelRaw = clamp(scroll.x, 0, max);
      wheelRaw += e.deltaX;
      scroll.snap(wheelRaw < 0 ? -rubber(-wheelRaw, G.W) : wheelRaw > max ? max + rubber(wheelRaw - max, G.W) : wheelRaw);
      clearTimeout(hideTimer);
      clearTimeout(wheelIdle);
      wheelIdle = setTimeout(() => {
        wheelRaw = null;
        const t = clamp(scroll.x, 0, maxScroll());
        if (t !== scroll.x) { if (RM) scroll.snap(t); else scroll.set(t, 0); kick(); }
      }, 140);
      kick();
    }, { passive: false });

    const kick = () => { if (!running) { running = true; cards.forEach((c) => { c.ppx = null; }); loop.add(task); } };

    // The note: where to rest the pointer, then one next thing to try at a time.
    const noteEl = $('#screen-note-text');
    const restNote = coarse ? 'Tap the notch' : 'Rest the pointer in the notch';
    const did = { moved: false, hung: false, shot: false };
    const setCNote = (t) => {
      if (noteEl.textContent === t) return;
      noteEl.textContent = t;
      noteEl.classList.remove('swap');
      void noteEl.offsetWidth;
      noteEl.classList.add('swap');
    };
    const nextNote = () => (!did.moved ? 'Drag a card along the line'
      : !did.hung ? 'Now drag notes.md up to the line'
        : !did.shot ? 'Copied screenshots hang here too'
          : coarse ? 'Tap the notch to put it away' : 'Move away and the line goes back up');
    noteEl.textContent = restNote;

    function show(reason) {
      clearTimeout(hideTimer);
      if (out) return;
      out = true;
      shownAt = performance.now();
      screen.classList.add('line-out');
      notch.setAttribute('aria-expanded', 'true');
      notch.querySelector('.visually-hidden').textContent = 'Put the Clothesline away';
      ul.inert = false;
      setCNote(nextNote());
      if (RM) { drop.snap(1); render(0); }
      else { drop.damping = 0.78; drop.set(1, drop.x < 0.05 ? 0.6 : undefined); kick(); }
      if (reason !== 'quiet') announce(live, `The Clothesline is out with ${cards.length} files.`);
    }
    function hide() {
      clearTimeout(hideTimer);
      if (!out || dragCard || ghost) return;
      out = false;
      screen.classList.remove('line-out');
      notch.setAttribute('aria-expanded', 'false');
      notch.querySelector('.visually-hidden').textContent = 'Show the Clothesline';
      setCNote(restNote);
      setSelected(null);
      if (RM) { drop.snap(0); render(0); ul.inert = true; }
      else { drop.damping = 1; drop.set(0); kick(); }
    }
    const scheduleHide = (ms = 650) => { clearTimeout(hideTimer); hideTimer = setTimeout(() => { if (!screen.contains(document.activeElement) || document.activeElement === deskFile || document.activeElement === shotBtn) hide(); }, ms); };

    cards = START.map(makeCard);
    cards.forEach((c) => ul.appendChild(c.li));
    layoutSlots(true);
    ul.inert = true;
    render(0);

    // Rest in the notch for half a second
    notch.addEventListener('pointerenter', (e) => {
      if (e.pointerType !== 'mouse' || out) return;
      notch.classList.add('arming');
      clearTimeout(armTimer);
      armTimer = setTimeout(() => { notch.classList.remove('arming'); show(); }, 500);
    });
    notch.addEventListener('pointerleave', () => { clearTimeout(armTimer); notch.classList.remove('arming'); });
    notch.addEventListener('click', () => {
      if (out && performance.now() - shownAt < 1500 && notch.matches(':hover')) return;
      if (out) hide(); else show();
    });

    // Leaving the line puts it away (it stays while the pointer is over it or a card has the keyboard)
    screen.addEventListener('pointermove', (e) => {
      if (!out || dragCard || ghost) return;
      const r = screen.getBoundingClientRect(), y = e.clientY - r.top;
      if (y < G.lineBottom) clearTimeout(hideTimer);
      else if (!selected) scheduleHide();
    });
    screen.addEventListener('pointerdown', (e) => { if (!e.target.closest('.card')) setSelected(null); });
    screen.addEventListener('pointerleave', () => { if (out && !dragCard && !ghost && !selected) scheduleHide(); });
    screen.addEventListener('focusout', (e) => { if (!screen.contains(e.relatedTarget)) { setSelected(null); scheduleHide(400); } });

    function setSelected(c, focus) {
      if (selected) selected.el.classList.remove('selected');
      selected = c;
      if (c) {
        c.el.classList.add('selected');
        if (focus) c.el.focus({ preventScroll: true });
        const x = slotX(Math.max(indexOf(c), 0)) - scroll.x;
        if (x - G.cw / 2 < 8 || x + G.cw / 2 > G.W - 8) {
          const t = clamp(slotX(indexOf(c)) - G.W / 2, 0, maxScroll());
          if (RM) scroll.snap(t); else scroll.set(t);
          kick();
        }
      }
    }
    const indexOf = (c) => cards.indexOf(c);
    const sayPos = (c) => `${c.name}, ${indexOf(c) + 1} of ${cards.length}`;
    function reorder(c, to) {
      const from = indexOf(c);
      to = clamp(to, 0, cards.length - 1);
      if (from === to) return;
      cards.splice(from, 1);
      cards.splice(to, 0, c);
      ul.insertBefore(c.li, ul.children[to + (to > from ? 1 : 0)] || null);
      layoutSlots(false);
      kick();
    }
    function removeCard(c) {
      const i = indexOf(c);
      if (i < 0) return;
      undo = { card: c, index: i };
      cards.splice(i, 1);
      c.li.remove();
      layoutSlots(false);
      kick();
      const next = cards[Math.min(i, cards.length - 1)];
      setSelected(next || null, true);
      announce(live, `${c.name} taken off the line. The file stays where it is. Command Z puts it back.`);
    }
    function restore() {
      if (!undo) return;
      const { card, index } = undo;
      undo = null;
      cards.splice(index, 0, card);
      ul.insertBefore(card.li, ul.children[index] || null);
      card.x.snap(slotX(index)); card.yOff.snap(-30); card.yOff.set(0, 0); card.omega = RM ? 0 : 1.5; liven(card);
      layoutSlots(false);
      kick();
      setSelected(card, true);
      announce(live, `${card.name} is back on the line.`);
    }

    function wireCard(c) {
      const b = c.el;
      b.addEventListener('focus', () => { setSelected(c); clearTimeout(hideTimer); b.setAttribute('aria-label', sayPos(c)); });
      b.addEventListener('keydown', (e) => {
        const i = indexOf(c);
        const move = e.altKey || e.metaKey || e.ctrlKey;
        if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
          e.preventDefault();
          const dir = e.key === 'ArrowRight' ? 1 : -1;
          if (move) { reorder(c, i + dir); liven(c); b.focus({ preventScroll: true }); announce(live, `Moved ${dir > 0 ? 'right' : 'left'}: ${sayPos(c)}`); b.setAttribute('aria-label', sayPos(c)); if (!did.moved) { did.moved = true; setCNote(nextNote()); } }
          else { const n = cards[clamp(i + dir, 0, cards.length - 1)]; setSelected(n, true); }
        } else if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); removeCard(c); }
        else if (e.key === 'Escape') { setSelected(null); b.blur(); notch.focus(); scheduleHide(300); }
        else if ((e.key === 'z' || e.key === 'Z') && (e.metaKey || e.ctrlKey)) { e.preventDefault(); restore(); }
        else if (e.key === 'Enter') { e.preventDefault(); announce(live, `In the app, this opens ${c.name}.`); }
      });
      // Press and drag a card along the string: it hangs from its pin under the pointer while the others make room.
      b.addEventListener('pointerdown', (e) => {
        if (e.pointerType === 'mouse' && e.button !== 0) return;
        if (dragCard) return;
        e.preventDefault();
        capture(b, e.pointerId);
        setSelected(c, true);
        clearTimeout(hideTimer);
        const r = screen.getBoundingClientRect();
        c.press = { id: e.pointerId, sx: e.clientX, sy: e.clientY, gx: e.clientX - r.left - c.pinX, gy: e.clientY - r.top - c.pinY, hist: [], order: cards.slice(), lifted: false };
      });
      b.addEventListener('pointermove', (e) => {
        const p = c.press;
        if (!p || p.id !== e.pointerId) return;
        const r = screen.getBoundingClientRect();
        if (!p.lifted) {
          if (Math.hypot(e.clientX - p.sx, e.clientY - p.sy) < 4) return;
          p.lifted = true;
          dragCard = c; c.free = true; b.classList.add('lifted');
          c.li.style.zIndex = 5;
          kick();
        }
        pushHist(p.hist, e.clientX, e.clientY);
        c.freeX = e.clientX - r.left - p.gx;
        c.freeY = Math.max(e.clientY - r.top - p.gy, G.top - 10);
        const others = cards.filter((x) => x !== c);
        const to = clamp(Math.round((c.freeX + scroll.x - G.start) / G.pitch), 0, others.length);
        if (to !== c.index) {
          c.index = to;
          let k = 0;
          others.forEach((o) => { if (k === to) k++; o.x.set(slotX(k)); k++; });
          kick();
        }
      });
      const end = (e, cancel) => {
        const p = c.press;
        if (!p || p.id !== e.pointerId) return;
        c.press = null;
        if (!p.lifted) return;
        b.classList.remove('lifted');
        c.li.style.zIndex = '';
        const { vx, vy } = velocityOf(p.hist);
        const pinX = c.freeX, pinY = c.freeY;
        c.free = false;
        dragCard = null;
        const r = screen.getBoundingClientRect();
        const below = e.clientY - r.top > G.lineBottom + 40;
        if (cancel || below) {
          // Esc, or pulled well below the line: back to where it was. (In the app, letting go over a folder moves the file there.)
          cards = p.order;
          if (below && !cancel) announce(live, `In the app, letting go of ${c.name} over a folder moves the file there. Here it goes back on the line.`);
        } else {
          const to = c.index ?? indexOf(c);
          cards = cards.filter((x) => x !== c);
          cards.splice(to, 0, c);
          announce(live, `Moved: ${sayPos(c)}`);
          if (!did.moved) { did.moved = true; setCNote(nextNote()); }
        }
        cards.forEach((x) => ul.appendChild(x.li));
        c.index = undefined;
        // Hand the pointer's velocity to the springs so there is no seam between the drag and the settle.
        liven(c);
        c.x.snap(pinX + scroll.x); c.x.set(slotX(indexOf(c)), vx);
        const sy = stringY(pinX, 1);
        c.yOff.snap(pinY - sy); c.yOff.set(0, vy);
        layoutSlots(false);
        kick();
        b.focus({ preventScroll: true });
      };
      b.addEventListener('pointerup', (e) => end(e, false));
      b.addEventListener('pointercancel', (e) => end(e, true));
      b.addEventListener('lostpointercapture', (e) => { if (c.press && c.press.id === e.pointerId) end(e, true); });
    }
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && dragCard && dragCard.press) {
        const c = dragCard;
        try { c.el.releasePointerCapture(c.press.id); } catch (_) { /* fine */ }
      }
    });

    // Drag a file up to the notch: the line drops, a translucent card with an open pin shows where it will hang.
    const deskHome = { x: new Spring(0, { response: 0.42, damping: 0.9, eps: 0.05 }), y: new Spring(0, { response: 0.42, damping: 0.9, eps: 0.05 }) };
    let desk = null;
    const NOTES = { name: 'notes.md', kind: 'doc', ext: 'md' };
    const existing = () => cards.find((c) => c.name === NOTES.name);
    function placeGhost(x) {
      const n = cards.length - (ghost && ghost.existing ? 1 : 0);
      const idx = clamp(Math.round((x + scroll.x - G.start) / G.pitch), 0, n);
      if (!ghost) {
        const ex = existing();
        if (ex) {
          ghost = { card: ex, existing: true, index: idx };
          cards = cards.filter((c) => c !== ex);
        } else {
          const card = makeCard(NOTES);
          card.alpha = 0.55; card.el.classList.add('ghost');
          ul.appendChild(card.li);
          ghost = { card, existing: false, index: idx };
        }
        ghost.card.x.snap(slotX(idx));
        ghost.card.ppx = null;
        ghost.card.yOff.snap(-24); ghost.card.yOff.set(0);
        ghost.card.alpha = 0.55; ghost.card.el.classList.add('ghost');
      }
      if (idx !== ghost.index) { ghost.index = idx; ghost.card.x.set(slotX(idx)); }
      layoutSlots(false);
      kick();
    }
    function dropGhost(commit) {
      if (!ghost) return;
      const g = ghost;
      ghost = null;
      g.card.el.classList.remove('ghost');
      g.card.alpha = 1;
      if (commit) {
        cards.splice(g.index, 0, g.card);
        if (!g.existing) { /* new card stays */ }
        cards.forEach((x) => ul.appendChild(x.li));
        g.card.omega = RM ? 0 : 1.8;
        liven(g.card);
        announce(live, `notes.md hangs on the Clothesline, ${g.index + 1} of ${cards.length}. The file stays where it is.`);
        did.hung = true;
        setCNote('Hung. notes.md itself stays where it was');
      } else if (g.existing) {
        cards.splice(Math.min(g.card.slot ?? 0, cards.length), 0, g.card);
        cards.forEach((x) => ul.appendChild(x.li));
      } else {
        g.card.li.remove();
      }
      layoutSlots(false);
      kick();
    }
    deskFile.addEventListener('pointerdown', (e) => {
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      e.preventDefault();
      deskFile.focus({ preventScroll: true });
      capture(deskFile, e.pointerId);
      desk = { id: e.pointerId, sx: e.clientX - deskHome.x.x, sy: e.clientY - deskHome.y.x, started: false, hist: [], near: 0 };
    });
    deskFile.addEventListener('pointermove', (e) => {
      if (!desk || desk.id !== e.pointerId) return;
      const dx = e.clientX - desk.sx, dy = e.clientY - desk.sy;
      if (!desk.started) { if (Math.hypot(dx, dy) < 4) return; desk.started = true; deskFile.classList.add('dragging'); }
      deskHome.x.snap(dx); deskHome.y.snap(dy);
      deskFile.style.transform = `translate(${dx}px, ${dy}px)`;
      pushHist(desk.hist, e.clientX, e.clientY);
      const r = screen.getBoundingClientRect(), x = e.clientX - r.left, y = e.clientY - r.top;
      const nearNotch = Math.abs(x - G.cx) < 140 && y < 90;
      desk.x = x; desk.y = y;
      if (!out && nearNotch && !desk.nearTimer) {
        desk.nearTimer = setTimeout(() => { if (desk && desk.nearNow) { show('quiet'); placeGhost(desk.x); } }, 300);
      }
      if (!nearNotch && desk.nearTimer) { clearTimeout(desk.nearTimer); desk.nearTimer = 0; }
      desk.nearNow = nearNotch;
      if (out) {
        const over = y < G.lineBottom;
        if (over) { clearTimeout(hideTimer); placeGhost(x); }
        else if (ghost) { dropGhost(false); scheduleHide(350); }
      }
    });
    const deskEnd = (e, cancel) => {
      if (!desk || desk.id !== e.pointerId) return;
      const d = desk;
      desk = null;
      clearTimeout(d.nearTimer);
      deskFile.classList.remove('dragging');
      if (!ghost && out && d.started && !cancel && d.y < G.lineBottom) placeGhost(d.x);
      if (ghost) dropGhost(!cancel);
      const vel = velocityOf(d.hist);
      if (RM) { deskHome.x.snap(0); deskHome.y.snap(0); deskFile.style.transform = ''; }
      else {
        deskHome.x.set(0, vel.vx); deskHome.y.set(0, vel.vy);
        loop.add((dt) => {
          deskHome.x.step(dt); deskHome.y.step(dt);
          deskFile.style.transform = `translate(${deskHome.x.x}px, ${deskHome.y.x}px)`;
          if (deskHome.x.done && deskHome.y.done) { deskFile.style.transform = ''; return false; }
        });
      }
    };
    deskFile.addEventListener('pointerup', (e) => deskEnd(e, false));
    deskFile.addEventListener('pointercancel', (e) => deskEnd(e, true));
    deskFile.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter' && e.key !== ' ') return;
      e.preventDefault();
      show('quiet');
      const ex = existing();
      if (ex) { reorder(ex, 0); setSelected(ex, true); announce(live, `notes.md is already on the line; moved to the front.`); return; }
      const card = makeCard(NOTES);
      cards.unshift(card);
      ul.insertBefore(card.li, ul.firstChild);
      card.x.snap(slotX(0)); card.yOff.snap(-30); card.yOff.set(0); card.omega = RM ? 0 : 1.8; liven(card);
      layoutSlots(false);
      kick();
      setSelected(card, true);
      announce(live, `notes.md hangs on the Clothesline, 1 of ${cards.length}. The file stays where it is.`);
      did.hung = true;
      setCNote('Hung. notes.md itself stays where it was');
    });

    // Copy a screenshot: it flies up along an arc and the pin catches it.
    let shotN = 7;
    function stepFlight(c, dt) {
      const f = c.flight;
      f.t = Math.min(f.t + dt / f.dur, 1);
      const t = 1 - Math.pow(1 - f.t, 3);
      const sx0 = slotX(0) - scroll.x;
      const target = { x: G.cx + (sx0 - G.cx) * clamp(drop.x, 0, 1), y: stringY(sx0, drop.x) };
      const cx = (f.from.x + target.x) / 2 + 40, cy = Math.min(f.from.y, target.y) - 120;
      c.fx = (1 - t) * (1 - t) * f.from.x + 2 * (1 - t) * t * cx + t * t * target.x;
      c.fy = (1 - t) * (1 - t) * f.from.y + 2 * (1 - t) * t * cy + t * t * target.y;
      if (f.t >= 1) { c.flight = null; c.x.snap(slotX(0)); c.yOff.snap(c.fy - stringY(c.fx, drop.x)); c.yOff.set(0); c.omega = 2; liven(c); }
    }
    shotBtn.addEventListener('click', () => {
      const secs = String(++shotN).padStart(2, '0');
      const card = makeCard({ name: `Screenshot 2026-11-24 at 10.31.${secs}.png`, kind: 'shot' });
      const r = screen.getBoundingClientRect(), b = shotBtn.getBoundingClientRect();
      if (!RM) {
        const flash = document.createElement('div');
        flash.className = 'flash';
        screen.appendChild(flash);
        flash.animate([{ opacity: 0.55 }, { opacity: 0 }], { duration: 320, easing: 'ease-out' }).onfinish = () => flash.remove();
      }
      show('quiet');
      if (RM) scroll.snap(0); else scroll.set(0);
      cards.unshift(card);
      ul.insertBefore(card.li, ul.firstChild);
      if (cards.length > 12) { const old = cards.pop(); old.li.remove(); }
      layoutSlots(false);
      if (RM) { card.x.snap(slotX(0)); }
      else {
        card.flight = { t: 0, dur: 0.75, from: { x: b.left - r.left + b.width / 2, y: b.top - r.top } };
        card.x.snap(slotX(0));
      }
      kick();
      announce(live, `${card.name} hangs on the Clothesline, saved in Pictures, Clothesline.`);
      did.shot = true;
      setCNote('Saved in Pictures › Clothesline');
    });

    new ResizeObserver(() => { geom(); layoutSlots(true); render(0); if (running) kick(); }).observe(screen);
  }

  // ---------- From a link (LinkDownload.swift, simulated) ----------
  // A post's address dragged out of the browser: ⇧ opens the Convert wheel with MP4, MP3, M4A and WAV (a link's only
  // wheel, as in the app), the corner banner shows the download, and the new file flies out of it onto the Clothesline.
  // The posts are made up and use the page's own pictures; nothing is fetched.
  const desk = $('#link-desk');
  if (desk) {
    const POSTS = {
      youtube: { url: 'youtube.com/watch?v=sunset-drive', title: 'Sunset drive', by: 'yummyorange', dur: '2:47', img: 'assets/sunset.webp', pos: '50% 50%' },
      x: { url: 'x.com/yummyorange/status/1862094517203', title: 'Lake at dawn', by: '@yummyorange', dur: '0:21', img: 'assets/lake.webp', pos: '50% 40%' },
      instagram: { url: 'instagram.com/reel/DdahliaHour', title: 'Dahlia hour', by: 'yummyorange', dur: '0:34', img: 'assets/sunset.webp', pos: '18% 70%' },
      tiktok: { url: 'tiktok.com/@yummyorange/video/7443021904', title: 'Morning swim', by: '@yummyorange', dur: '0:15', img: 'assets/lake.webp', pos: '85% 75%' },
      threads: { url: 'threads.com/@yummyorange/post/DfStillWater', title: 'Still water', by: '@yummyorange', dur: '0:28', img: 'assets/lake.webp', pos: '20% 20%' },
    };
    const SITE = { youtube: 'YouTube', x: 'X', instagram: 'Instagram', tiktok: 'TikTok', threads: 'Threads' };
    const ITEMS = [
      { id: 'mp4', kind: 'format', label: 'MP4', title: 'MP4 video', fmt: 'mp4' },
      { id: 'mp3', kind: 'format', label: 'MP3', title: 'MP3 sound', fmt: 'mp3' },
      { id: 'm4a', kind: 'format', label: 'M4A', title: 'M4A sound', fmt: 'm4a' },
      { id: 'wav', kind: 'format', label: 'WAV', title: 'WAV sound', fmt: 'wav' },
    ];
    const address = $('#lk-address'), urlEl = $('#lk-url'), img = $('#lk-img'), durEl = $('#lk-dur');
    const titleEl = $('#lk-post-title'), metaEl = $('#lk-meta'), page = $('#lk-page');
    const chip = $('#lk-chip'), chipTitle = $('#lk-chip-title'), chipURL = $('#lk-chip-url');
    const hud = $('#lk-hud'), hudText = $('#lk-hud-text'), hudFill = $('#lk-hud-fill');
    const notch = $('#lk-notch'), ul = $('#lk-cards'), stringPath = $('#lk-string'), glowPath = $('#lk-glow');
    const note = $('#lk-note'), noteText = $('#lk-note-text'), live = $('#lk-live'), shiftBtn = $('#lk-shift');
    const lk = { site: 'youtube', drag: null, via: null, at: null, busy: false, again: false, pending: 0 };
    const post = () => POSTS[lk.site];

    const wheel = new Wheel($('#lk-wheel-layer'), {
      role: 'menu',
      onHighlight: (i, item) => { if (item && lk.via === 'keyboard') announce(live, item.title); },
    });
    wheel.setItems(ITEMS, { title: 'Convert', label: 'Convert wheel for the link' });
    wheel.el.hidden = true;

    const deskRect = () => desk.getBoundingClientRect();
    const toDesk = (x, y) => { const r = deskRect(); return { x: x - r.left, y: y - r.top }; };
    const addressCenter = () => { const a = urlEl.getBoundingClientRect(); return toDesk(a.left + a.width / 2, a.top + a.height / 2); };

    // ----- The note: one next step at a time
    const setNote = (text) => {
      if (noteText.textContent === text) return;
      noteText.textContent = text;
      noteText.classList.remove('swap');
      void noteText.offsetWidth;
      noteText.classList.add('swap');
    };
    const idleNote = () => (lk.again ? 'Try another tab, or MP3' : coarse ? 'Drag the address out' : 'Press the address and drag it out');
    const setState = (st, text) => {
      desk.dataset.state = st;
      setNote(text || {
        idle: idleNote(),
        selected: 'Now tap ⇧ below',
        dragging: coarse ? 'Now tap ⇧ below' : 'Now tap ⇧',
        open: lk.via === 'keyboard' ? 'Pick a format, then press Return' : 'Let go on MP4 or MP3',
      }[st] || noteText.textContent);
    };

    // ----- Tabs: one made-up post per site
    function setSite(key) {
      lk.site = key;
      const p = POSTS[key];
      urlEl.textContent = p.url;
      img.src = p.img;
      img.style.objectPosition = p.pos;
      durEl.textContent = p.dur;
      titleEl.textContent = p.title;
      metaEl.textContent = `${p.by} · a made-up post`;
      page.setAttribute('aria-labelledby', `lk-tab-${key}`);
      address.setAttribute('aria-label', `${p.url}, the address of ${p.title} on ${SITE[key]}`);
      if (wheel.isOpen) closeWheel({ returnFocus: false });
      address.classList.remove('selected');
      if (!lk.busy && !lk.drag) setState('idle');
    }
    tabs($('.br-tabs', desk), (t) => setSite(t.dataset.site));
    setSite('youtube');

    // ----- The wheel
    function openWheel(at, via) {
      const switching = wheel.isOpen;
      lk.via = via;
      const r0 = deskRect(), availH = r0.height - 84;   // keep the key free
      wheel.setScale(Math.min(1.12, (Math.min(r0.width, availH) - 24) / (2 * wheel.R)));
      const r = wheel.R * wheel.scale;
      lk.at = { x: clamp(at.x, r + 8, r0.width - r - 8), y: clamp(at.y, r + 8, Math.max(r + 8, availH - r)) };
      wheel.place(lk.at.x, lk.at.y);
      hideLine();
      if (switching) wheel.reopen(); else wheel.open();
      shiftBtn.classList.add('on');
      setState('open');
      if (via === 'keyboard') { wheel.el.focus({ preventScroll: true }); wheel.highlight(0); }
      else if (lk.drag && lk.drag.last) wheel.highlight(wheel.indexAt(lk.drag.last.x, lk.drag.last.y), { quiet: true });
      announce(live, `Convert wheel: MP4, MP3, M4A or WAV.${via === 'keyboard' ? ' Arrow keys to choose, Return to download, Escape to close.' : ''}`);
    }
    function closeWheel({ returnFocus = true } = {}) {
      if (!wheel.isOpen) return;
      const hadFocus = wheel.el.contains(document.activeElement) || document.activeElement === wheel.el;
      wheel.highlight(-1, { quiet: true });
      wheel.close();
      shiftBtn.classList.remove('on');
      if (hadFocus && returnFocus) address.focus({ preventScroll: true });
    }

    // ----- The dragged link (the browser's drag image): 1:1 with the pointer, springs home when let go elsewhere
    const chipPos = { x: new Spring(0, { response: 0.42, damping: 0.9, eps: 0.05 }), y: new Spring(0, { response: 0.42, damping: 0.9, eps: 0.05 }), token: 0 };
    const GRAB = { x: 23, y: 23 };   // the pointer sits on the chip's link icon
    const placeChip = () => { chip.style.transform = `translate(${f2(chipPos.x.x - GRAB.x)}px, ${f2(chipPos.y.x - GRAB.y)}px)`; };
    function showChip(at) {
      const p = post();
      chipTitle.textContent = p.title;
      chipURL.textContent = p.url;
      chipPos.token++;
      chip.getAnimations().forEach((a) => a.cancel());
      chipPos.x.snap(at.x); chipPos.y.snap(at.y);
      placeChip();
      chip.style.opacity = '';
      chip.hidden = false;
      if (!RM) chip.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 110, easing: 'ease-out' });
    }
    function returnChip(vel = { vx: 0, vy: 0 }) {
      const home = addressCenter(), token = ++chipPos.token;
      const done = () => { chip.hidden = true; chip.style.opacity = ''; address.classList.remove('selected'); };
      if (RM || chip.hidden) { done(); return; }
      chipPos.x.set(home.x, vel.vx); chipPos.y.set(home.y, vel.vy);
      loop.add((dt) => {
        if (token !== chipPos.token) return false;
        chipPos.x.step(dt); chipPos.y.step(dt);
        placeChip();
        // It melts back into the address it came from.
        const d = Math.hypot(chipPos.x.x - home.x, chipPos.y.x - home.y);
        chip.style.opacity = clamp(d / 50, 0, 1).toFixed(3);
        if (d < 1.5 || (chipPos.x.done && chipPos.y.done)) { done(); return false; }
      });
    }

    // ----- Dropping on a petal: the corner banner, then the file onto the line
    function apply(item) {
      const p = post();
      closeWheel({ returnFocus: false });
      chipPos.token++;
      if (RM || chip.hidden) chip.hidden = true;
      else chip.animate([{ opacity: 0.82 }, { opacity: 0 }], { duration: 160, easing: 'ease-out' }).onfinish = () => { chip.hidden = true; };
      address.classList.remove('selected');
      download(item, p, lk.site);
    }
    function download(item, p, site) {
      lk.busy = true;
      const name = `${p.title}.${item.fmt}`;
      hud.getAnimations().forEach((a) => a.cancel());
      hudText.textContent = `→ ${item.label}  ·  ${p.title}`;
      hudFill.style.transform = 'scaleX(0)';
      hud.hidden = false;
      if (!RM) hud.animate([{ opacity: 0, transform: 'translateY(-6px) scale(0.97)' }, { opacity: 1, transform: 'none' }], { duration: 220, easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)' });
      setState('downloading', `Downloading from ${SITE[site]}…`);
      announce(live, `Downloading ${name} from ${SITE[site]}.`);
      const D = 1.9;
      let t = 0, dropped = false;
      // Progress is status, not motion: it fills under Reduce Motion too.
      loop.add((dt) => {
        t += dt;
        const u = clamp(t / D, 0, 1);
        // A moment to connect, then quick, then the last part while the file is finished.
        const prog = u < 0.12 ? u * 0.25 : 0.03 + 0.97 * (1 - Math.pow(1 - (u - 0.12) / 0.88, 2.2));
        hudFill.style.transform = `scaleX(${prog.toFixed(4)})`;
        if (!dropped && u > 0.7) { dropped = true; showLine(); }
        if (u >= 1) { finish(item, p, name); return false; }
      });
    }
    function finish(item, p, name) {
      const card = makeCard({ name, kind: item.fmt === 'mp4' ? 'video' : 'audio', img: p.img, pos: p.pos, dur: p.dur });
      cards.unshift(card);
      ul.insertBefore(card.li, ul.firstChild);
      while (cards.length > 8) cards.pop().li.remove();
      layoutSlots(false);
      card.x.snap(slotX(0));
      const r = deskRect(), h = hud.getBoundingClientRect();
      if (!RM) card.flight = { t: 0, dur: 0.8, from: { x: h.left - r.left + h.width / 2, y: h.top - r.top + h.height / 2 } };
      kick();
      // The banner goes as the card leaves it.
      if (RM) hud.hidden = true;
      else hud.animate([{ opacity: 1 }, { opacity: 0, transform: 'scale(0.97)' }], { duration: 280, easing: 'ease-out', fill: 'forwards' })
        .onfinish = (ev) => { hud.hidden = true; ev.target.cancel(); };
      lk.busy = false;
      lk.again = true;
      setState('done', 'In Downloads, and on the line');
      announce(live, `${name} is saved in Downloads and hangs on the Clothesline.`);
      setTimeout(() => { if (desk.dataset.state === 'done') setState('idle'); }, 2600);
    }

    // ----- The Clothesline (as in the Clothesline section, without dragging cards)
    const G = {};
    const geom = () => {
      G.W = desk.clientWidth; G.cx = G.W / 2; G.top = 46; G.notchBottom = 32;
      // Wide enough for "Sunset drive.mp4"; a shallow sag keeps the cards clear of the browser below.
      G.sag = clamp(G.W * 0.022, 10, 24);
      G.cw = clamp(G.W * 0.1, 76, 112);
      G.pitch = G.cw + clamp(G.W * 0.02, 10, 18);
      G.start = clamp(G.W * 0.05, 18, 52) + G.cw / 2;
      desk.style.setProperty('--cw', `${G.cw}px`);
    };
    geom();
    const drop = new Spring(0, { response: 0.55, damping: 0.78 });
    const K = Math.pow(TAU / 1.15, 2), C = 4.5, PEND_L = 96, SOFT = 0.32, LIM = 0.6, WALL = 400, CALM_DRIVE = 0.35, LIVELY_MS = 900;
    let cards = [], out = false, running = false;
    const slotX = (i) => G.start + i * G.pitch;
    const layoutSlots = (snap) => cards.forEach((c, i) => { if (snap || RM) c.x.snap(slotX(i)); else c.x.set(slotX(i)); });
    const ends = (d) => {
      const dd = clamp(d, 0, 1);
      return { x0: G.cx - dd * (G.cx + 24), x1: G.cx + dd * (G.W - G.cx + 24), y: G.notchBottom - 8 + d * (G.top - G.notchBottom + 8), sag: G.sag * d };
    };
    const stringY = (x, d) => {
      const e = ends(d), half = (e.x1 - e.x0) / 2 || 1, u = clamp((x - G.cx) / half, -1, 1);
      return e.y + e.sag * (1 - u * u);
    };
    function makeCard(d) {
      const c = { ...d, theta: 0, omega: 0, ppx: null, pvx: 0, axs: 0, lively: 0,
        x: new Spring(0, { response: 0.32, damping: 1, eps: 0.05 }), yOff: new Spring(0, { response: 0.4, damping: 0.75, eps: 0.05 }) };
      const li = document.createElement('li'), el = document.createElement('div');
      el.className = 'card';
      el.innerHTML = `<span class="pin" aria-hidden="true"></span><span class="card-thumb" aria-hidden="true">${d.kind === 'video'
        ? `<img src="${d.img}" alt="" style="object-position:${d.pos}"><span class="dur">${d.dur}</span>` : '<span class="wave-mini"></span>'}</span><span class="card-name"></span>`;
      el.querySelector('.card-name').textContent = d.name;
      li.appendChild(el);
      c.li = li; c.el = el;
      return c;
    }
    function render(dt) {
      const d = RM ? (out ? 1 : 0) : drop.x, dd = clamp(d, 0, 1), e = ends(RM ? 1 : d);
      const pathD = `M${f2(e.x0)} ${f2(e.y)}Q${f2(G.cx)} ${f2(e.y + 2 * e.sag)} ${f2(e.x1)} ${f2(e.y)}`;
      stringPath.setAttribute('d', pathD);
      glowPath.setAttribute('d', pathD);
      const vis = RM ? (out ? 1 : 0) : dd;
      stringPath.style.opacity = vis > 0.01 ? 1 : 0;
      glowPath.style.opacity = vis > 0.01 ? 0.75 : 0;
      cards.forEach((c) => {
        let pinX, pinY;
        if (c.flight) { pinX = c.fx; pinY = c.fy; }
        else { pinX = RM ? c.x.x : G.cx + (c.x.x - G.cx) * dd; pinY = stringY(pinX, RM ? 1 : d) + c.yOff.x; }
        // A damped pendulum driven by its pin's acceleration: the card lags, then swings back.
        if (c.flight) { c.theta = 0.3 * (1 - c.flight.t); c.omega = 0; c.ppx = pinX; c.pvx = 0; }
        else if (!RM && dt > 0) {
          if (c.ppx === null) { c.ppx = pinX; c.pvx = 0; c.axs = 0; }
          const vx = (pinX - c.ppx) / dt, raw = clamp((vx - c.pvx) / dt, -6000, 6000);
          c.axs += (raw - c.axs) * Math.min(1, dt * 25);
          c.ppx = pinX; c.pvx = vx;
          const drive = c.lively > performance.now() ? 1 : CALM_DRIVE;
          let t = dt;
          while (t > 1e-6) {
            const h = Math.min(t, 1 / 240);
            let acc = -K * Math.sin(c.theta) - C * c.omega + drive * (c.axs / PEND_L) * Math.cos(c.theta);
            const over = Math.abs(c.theta) - SOFT;
            if (over > 0) acc -= Math.sign(c.theta) * WALL * over;
            c.omega += acc * h;
            c.theta += c.omega * h;
            if (Math.abs(c.theta) > LIM) { c.theta = Math.sign(c.theta) * LIM; if (Math.sign(c.omega) === Math.sign(c.theta)) c.omega = 0; }
            t -= h;
          }
        } else { c.theta = 0; c.omega = 0; }
        const sc = RM || c.flight ? 1 : 0.4 + 0.6 * dd;
        const op = c.flight ? 1 : RM ? (out ? 1 : 0) : clamp(dd * 2.4 - 0.2, 0, 1);
        c.el.style.transform = `translate(${f2(pinX - G.cw / 2)}px, ${f2(pinY + 2)}px) rotate(${(c.theta * 57.2958).toFixed(2)}deg) scale(${sc.toFixed(3)})`;
        c.el.style.opacity = op.toFixed(3);
      });
    }
    // The new file flies along an arc from the banner, and the pin catches it.
    function stepFlight(c, dt) {
      const f = c.flight;
      f.t = Math.min(f.t + dt / f.dur, 1);
      const t = 1 - Math.pow(1 - f.t, 3);
      const sx0 = slotX(0), target = { x: G.cx + (sx0 - G.cx) * clamp(drop.x, 0, 1), y: stringY(sx0, drop.x) };
      // It swoops down across the wall and up into the pin, all of it in view under the menu bar.
      const cx = (f.from.x + target.x) / 2, cy = Math.max(f.from.y, target.y) + 130;
      c.fx = (1 - t) * (1 - t) * f.from.x + 2 * (1 - t) * t * cx + t * t * target.x;
      c.fy = (1 - t) * (1 - t) * f.from.y + 2 * (1 - t) * t * cy + t * t * target.y;
      if (f.t >= 1) { c.flight = null; c.yOff.snap(c.fy - stringY(c.fx, drop.x)); c.yOff.set(0); c.omega = 2; c.lively = performance.now() + LIVELY_MS; }
    }
    const settled = () => drop.done && cards.every((c) => c.x.done && c.yOff.done && Math.abs(c.theta) < 0.002 && Math.abs(c.omega) < 0.02 && !c.flight);
    const task = (dt) => {
      drop.step(dt);
      cards.forEach((c) => {
        if (RM) { c.x.snap(c.x.target); c.yOff.snap(c.yOff.target); } else { c.x.step(dt); c.yOff.step(dt); }
        if (c.flight) stepFlight(c, dt);
      });
      render(dt);
      if (settled()) { running = false; return false; }
    };
    const kick = () => { if (!running) { running = true; cards.forEach((c) => { c.ppx = null; }); loop.add(task); } };
    function showLine() {
      if (out) return;
      out = true;
      desk.classList.add('line-out');
      notch.setAttribute('aria-expanded', 'true');
      notch.querySelector('.visually-hidden').textContent = 'Put the Clothesline away';
      ul.removeAttribute('aria-hidden');
      if (RM) { drop.snap(1); render(0); } else { drop.damping = 0.78; drop.set(1, drop.x < 0.05 ? 0.6 : undefined); kick(); }
    }
    function hideLine() {
      if (!out || cards.some((c) => c.flight)) return;
      out = false;
      desk.classList.remove('line-out');
      notch.setAttribute('aria-expanded', 'false');
      notch.querySelector('.visually-hidden').textContent = 'Show the Clothesline';
      ul.setAttribute('aria-hidden', 'true');
      if (RM) { drop.snap(0); render(0); } else { drop.damping = 1; drop.set(0); kick(); }
    }
    notch.addEventListener('click', () => {
      if (out) { hideLine(); return; }
      showLine();
      announce(live, cards.length ? `The Clothesline is out with ${cards.length} ${cards.length === 1 ? 'file' : 'files'}.` : 'The Clothesline is out. Downloads hang here.');
    });
    render(0);

    // ----- Pointer: press the address (it is selected at once), drag 6 px and the link comes along
    address.addEventListener('pointerdown', (e) => {
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      if (lk.drag || lk.busy) return;
      e.preventDefault();
      address.focus({ preventScroll: true });
      if (wheel.isOpen) closeWheel({ returnFocus: false });
      address.classList.add('selected');
      capture(address, e.pointerId);
      lk.drag = { id: e.pointerId, sx: e.clientX, sy: e.clientY, started: false, hist: [], held: e.shiftKey, last: { x: e.clientX, y: e.clientY } };
    });
    address.addEventListener('pointermove', (e) => {
      const d = lk.drag;
      if (!d || d.id !== e.pointerId) return;
      d.last = { x: e.clientX, y: e.clientY };
      const at = toDesk(e.clientX, e.clientY);
      if (!d.started) {
        if (Math.hypot(e.clientX - d.sx, e.clientY - d.sy) < 6) return;
        d.started = true;
        hideLine();
        showChip(at);
        setState('dragging');
        if (d.held || e.shiftKey) openWheel(at, 'pointer');
      }
      chipPos.x.snap(at.x); chipPos.y.snap(at.y);
      placeChip();
      pushHist(d.hist, e.clientX, e.clientY);
      if (wheel.isOpen) wheel.highlight(wheel.indexAt(e.clientX, e.clientY));
    });
    const endDrag = (e, cancelled) => {
      const d = lk.drag;
      if (!d || d.id !== e.pointerId) return;
      lk.drag = null;
      if (!d.started) { if (!wheel.isOpen) setState('selected'); return; }
      if (!cancelled && wheel.isOpen && wheel.hl >= 0) { apply(wheel.items[wheel.hl]); return; }
      if (wheel.isOpen) closeWheel({ returnFocus: false });
      returnChip(velocityOf(d.hist));
      setState('idle');
    };
    address.addEventListener('pointerup', (e) => endDrag(e, false));
    address.addEventListener('pointercancel', (e) => endDrag(e, true));
    address.addEventListener('contextmenu', (e) => e.preventDefault());

    // ----- The ⇧ key on the page: a second finger can tap it mid-drag; otherwise it opens the wheel on the address
    shiftBtn.addEventListener('pointerdown', (e) => {
      shiftBtn.classList.add('pressed');
      if (lk.drag && lk.drag.started && e.pointerId !== lk.drag.id) {
        e.preventDefault();
        if (!wheel.isOpen) openWheel(toDesk(lk.drag.last.x, lk.drag.last.y), 'pointer');
        shiftBtn.dataset.skipClick = '1';
      }
    });
    const unpress = () => shiftBtn.classList.remove('pressed');
    ['pointerup', 'pointerleave', 'pointercancel'].forEach((t) => shiftBtn.addEventListener(t, unpress));
    shiftBtn.addEventListener('click', (e) => {
      if (shiftBtn.dataset.skipClick) { delete shiftBtn.dataset.skipClick; return; }
      if (lk.busy || lk.drag) return;
      if (wheel.isOpen) { closeWheel(); address.classList.remove('selected'); setState('idle'); return; }
      address.classList.add('selected');
      openWheel(addressCenter(), e.detail === 0 ? 'keyboard' : 'tap');
    });

    // ----- Tapping a petal (no drag): highlight on press, download on release over the same petal
    wheel.el.addEventListener('pointerdown', (e) => {
      if (lk.drag) return;
      wheel.highlight(wheel.indexAt(e.clientX, e.clientY));
      capture(wheel.el, e.pointerId);
      wheel.el.dataset.press = '1';
    });
    wheel.el.addEventListener('pointermove', (e) => {
      if (lk.drag) return;
      if (e.pointerType === 'mouse' || wheel.el.dataset.press) wheel.highlight(wheel.indexAt(e.clientX, e.clientY));
    });
    wheel.el.addEventListener('pointerup', (e) => {
      if (lk.drag || !wheel.el.dataset.press) return;
      delete wheel.el.dataset.press;
      const i = wheel.indexAt(e.clientX, e.clientY);
      if (i >= 0) { apply(wheel.items[i]); return; }
      const r = deskRect();
      if (Math.hypot(e.clientX - (r.left + wheel.cx), e.clientY - (r.top + wheel.cy)) > wheel.R * wheel.scale) {
        closeWheel(); address.classList.remove('selected'); setState('idle');
      }
    });
    desk.addEventListener('pointerdown', (e) => {
      // A press anywhere else closes the wheel and lets go of the address, as in the app and a browser.
      if (lk.drag || e.target.closest('.br-address, .keybar, .wheel, .notch')) return;
      if (wheel.isOpen) closeWheel({ returnFocus: false });
      address.classList.remove('selected');
      if (!lk.busy && desk.dataset.state !== 'done') setState('idle');
    });

    // ----- Keyboard: Return or a lone ⇧ on the address opens the wheel; ⇧ mid-drag too; ⌘ and ⌥ say why not
    address.addEventListener('keydown', (e) => {
      if ((e.key === 'Enter' || e.key === ' ') && !wheel.isOpen && !lk.busy) {
        e.preventDefault();
        address.classList.add('selected');
        openWheel(addressCenter(), 'keyboard');
      }
    });
    wheel.el.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowRight' || e.key === 'ArrowDown') { e.preventDefault(); wheel.step(1); }
      else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') { e.preventDefault(); wheel.step(-1); }
      else if (e.key === 'Home') { e.preventDefault(); wheel.highlight(0); }
      else if (e.key === 'End') { e.preventDefault(); wheel.highlight(wheel.items.length - 1); }
      else if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        if (wheel.hl >= 0) { const item = wheel.items[wheel.hl]; address.focus({ preventScroll: true }); apply(item); }
      } else if (e.key === 'Tab') { closeWheel({ returnFocus: false }); address.classList.remove('selected'); setState('idle'); }
    });
    const ours = () => (lk.drag && lk.drag.started) || desk.contains(document.activeElement);
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') {
        if (wheel.isOpen && ours()) { e.preventDefault(); closeWheel(); setState(lk.drag && lk.drag.started ? 'dragging' : 'idle'); if (!lk.drag) address.classList.remove('selected'); return; }
        if (lk.drag && lk.drag.started) {
          const d = lk.drag;
          lk.drag = null;
          try { address.releasePointerCapture(d.id); } catch (_) { /* already released */ }
          returnChip();
          setState('idle');
        }
        return;
      }
      if (e.repeat) { lk.pending = 0; return; }
      if (e.key === 'Shift') {
        if (lk.drag && lk.drag.started) { if (!wheel.isOpen) openWheel(toDesk(lk.drag.last.x, lk.drag.last.y), 'pointer'); return; }
        lk.pending = document.activeElement === address && !wheel.isOpen && !lk.busy ? performance.now() : 0;
        return;
      }
      lk.pending = 0;
      if ((e.key === 'Meta' || e.key === 'Alt' || e.key === 'Control') && ((lk.drag && lk.drag.started) || document.activeElement === address || (wheel.isOpen && ours()))) {
        if (e.key === 'Alt') e.preventDefault();
        setNote('A link only has the ⇧ wheel');
        announce(live, 'A link has only the Shift wheel, Convert.');
      }
    });
    document.addEventListener('keyup', (e) => {
      const t = lk.pending;
      lk.pending = 0;
      if (e.key !== 'Shift' || !t || performance.now() - t > 800 || document.activeElement !== address) return;
      address.classList.add('selected');
      openWheel(addressCenter(), 'keyboard');
    });

    // The note's arrow draws itself when the desk comes into view.
    const noteObs = new IntersectionObserver((entries) => {
      entries.forEach((en) => { if (en.isIntersecting) { note.classList.add('drawn'); noteObs.disconnect(); } });
    }, { threshold: 0.5 });
    noteObs.observe(note);
    new ResizeObserver(() => {
      geom(); layoutSlots(true); render(0);
      if (wheel.isOpen && !lk.drag) { closeWheel({ returnFocus: false }); setState('idle'); }
      if (running) kick();
    }).observe(desk);
  }

  // The editor windows live in js/editors.js

  // ---------- The Clothesline loop (rendered by the app) ----------
  const video = $('#line-video');
  if (video) {
    const btn = $('#line-video-toggle');
    let userPaused = RM, visible = false, loaded = false;
    const setBtn = () => {
      const playing = !video.paused;
      btn.querySelector('span').textContent = playing ? 'Pause' : 'Play';
      btn.querySelector('use').setAttribute('href', playing ? '#i-pause' : '#i-play');
    };
    const load = () => {
      if (loaded) return;
      loaded = true;
      const dark = mqDark.matches;
      if (dark) video.poster = video.dataset.darkPoster;
      video.src = dark ? video.dataset.darkSrc : video.dataset.src;
    };
    if (mqDark.matches) video.poster = video.dataset.darkPoster;
    const sync = () => {
      if (visible && !userPaused) { load(); video.play().catch(() => {}); }
      else video.pause();
    };
    video.addEventListener('play', setBtn);
    video.addEventListener('pause', setBtn);
    btn.addEventListener('click', () => {
      userPaused = !video.paused;
      if (!userPaused) { load(); video.play().catch(() => {}); } else video.pause();
    });
    new IntersectionObserver((en) => { visible = en[0].isIntersecting; sync(); }, { threshold: 0.4 }).observe(video);
    setBtn();
  }
})();
