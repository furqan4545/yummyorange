/* YummyOrange website: the editor windows. Small working copies of the app's Split, Trim, Crop and Edit PDF windows,
   dark like the app in both appearances. Nothing leaves the page: Save only shows what the app writes beside the
   original. Drags track the pointer 1:1 from where it was grabbed, rubber-band at their limits and settle on a
   critically damped spring that starts from the value on screen, so a grab mid-flight just takes over
   (apple-motion §2, §3, §9). Reduce Motion drops the springs and the preview's drift. */
(() => {
  'use strict';
  const tabList = document.getElementById('ed-tabs');
  const stage = document.getElementById('ed-stage');
  const copyEl = document.getElementById('ed-copy');
  const panel = document.getElementById('ed-panel');
  if (!tabList || !stage || !copyEl || !panel) return;

  // ---------- Helpers ----------
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const clamp = (x, a, b) => Math.min(Math.max(x, a), b);
  const mqRM = matchMedia('(prefers-reduced-motion: reduce)');
  const RM = () => mqRM.matches;
  const MAC = /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent);
  const CMD = MAC ? '⌘' : 'Ctrl+';
  const capture = (el, id) => { try { el.setPointerCapture(id); } catch (_) { /* the pointer is already gone */ } };
  const fmt = (t) => { t = Math.max(0, t); const m = Math.floor(t / 60); return `${m}:${(t - m * 60).toFixed(2).padStart(5, '0')}`; };
  const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
  // Past a limit the value follows less and less, never more than `dim` beyond it (apple-motion §9)
  const rubber = (over, dim) => (over * dim * 0.55) / (dim + 0.55 * Math.abs(over));
  const band = (v, lo, hi, dim) => (v < lo ? lo - rubber(lo - v, dim) : v > hi ? hi + rubber(v - hi, dim) : v);

  // A spring from the value on screen to `to`, carrying the release velocity (apple-motion §4, §5). Damping 1: no bounce.
  function spring(from, to, v0, step, done, opt = {}) {
    if (RM()) { step(to); if (done) done(); return () => {}; }
    const response = opt.response || 0.35, k = (2 * Math.PI / response) ** 2, c = (4 * Math.PI) / response;
    const eps = opt.eps || 1e-3;
    let x = from, v = v0 || 0, last = performance.now(), id = 0;
    const tick = (now) => {
      let dt = Math.min((now - last) / 1000, 1 / 20);
      last = now;
      while (dt > 1e-6) { const h = Math.min(dt, 1 / 240); v += (-k * (x - to) - c * v) * h; x += v * h; dt -= h; }
      if (Math.abs(x - to) < eps && Math.abs(v) < eps * 20) { id = 0; step(to); if (done) done(); return; }
      step(x);
      id = requestAnimationFrame(tick);
    };
    id = requestAnimationFrame(tick);
    return () => { if (id) cancelAnimationFrame(id); id = 0; };
  }
  // Velocity over the last ~100 ms of a drag, for the hand-off to the spring
  function tracker() {
    let s = [];
    return {
      add(v) { const t = performance.now(); s.push([t, v]); while (s.length > 2 && t - s[0][0] > 100) s.shift(); },
      vel() { if (s.length < 2) return 0; const a = s[0], b = s[s.length - 1], dt = (b[0] - a[0]) / 1000; return dt > 0.008 ? (b[1] - a[1]) / dt : 0; },
    };
  }

  const svg = (d) => `<svg class="edw-ic" viewBox="0 0 16 16" aria-hidden="true" focusable="false">${d}</svg>`;
  const I = {
    play: svg('<path d="M5 3.2v9.6L12.8 8z" fill="currentColor" stroke="none"/>'),
    pause: svg('<path d="M5.5 3.5v9M10.5 3.5v9" stroke-width="2.2"/>'),
    split: svg('<circle cx="4" cy="4.5" r="2"/><circle cx="4" cy="11.5" r="2"/><path d="M5.7 5.6 14 12M5.7 10.4 14 4"/>'),
    evenly: svg('<path d="M1.5 3.5h13v9h-13zM5.8 3.5v9M10.2 3.5v9"/>'),
    trash: svg('<path d="M2.5 4.5h11M6 4.5V2.8h4v1.7M4 4.5l.7 9h6.6l.7-9"/>'),
    undo: svg('<path d="M5.5 3.5 2.5 6.5l3 3M2.5 6.5H10a3.5 3.5 0 0 1 0 7H8"/>'),
    chev: '<svg class="edw-chev" viewBox="0 0 10 10" aria-hidden="true" focusable="false"><path d="M2.5 4 5 6.5 7.5 4"/></svg>',
    updown: '<svg class="edw-chev" viewBox="0 0 10 14" aria-hidden="true" focusable="false"><path d="M2.5 5 5 2.5 7.5 5M2.5 9 5 11.5 7.5 9"/></svg>',
  };

  // ---------- The window: title bar, Undo, Save and the sheet that says what Save wrote ----------
  function shell(o) {
    return `<div class="edw" data-tool="${o.id}">
      <div class="edw-bar">
        <div class="edw-lead"><span class="edw-lights" aria-hidden="true"><i></i><i></i><i></i></span>
          <div class="edw-title"><b>${o.file}</b><span>${o.tool}</span></div></div>
        <div class="edw-tools">${o.tools}</div>
        <div class="edw-end">${o.end || ''}
          <button type="button" class="edw-btn" data-act="undo" aria-label="Undo" title="Undo (${CMD}Z)" disabled>${I.undo}</button>
          <button type="button" class="edw-save" data-act="save">Save</button>
        </div>
      </div>
      <div class="edw-body">${o.body}
        <div class="edw-scrim" hidden></div>
        <div class="edw-sheet" role="dialog" aria-label="Saved" hidden>
          <p class="edw-sheet-h">Saved next to ${o.file}</p>
          <ul class="edw-files"></ul>
          <div class="edw-sheet-end"><button type="button" class="edw-save" data-act="done">Done</button></div>
        </div>
      </div>
      ${o.foot ? `<div class="edw-foot">${o.foot}</div>` : ''}
      <p class="visually-hidden" aria-live="polite" data-live></p>
    </div>`;
  }

  const editingText = (el) => !!el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName));

  function base(win, o) {
    const ac = new AbortController();
    const on = (el, ev, fn, opt) => el.addEventListener(ev, fn, { ...opt, signal: ac.signal });
    const live = $('[data-live]', win), undoBtn = $('.edw-bar [data-act="undo"]', win), saveBtn = $('.edw-bar [data-act="save"]', win);
    const sheet = $('.edw-sheet', win), scrim = $('.edw-scrim', win), list = $('.edw-files', win), done = $('[data-act="done"]', win);
    const stack = [];
    let open = false, sayT = 0, hideT = 0;
    const ed = {
      on, ac, win,
      say(text) { clearTimeout(sayT); live.textContent = ''; sayT = setTimeout(() => { live.textContent = text; }, 40); },
      push(snap) { stack.push(snap); if (stack.length > 80) stack.shift(); undoBtn.disabled = false; },
      undo() { if (!stack.length || open) return; o.restore(stack.pop()); undoBtn.disabled = !stack.length; ed.say('Undone.'); },
      canSave(v) { saveBtn.disabled = !v; },
      open(rows) {
        const shown = rows.length > 6 ? rows.slice(0, 5) : rows;
        list.innerHTML = shown.map((r) => `<li><span class="edw-doc" aria-hidden="true">${r.ext}</span><span class="edw-fn">${r.name}</span><span class="edw-fm">${r.meta || ''}</span></li>`).join('')
          + (shown.length < rows.length ? `<li class="edw-more">and ${rows.length - shown.length} more</li>` : '');
        open = true; clearTimeout(hideT);
        scrim.hidden = false; sheet.hidden = false;
        void sheet.offsetWidth;
        win.classList.add('sheet-on');
        done.focus({ preventScroll: true });
        ed.say(`Saved ${rows.map((r) => r.name).join(', ')}, next to ${o.file}.`);
      },
      close() {
        if (!open) return;
        open = false;
        win.classList.remove('sheet-on');
        hideT = setTimeout(() => { sheet.hidden = true; scrim.hidden = true; }, RM() ? 0 : 320);
        saveBtn.focus({ preventScroll: true });
      },
      get isOpen() { return open; },
    };
    on(win, 'click', (e) => {
      const b = e.target.closest('[data-act]');
      if (!b || b.disabled) return;
      const a = b.dataset.act;
      if (a === 'undo') ed.undo();
      else if (a === 'save') o.save();
      else if (a === 'done') ed.close();
      else if (o.act) o.act(a, b);
      setTimeout(keepFocus, 0);
    });
    // Keep focus in the window, so ⌘Z and ⌘B keep working after a click: a button that just turned itself off (Reset,
    // Remove Split, Undo) drops focus, and Safari doesn't focus the buttons it clicks.
    function keepFocus() {
      const f = document.activeElement;
      if (open || !o.home || (win.contains(f) && !f.disabled)) return;
      const h = o.home();
      if (h) h.focus({ preventScroll: true });
    }
    on(win, 'pointerup', () => setTimeout(keepFocus, 0));
    on(scrim, 'pointerdown', () => ed.close());
    on(win, 'keydown', (e) => {
      if (open) { if (e.key === 'Escape') { e.preventDefault(); ed.close(); } return; }
      const mod = MAC ? e.metaKey : e.ctrlKey;
      if (mod && !e.altKey && !e.shiftKey && e.key.toLowerCase() === 'z' && !editingText(e.target)) { e.preventDefault(); ed.undo(); return; }
      if (o.key) o.key(e, mod);
    });
    return ed;
  }

  // ---------- Video editors (Split, Trim): the picture, the transport and a timeline of film strip and waveform ----------
  const D = 12, P = 14, FPS = 30;
  const snapT = (t) => Math.round(t * FPS) / FPS;
  // Limits moved in to whole frames, so a value snapped to a frame never lands past one
  const inward = (lo, hi) => [Math.ceil(lo * FPS - 1e-6) / FPS, Math.floor(hi * FPS + 1e-6) / FPS];
  const waveURL = (() => {
    const cache = {};
    return (color) => {
      if (cache[color]) return cache[color];
      const N = 240, top = [];
      for (let i = 0; i <= N; i++) {
        const u = i / N;
        const a = 0.5 + 0.2 * Math.sin(u * 41) * Math.sin(u * 6.1 + 1) + 0.14 * Math.sin(u * 97 + 2) + 0.07 * Math.sin(u * 251);
        top.push([i, 20 - clamp(a, 0.14, 0.92) * 19]);
      }
      const d = `M${top.map((p) => `${p[0]} ${p[1].toFixed(2)}`).join('L')}L${top.slice().reverse().map((p) => `${p[0]} ${(40 - p[1]).toFixed(2)}`).join('L')}Z`;
      const s = `<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 ${N} 40' preserveAspectRatio='none'><path d='${d}' fill='${color}'/></svg>`;
      return (cache[color] = `url("data:image/svg+xml,${encodeURIComponent(s)}")`);
    };
  })();

  function media(host, spec) {
    host.innerHTML = shell({
      id: spec.id, file: 'sunset.mp4', tool: spec.tool, tools: spec.tools,
      body: `<div class="edw-view"><div class="edw-frame"><img src="assets/sunset.webp" alt="" width="480" height="300" draggable="false"><span class="edw-badge" hidden></span></div></div>
        <div class="edw-ctl">
          <button type="button" class="edw-btn edw-play" data-act="play" aria-label="Play">${I.play}</button>
          <span class="edw-time"><b data-now>0:00.00</b> / ${fmt(D)}</span>
          <span class="edw-info" data-info></span>
        </div>
        <div class="edw-tl">
          <div class="edw-ruler" aria-hidden="true"></div>
          <div class="edw-track">${spec.track}</div>
          ${spec.extra || ''}
          <div class="edw-ph" role="slider" tabindex="0" aria-label="Playhead" aria-valuemin="0" aria-valuemax="${D}"><i></i></div>
        </div>`,
    });
    const win = host.firstElementChild;
    const tl = $('.edw-tl', win), ruler = $('.edw-ruler', win), ph = $('.edw-ph', win), nowEl = $('[data-now]', win);
    const playBtn = $('[data-act="play"]', win), frame = $('.edw-frame', win), img = $('img', frame);
    let W = 0, t = spec.start || 0, playing = false, raf = 0, last = 0, labels = [];
    const m = {
      win, tl, ph, frame, info: $('[data-info]', win), badge: $('.edw-badge', win),
      get W() { return W; }, get t() { return t; }, get playing() { return playing; },
      X: (s) => P + (s / D) * (W - 2 * P),
      T: (x) => ((x - P) / (W - 2 * P)) * D,
      k: () => (W - 2 * P) / D,
      setT, stop, toggle: () => (playing ? stop() : play()),
    };
    m.ed = base(win, {
      file: 'sunset.mp4', save: spec.save, restore: spec.restore,
      act: (a, b) => { if (a === 'play') m.toggle(); else spec.act(a, b); },
      key: spec.key,
      home: () => ph,
    });

    function drawRuler() {
      const step = W < 560 ? 2 : 1;
      let h = '';
      for (let i = 0; i <= D * 2; i++) {
        const s = i / 2, major = Number.isInteger(s) && s % step === 0;
        h += `<i${major ? ' class="M"' : ''} style="left:${m.X(s).toFixed(1)}px"></i>`;
        if (major && s < D) h += `<span style="left:${m.X(s).toFixed(1)}px">0:${String(s).padStart(2, '0')}</span>`;
      }
      ruler.innerHTML = h;
      labels = $$('span', ruler).map((el) => [el, parseFloat(el.style.left)]);
    }
    // The knob is 12 px wide on the tick; the label starts 4 px right of its tick and is about 28 px long
    const clearLabels = (x) => labels.forEach(([el, lx]) => el.classList.toggle('under', x > lx - 4 && x < lx + 34));
    function setT(v) {
      t = clamp(v, 0, D);
      ph.style.transform = `translateX(${m.X(t).toFixed(1)}px)`;
      clearLabels(m.X(t));
      nowEl.textContent = fmt(t);
      ph.setAttribute('aria-valuenow', t.toFixed(2));
      ph.setAttribute('aria-valuetext', fmt(t));
      // The "video": a slow drift across the picture, so each moment has its own frame (none with Reduce Motion)
      img.style.transform = RM() ? '' : `scale(1.12) translate(${((0.5 - t / D) * 7).toFixed(2)}%, ${((t / D - 0.5) * 2.5).toFixed(2)}%)`;
      if (spec.onTime) spec.onTime(t);
    }
    function setPlayBtn() {
      playBtn.innerHTML = playing ? I.pause : I.play;
      playBtn.setAttribute('aria-label', playing ? 'Pause' : 'Play');
    }
    function stop() { if (!playing) return; playing = false; cancelAnimationFrame(raf); setPlayBtn(); }
    function play() {
      const [a, b] = spec.range();
      if (t < a - 1e-3 || t >= b - 0.02) setT(a);
      playing = true; last = performance.now(); setPlayBtn();
      const loop = (now) => {
        if (!playing) return;
        const end = spec.range()[1], nt = t + (now - last) / 1000;
        last = now;
        if (nt >= end) { setT(end); stop(); return; }
        setT(nt);
        raf = requestAnimationFrame(loop);
      };
      raf = requestAnimationFrame(loop);
    }

    // Scrub: press anywhere on the ruler or the strip and the playhead is there at once, then follows 1:1.
    // On the playhead itself it keeps the offset from where it was grabbed. A finger first has to move sideways
    // (or tap), so a vertical swipe over the timeline still scrolls the page and leaves the playhead alone.
    m.ed.on(tl, 'pointerdown', (e) => {
      if (e.button > 0 || e.target.closest('.edw-cut, .edw-th')) return;
      e.preventDefault();
      const left = () => tl.getBoundingClientRect().left;
      const off = e.target.closest('.edw-ph') ? e.clientX - left() - m.X(t) : 0;
      const x0 = e.clientX, y0 = e.clientY;
      let live = false;
      const go = (x) => setT(snapT(m.T(x - left() - off)));
      const begin = () => { live = true; stop(); ph.focus({ preventScroll: true }); if (spec.onScrub) spec.onScrub(); };
      if (e.pointerType !== 'touch') { begin(); go(x0); }
      capture(tl, e.pointerId);
      const move = (ev) => {
        if (!live) {
          const dx = Math.abs(ev.clientX - x0);
          if (dx < 8 || dx < Math.abs(ev.clientY - y0)) return;
          begin();
        }
        go(ev.clientX);
      };
      const up = (ev) => {
        if (!live && ev.type === 'pointerup' && Math.hypot(ev.clientX - x0, ev.clientY - y0) < 10) { begin(); go(ev.clientX); }
        tl.removeEventListener('pointermove', move); tl.removeEventListener('pointerup', up); tl.removeEventListener('pointercancel', up);
      };
      tl.addEventListener('pointermove', move);
      tl.addEventListener('pointerup', up);
      tl.addEventListener('pointercancel', up);
    });
    m.ed.on(ph, 'keydown', (e) => {
      const step = e.shiftKey ? 1 : 0.1;
      let v = null;
      if (e.key === 'ArrowRight' || e.key === 'ArrowUp') v = t + step;
      else if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') v = t - step;
      else if (e.key === 'Home') v = 0;
      else if (e.key === 'End') v = D;
      else if (e.key === ' ') { e.preventDefault(); m.toggle(); return; }
      if (v !== null) { e.preventDefault(); stop(); setT(snapT(v)); }
    });

    const ro = new ResizeObserver(() => {
      if (!tl.clientWidth) return;
      W = tl.clientWidth;
      drawRuler();
      setT(t);
      spec.layout();
    });
    ro.observe(tl);
    // Playback stops when the window scrolls out of view
    const io = new IntersectionObserver((en) => { if (!en[0].isIntersecting) stop(); });
    io.observe(win);
    m.destroy = () => { stop(); ro.disconnect(); io.disconnect(); m.ed.ac.abort(); };
    return m;
  }

  // Shared by the split and trim handles: drag 1:1 from the grab point between lo and hi, rubber-band past them,
  // then settle on the nearest allowed value with the release velocity.
  function dragValue(m, e, el, o) {
    e.preventDefault();
    e.stopPropagation();
    el.focus({ preventScroll: true });
    capture(el, e.pointerId);
    el.classList.add('drag');
    const x0 = e.clientX, s0 = o.shown(), k = m.k(), vt = tracker();
    let moved = false;
    vt.add(s0);
    const move = (ev) => {
      const raw = s0 + (ev.clientX - x0) / k, shown = band(raw, o.lo, o.hi, o.dim);
      moved = moved || ev.clientX !== x0;
      vt.add(shown); // the velocity of what's on screen, so a release past a limit doesn't fling it further out
      o.set(snapT(clamp(raw, o.lo, o.hi)), shown);
    };
    const up = () => {
      el.removeEventListener('pointermove', move);
      el.removeEventListener('pointerup', up);
      el.removeEventListener('pointercancel', up);
      el.classList.remove('drag');
      o.end(moved, vt.vel());
    };
    el.addEventListener('pointermove', move);
    el.addEventListener('pointerup', up);
    el.addEventListener('pointercancel', up);
  }

  // ---------- Split ----------
  function buildSplit(host) {
    const MIN = 0.25, MAXPARTS = 20;
    let cuts = [4, 8.4], shown = cuts.slice(), sel = -1, warnT = 0;
    const springs = [];
    let partsEl = null, cutsEl = null, removeBtn = null;
    const stopSprings = () => { springs.forEach((c) => c && c()); springs.length = 0; };

    const m = media(host, {
      id: 'split', tool: 'Split', start: 6,
      tools: `<button type="button" class="edw-btn" data-act="split" aria-label="Split at Playhead" title="Split at Playhead (${CMD}B)">${I.split}</button>
        <span class="edw-pop" title="Split Evenly">${I.evenly}${I.chev}<select aria-label="Split Evenly" data-evenly>
          <option value="" selected disabled hidden>Split Evenly</option>
          <option value="2">2 Equal Parts</option><option value="3">3 Equal Parts</option><option value="4">4 Equal Parts</option><option value="5">5 Equal Parts</option>
          <option value="0">Remove All Splits</option></select></span>
        <button type="button" class="edw-btn" data-act="remove" aria-label="Remove Split" title="Remove Selected Split (⌫)" disabled>${I.trash}</button>`,
      track: '<div class="edw-parts"></div>',
      extra: '<div class="edw-cuts"></div>',
      range: () => [0, D],
      layout: render,
      onTime: badge,
      onScrub: () => { if (sel >= 0) { sel = -1; render(); } },
      act: (a) => { if (a === 'split') addSplit(); else if (a === 'remove') removeSplit(sel); },
      key: (e, mod) => {
        if (mod && e.key.toLowerCase() === 'b') { e.preventDefault(); addSplit(); }
      },
      restore: (s) => { stopSprings(); cuts = s.slice(); shown = cuts.slice(); sel = -1; render(); },
      save: () => {
        m.stop();
        const pts = [0, ...cuts, D];
        m.ed.open(pts.slice(1).map((b, i) => ({ ext: 'MP4', name: `sunset part ${i + 1}.mp4`, meta: `${(b - pts[i]).toFixed(2)} s` })));
      },
    });
    partsEl = $('.edw-parts', m.win);
    cutsEl = $('.edw-cuts', m.win);
    removeBtn = $('[data-act="remove"]', m.win);
    m.tl.style.setProperty('--wave', waveURL('#8E8E93'));

    function badge(t) {
      if (!partsEl) return;
      const n = cuts.length + 1;
      m.badge.hidden = n < 2;
      if (n > 1) m.badge.textContent = `Part ${cuts.filter((c) => c <= t + 1e-6).length + 1} of ${n}`;
    }
    function info() {
      if (warnT) return;
      const pts = [0, ...cuts, D];
      let min = D;
      for (let i = 1; i < pts.length; i++) min = Math.min(min, pts[i] - pts[i - 1]);
      m.info.textContent = cuts.length ? `${cuts.length + 1} parts · shortest ${min.toFixed(2)} s` : 'No splits yet';
      m.ed.canSave(cuts.length > 0);
      removeBtn.disabled = sel < 0;
    }
    function warn(msg) {
      clearTimeout(warnT);
      m.info.textContent = msg;
      m.info.classList.add('warn');
      m.ed.say(msg);
      warnT = setTimeout(() => { warnT = 0; m.info.classList.remove('warn'); info(); }, 1800);
    }
    function render() {
      if (!partsEl || !m.W) return;
      const pts = [0, ...shown, D], n = pts.length - 1, x0 = m.X(0), span = m.W - 2 * P;
      let h = '';
      for (let i = 0; i < n; i++) {
        const l = m.X(pts[i]) + (i ? 2 : 0), r = m.X(pts[i + 1]) - (i < n - 1 ? 2 : 0), o = (l - x0).toFixed(1);
        h += `<div class="edw-part" style="left:${l.toFixed(1)}px;width:${Math.max(0, r - l).toFixed(1)}px">`
          + `<span class="edw-film" style="background-position:-${o}px 0,-${o}px 0"></span>`
          + `<span class="edw-wave" style="background-size:${span}px 100%;background-position:-${o}px 0"></span>`
          + `${n > 1 ? `<b>${i + 1}</b>` : ''}</div>`;
      }
      partsEl.innerHTML = h;
      while (cutsEl.children.length < cuts.length) {
        const el = document.createElement('div');
        el.className = 'edw-cut';
        el.tabIndex = 0;
        el.setAttribute('role', 'slider');
        el.setAttribute('aria-valuemin', '0');
        el.setAttribute('aria-valuemax', String(D));
        el.innerHTML = '<i></i>';
        cutsEl.append(el);
      }
      while (cutsEl.children.length > cuts.length) cutsEl.lastElementChild.remove();
      [...cutsEl.children].forEach((el, i) => {
        el.dataset.i = i;
        el.style.transform = `translateX(${m.X(shown[i]).toFixed(1)}px)`;
        el.classList.toggle('on', i === sel);
        el.setAttribute('aria-label', `Split ${i + 1}`);
        el.setAttribute('aria-valuenow', cuts[i].toFixed(2));
        el.setAttribute('aria-valuetext', fmt(cuts[i]));
      });
      info();
      badge(m.t);
    }
    function addSplit() {
      const at = snapT(m.t);
      if (at < MIN || at > D - MIN) return warn('Move the playhead off the ends');
      if (cuts.some((c) => Math.abs(c - at) < MIN)) return warn('Too close to another split');
      if (cuts.length >= MAXPARTS - 1) return warn(`${MAXPARTS} parts at most here`);
      m.ed.push(cuts.slice());
      stopSprings();
      cuts.push(at);
      cuts.sort((a, b) => a - b);
      shown = cuts.slice();
      sel = cuts.indexOf(at);
      render();
      m.ed.say(`Split at ${fmt(at)}. ${cuts.length + 1} parts.`);
    }
    function removeSplit(i) {
      if (i < 0 || i >= cuts.length) return;
      const hadFocus = cutsEl.contains(document.activeElement);
      m.ed.push(cuts.slice());
      stopSprings();
      cuts.splice(i, 1);
      shown = cuts.slice();
      sel = -1;
      render();
      if (hadFocus && !cutsEl.contains(document.activeElement)) m.ph.focus({ preventScroll: true });
      m.ed.say(`Split removed. ${plural(cuts.length + 1, 'part')}.`);
    }
    const limits = (i) => inward((i ? cuts[i - 1] : 0) + MIN, (i < cuts.length - 1 ? cuts[i + 1] : D) - MIN);

    m.ed.on($('[data-evenly]', m.win), 'change', (e) => {
      const n = +e.target.value;
      e.target.selectedIndex = 0;
      m.ed.push(cuts.slice());
      stopSprings();
      cuts = n ? Array.from({ length: n - 1 }, (_, j) => snapT((D * (j + 1)) / n)) : [];
      shown = cuts.slice();
      sel = -1;
      render();
      m.ed.say(n ? `Split into ${n} equal parts.` : 'All splits removed.');
    });
    m.ed.on(cutsEl, 'pointerdown', (e) => {
      const h = e.target.closest('.edw-cut');
      if (!h || e.button > 0) return;
      const i = +h.dataset.i, [lo, hi] = limits(i), before = cuts.slice();
      if (springs[i]) { springs[i](); springs[i] = null; }
      sel = i;
      dragValue(m, e, h, {
        lo, hi, dim: 0.2, shown: () => shown[i],
        set: (v, s) => { cuts[i] = v; shown[i] = s; render(); },
        end: (moved, vel) => {
          if (moved && Math.abs(cuts[i] - before[i]) > 1e-6) { m.ed.push(before); m.ed.say(`Split ${i + 1} at ${fmt(cuts[i])}.`); }
          if (Math.abs(shown[i] - cuts[i]) > 1e-4) {
            springs[i] = spring(shown[i], cuts[i], vel, (x) => { shown[i] = x; render(); }, () => { springs[i] = null; }, { response: 0.3, eps: 5e-4 });
          } else { shown[i] = cuts[i]; render(); }
        },
      });
      render();
    });
    m.ed.on(cutsEl, 'focusin', (e) => { const h = e.target.closest('.edw-cut'); if (h && sel !== +h.dataset.i) { sel = +h.dataset.i; render(); } });
    m.ed.on(cutsEl, 'keydown', (e) => {
      const h = e.target.closest('.edw-cut');
      if (!h) return;
      const i = +h.dataset.i;
      let d = 0;
      if (e.key === 'ArrowRight' || e.key === 'ArrowUp') d = 1;
      else if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') d = -1;
      if (d) {
        e.preventDefault();
        const [lo, hi] = limits(i), v = snapT(clamp(cuts[i] + d * (e.shiftKey ? 1 : 0.1), lo, hi));
        if (Math.abs(v - cuts[i]) > 1e-6) { m.ed.push(cuts.slice()); stopSprings(); cuts[i] = v; shown = cuts.slice(); render(); }
      } else if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); removeSplit(i); }
      else if (e.key === ' ') { e.preventDefault(); m.toggle(); }
      else if (e.key === 'Escape') { e.preventDefault(); sel = -1; render(); m.ph.focus({ preventScroll: true }); }
    });
    return { destroy() { stopSprings(); clearTimeout(warnT); m.destroy(); } };
  }

  // ---------- Trim ----------
  function buildTrim(host) {
    const MIN = 0.5;
    let a = 1.5, b = 10, sa = a, sb = b, warnT = 0;
    const springs = {};
    let trimEl = null, dimL = null, dimR = null, ths = null;
    const stopSprings = () => { Object.keys(springs).forEach((k) => { if (springs[k]) springs[k](); springs[k] = null; }); };

    const m = media(host, {
      id: 'trim', tool: 'Trim', start: 4,
      tools: '<div class="edw-seg"><button type="button" data-act="setin">Set Start</button><button type="button" data-act="setout">Set End</button></div>',
      track: `<span class="edw-film edw-full"></span><span class="edw-wave edw-full"></span><span class="edw-dim"></span><span class="edw-dim"></span>`,
      extra: `<div class="edw-trim">
        <div class="edw-th" data-h="in" role="slider" tabindex="0" aria-label="Start" aria-valuemin="0" aria-valuemax="${D}"><span class="edw-tip"></span></div>
        <div class="edw-th" data-h="out" role="slider" tabindex="0" aria-label="End" aria-valuemin="0" aria-valuemax="${D}"><span class="edw-tip"></span></div></div>`,
      range: () => [a, b],
      layout: render,
      onTime: (t) => { if (trimEl) { const out = t < a - 1e-3 || t > b + 1e-3; m.frame.classList.toggle('cut', out); m.badge.hidden = !out; m.badge.textContent = 'Not kept'; } },
      act: (x) => {
        const t = snapT(m.t), before = [a, b];
        if (x === 'setin') {
          if (t > b - MIN) return warn('Start has to be before the end');
          stopSprings(); a = sa = t;
        } else if (x === 'setout') {
          if (t < a + MIN) return warn('End has to be after the start');
          stopSprings(); b = sb = t;
        } else return;
        if (before[0] !== a || before[1] !== b) { m.ed.push(before); render(); m.ed.say(`${x === 'setin' ? 'Start' : 'End'} set to ${fmt(t)}.`); }
      },
      restore: (s) => { stopSprings(); [a, b] = s; sa = a; sb = b; render(); },
      save: () => { m.stop(); m.ed.open([{ ext: 'MP4', name: 'sunset trimmed.mp4', meta: `${(b - a).toFixed(2)} s` }]); },
    });
    trimEl = $('.edw-trim', m.win);
    m.tl.style.setProperty('--wave', waveURL('#D98AC4'));
    [dimL, dimR] = $$('.edw-dim', m.win);
    ths = { in: $('[data-h="in"]', m.win), out: $('[data-h="out"]', m.win) };

    function warn(msg) {
      clearTimeout(warnT);
      m.info.textContent = msg;
      m.info.classList.add('warn');
      m.ed.say(msg);
      warnT = setTimeout(() => { warnT = 0; m.info.classList.remove('warn'); render(); }, 1800);
    }
    function render() {
      if (!trimEl || !m.W) return;
      const xa = m.X(sa), xb = m.X(sb);
      trimEl.style.transform = `translateX(${xa.toFixed(1)}px)`;
      trimEl.style.width = `${Math.max(0, xb - xa).toFixed(1)}px`;
      dimL.style.left = `${P}px`;
      dimL.style.width = `${Math.max(0, xa - P).toFixed(1)}px`;
      dimR.style.left = `${xb.toFixed(1)}px`;
      dimR.style.width = `${Math.max(0, m.W - P - xb).toFixed(1)}px`;
      [['in', a], ['out', b]].forEach(([k, v]) => {
        ths[k].setAttribute('aria-valuenow', v.toFixed(2));
        ths[k].setAttribute('aria-valuetext', fmt(v));
        ths[k].firstElementChild.textContent = fmt(v);
      });
      if (!warnT) m.info.innerHTML = `<span class="edw-se">Start <b>${fmt(a)}</b> · End <b>${fmt(b)}</b> · </span>Length <b>${(b - a).toFixed(2)} s</b>`;
      m.ed.canSave(a > 1e-3 || b < D - 1e-3);
    }
    const lim = (k) => (k === 'in' ? inward(0, b - MIN) : inward(a + MIN, D));
    m.ed.on(trimEl, 'pointerdown', (e) => {
      const h = e.target.closest('.edw-th');
      if (!h || e.button > 0) return;
      const k = h.dataset.h, [lo, hi] = lim(k), before = [a, b];
      if (springs[k]) { springs[k](); springs[k] = null; }
      m.stop();
      dragValue(m, e, h, {
        lo, hi, dim: 0.35, shown: () => (k === 'in' ? sa : sb),
        // The picture shows the frame at the edge being dragged
        set: (v, s) => { if (k === 'in') { a = v; sa = s; } else { b = v; sb = s; } m.setT(v); render(); },
        end: (moved, vel) => {
          if (moved && (before[0] !== a || before[1] !== b)) { m.ed.push(before); m.ed.say(`Keeps ${fmt(a)} to ${fmt(b)}, ${(b - a).toFixed(2)} seconds.`); }
          const s = k === 'in' ? sa : sb, v = k === 'in' ? a : b;
          const put = (x) => { if (k === 'in') sa = x; else sb = x; render(); };
          if (Math.abs(s - v) > 1e-4) springs[k] = spring(s, v, vel, put, () => { springs[k] = null; }, { response: 0.3, eps: 5e-4 });
          else put(v);
        },
      });
    });
    m.ed.on(trimEl, 'keydown', (e) => {
      const h = e.target.closest('.edw-th');
      if (!h) return;
      const k = h.dataset.h, [lo, hi] = lim(k), cur = k === 'in' ? a : b;
      let v = null;
      if (e.key === 'ArrowRight' || e.key === 'ArrowUp') v = cur + (e.shiftKey ? 1 : 0.1);
      else if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') v = cur - (e.shiftKey ? 1 : 0.1);
      else if (e.key === 'Home') v = lo;
      else if (e.key === 'End') v = hi;
      else if (e.key === ' ') { e.preventDefault(); m.toggle(); return; }
      if (v === null) return;
      e.preventDefault();
      v = snapT(clamp(v, lo, hi));
      if (Math.abs(v - cur) < 1e-6) return;
      m.ed.push([a, b]);
      stopSprings();
      if (k === 'in') a = sa = v; else b = sb = v;
      m.stop();
      m.setT(v);
      render();
    });
    return { destroy() { stopSprings(); clearTimeout(warnT); m.destroy(); } };
  }

  // ---------- Crop ----------
  function buildCrop(host) {
    const IW = 1600, IH = 1000, MINF = 0.08, FULL = { x: 0, y: 0, w: 1, h: 1 };
    let r = { x: 0.1, y: 0.1, w: 0.66, h: 0.72 }, s = { ...r }, ratio = 0, SW = 0, SH = 0;
    const springs = {};
    const HS = [['nw', 'Top left corner'], ['n', 'Top edge'], ['ne', 'Top right corner'], ['e', 'Right edge'],
      ['se', 'Bottom right corner'], ['s', 'Bottom edge'], ['sw', 'Bottom left corner'], ['w', 'Left edge']];
    host.innerHTML = shell({
      id: 'crop', file: 'lake.png', tool: 'Crop',
      tools: `<label class="edw-popup"><span data-ratio-label>Free</span><span class="edw-popup-ch">${I.updown}</span>
        <select aria-label="Aspect ratio"><option value="0">Free</option><option value="1">1:1</option><option value="${16 / 9}">16:9</option><option value="${4 / 3}">4:3</option></select></label>`,
      end: '<button type="button" class="edw-btn edw-text" data-act="reset">Reset</button>',
      body: `<div class="edw-cropwrap"><div class="edw-crop"><img src="assets/lake.webp" alt="" width="480" height="300" draggable="false">
        <div class="edw-cf" tabindex="0" role="group" aria-roledescription="crop frame" aria-label="Crop frame. Arrow keys move it; Return saves."><span class="edw-thirds"></span>
        ${HS.map(([k, l]) => (k.length === 2
          ? `<span class="edw-ch" data-h="${k}" tabindex="0" role="button" aria-roledescription="handle" aria-label="${l}. Arrow keys resize."></span>`
          : `<span class="edw-ch" data-h="${k}" aria-hidden="true"></span>`)).join('')}</div></div></div>`,
      foot: '<span class="edw-hint">Drag a corner or an edge to crop, or inside to move.</span><span data-size></span>',
    });
    const win = host.firstElementChild;
    const wrap = $('.edw-cropwrap', win), box = $('.edw-crop', win), cf = $('.edw-cf', win), sizeEl = $('[data-size]', win);
    const select = $('select', win), label = $('[data-ratio-label]', win), resetBtn = $('[data-act="reset"]', win);
    const stopSprings = () => { Object.keys(springs).forEach((k) => { if (springs[k]) springs[k](); springs[k] = null; }); };
    const px = (q) => `${Math.round(q.w * IW)} × ${Math.round(q.h * IH)} px`;
    const isFull = () => r.x < 1e-3 && r.y < 1e-3 && r.w > 0.999 && r.h > 0.999;
    const ratioOf = (v) => (parseFloat(v) || 0) * (IH / IW); // pixel aspect → this picture's 0…1 units

    const ed = base(win, {
      file: 'lake.png',
      save, restore: (q) => { stopSprings(); r = { ...q.r }; s = { ...r }; select.value = q.v; before0 = q.v; ratio = ratioOf(q.v); label.textContent = select.options[select.selectedIndex].text; render(); },
      act: (a) => { if (a === 'reset') reset(); },
      key: (e) => { if (e.key === 'Enter' && !e.target.closest('button, select')) { e.preventDefault(); save(); } },
      home: () => cf,
    });
    const snapshot = () => ({ r: { ...r }, v: select.value });
    function save() { if (isFull()) return; ed.open([{ ext: 'PNG', name: 'lake cropped.png', meta: px(r) }]); }

    function render() {
      if (!SW) return;
      cf.style.left = `${(s.x * SW).toFixed(1)}px`;
      cf.style.top = `${(s.y * SH).toFixed(1)}px`;
      cf.style.width = `${(s.w * SW).toFixed(1)}px`;
      cf.style.height = `${(s.h * SH).toFixed(1)}px`;
      sizeEl.textContent = `${px(r)} · from ${IW} × ${IH}`;
      ed.canSave(!isFull());
      resetBtn.disabled = isFull() && !ratio;
    }
    // Settle what's on screen onto the logical frame, x and y on their own springs (apple-motion §3)
    function settle(vx = 0, vy = 0) {
      stopSprings();
      ['x', 'y', 'w', 'h'].forEach((k) => {
        if (Math.abs(s[k] - r[k]) < 1e-4) { s[k] = r[k]; return; }
        springs[k] = spring(s[k], r[k], k === 'x' ? vx : k === 'y' ? vy : 0, (v) => { s[k] = v; render(); }, () => { springs[k] = null; }, { response: 0.35, eps: 2e-4 });
      });
      render();
    }
    // Resize from the handle `h`, the opposite side staying put (the centre line, for an edge with the shape locked)
    function resizeRect(st, h, ddx, ddy, R) {
      const dx = h.includes('e') ? 1 : h.includes('w') ? -1 : 0, dy = h.includes('s') ? 1 : h.includes('n') ? -1 : 0;
      const ax = dx === 1 ? st.x : dx === -1 ? st.x + st.w : st.x + st.w / 2;
      const ay = dy === 1 ? st.y : dy === -1 ? st.y + st.h : st.y + st.h / 2;
      let w = dx ? Math.max(MINF, st.w + dx * ddx) : st.w, hh = dy ? Math.max(MINF, st.h + dy * ddy) : st.h;
      const aw = dx === 1 ? 1 - ax : dx === -1 ? ax : 2 * Math.min(ax, 1 - ax);
      const ah = dy === 1 ? 1 - ay : dy === -1 ? ay : 2 * Math.min(ay, 1 - ay);
      if (R) {
        if (dx && dy) { if (w / R > hh) hh = w / R; else w = hh * R; } else if (dx) hh = w / R; else w = hh * R;
        const q = Math.min(1, aw / w, ah / hh);
        w *= q; hh *= q;
      } else { w = Math.min(w, aw); hh = Math.min(hh, ah); }
      return { x: dx === 1 ? ax : dx === -1 ? ax - w : ax - w / 2, y: dy === 1 ? ay : dy === -1 ? ay - hh : ay - hh / 2, w, h: hh };
    }
    function fitRatio(q, R) {
      const cx = q.x + q.w / 2, cy = q.y + q.h / 2, A = q.w * q.h;
      let w = Math.sqrt(A * R), h = Math.sqrt(A / R);
      const k = Math.min(1, 1 / w, 1 / h);
      w *= k; h *= k;
      return { x: clamp(cx - w / 2, 0, 1 - w), y: clamp(cy - h / 2, 0, 1 - h), w, h };
    }
    const inside = (q) => ({ ...q, x: clamp(q.x, 0, 1 - q.w), y: clamp(q.y, 0, 1 - q.h) });
    function reset() {
      const before = snapshot();
      select.value = '0'; ratio = 0; label.textContent = 'Free';
      r = { ...FULL };
      ed.push(before);
      settle();
      ed.say(`Reset to the whole picture, ${px(r)}.`);
    }

    ed.on(select, 'change', () => {
      const before = { r: { ...r }, v: before0 };
      before0 = select.value;
      ratio = ratioOf(select.value);
      label.textContent = select.options[select.selectedIndex].text;
      if (ratio) { r = fitRatio(inside(s), ratio); settle(); }
      ed.push(before);
      ed.say(`${label.textContent}. ${px(r)}.`);
    });
    let before0 = select.value;
    ed.on(select, 'focus', () => { before0 = select.value; });

    ed.on(cf, 'pointerdown', (e) => {
      if (e.button > 0) return;
      e.preventDefault();
      const hEl = e.target.closest('.edw-ch'), mode = hEl ? hEl.dataset.h : 'move';
      (hEl && hEl.tabIndex === 0 ? hEl : cf).focus({ preventScroll: true });
      stopSprings();
      // Grab what's on screen, even mid-spring
      const st = { ...s }, x0 = e.clientX, y0 = e.clientY, before = snapshot(), vx = tracker(), vy = tracker();
      r = inside(st);
      capture(cf, e.pointerId);
      cf.classList.add('drag');
      const move = (ev) => {
        const dx = (ev.clientX - x0) / SW, dy = (ev.clientY - y0) / SH;
        if (mode === 'move') {
          const rx = st.x + dx, ry = st.y + dy;
          r = { ...st, x: clamp(rx, 0, 1 - st.w), y: clamp(ry, 0, 1 - st.h) };
          s = { ...st, x: band(rx, 0, 1 - st.w, 0.05), y: band(ry, 0, 1 - st.h, 0.05) };
          vx.add(s.x); vy.add(s.y);
        } else {
          r = resizeRect(inside(st), mode, dx, dy, ratio);
          s = { ...r };
        }
        render();
      };
      const up = () => {
        cf.removeEventListener('pointermove', move);
        cf.removeEventListener('pointerup', up);
        cf.removeEventListener('pointercancel', up);
        cf.classList.remove('drag');
        const ch = ['x', 'y', 'w', 'h'].some((k) => Math.abs(r[k] - before.r[k]) > 1e-5);
        if (ch) { ed.push(before); ed.say(`${px(r)}.`); }
        settle(vx.vel(), vy.vel());
      };
      cf.addEventListener('pointermove', move);
      cf.addEventListener('pointerup', up);
      cf.addEventListener('pointercancel', up);
    });
    ed.on(cf, 'keydown', (e) => {
      const A = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[e.key];
      if (!A) return;
      e.preventDefault();
      const step = e.shiftKey ? 0.05 : 0.01, h = e.target.closest('.edw-ch'), before = snapshot();
      stopSprings();
      const st = inside(s);
      r = h ? resizeRect(st, h.dataset.h, A[0] * step, A[1] * step, ratio) : { ...st, x: clamp(st.x + A[0] * step, 0, 1 - st.w), y: clamp(st.y + A[1] * step, 0, 1 - st.h) };
      s = { ...r };
      if (['x', 'y', 'w', 'h'].some((k) => Math.abs(r[k] - before.r[k]) > 1e-5)) { ed.push(before); ed.say(px(r)); }
      render();
    });

    const ro = new ResizeObserver(() => {
      const cs = getComputedStyle(wrap);
      const aw = wrap.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
      const ah = wrap.clientHeight - parseFloat(cs.paddingTop) - parseFloat(cs.paddingBottom);
      if (aw <= 0 || ah <= 0) return;
      SW = Math.floor(Math.min(aw, ah * 1.6));
      SH = Math.floor(SW / 1.6);
      box.style.width = `${SW}px`;
      box.style.height = `${SH}px`;
      render();
    });
    ro.observe(wrap);
    return { destroy() { stopSprings(); ro.disconnect(); ed.ac.abort(); } };
  }

  // ---------- Edit PDF ----------
  function buildPdf(host) {
    host.innerHTML = shell({
      id: 'pdf', file: 'estimate.pdf', tool: 'Edit PDF',
      tools: '<div class="edw-seg"><button type="button" data-act="mode-edit" aria-pressed="true">Edit Text</button><button type="button" data-act="mode-add" aria-pressed="false">Add Text</button></div>',
      body: `<div class="edw-desk"><div class="edw-page" data-mode="edit">
        <p class="pl pl-h1">Garden Studio — Estimate 2026-114</p>
        <p class="pl pl-meta">For Rosa Martín · 24 November 2026</p>
        <p class="pl pl-h2">Work</p>
        <p class="pl">1. Clear the north border — 2 days</p>
        <p class="pl">2. Lay a gravel path with a steel edge — 1 day</p>
        <p class="pl">3. Plant 40 dahlia tubers and 12 grasses — 1 day</p>
        <p class="pl pl-h2">Prices</p>
        <div class="pt"><span class="pl pt-h">Item</span><span class="pl pt-h">Amount</span>
          <span class="pl">Labour, 4 days</span><span class="pl">€1,440</span>
          <span class="pl">Gravel, edging and plants</span><span class="pl">€875</span>
          <span class="pl pt-t">Total</span><span class="pl pt-t">€2,315</span></div>
        <p class="pl">A deposit of €500 books the start date.</p>
        <p class="pl pl-h2">Notes</p>
        <div class="pn" aria-hidden="true"></div>
      </div></div>`,
      foot: '<span data-changes>No changes</span><span>Page 1 of 1</span>',
    });
    const win = host.firstElementChild;
    const page = $('.edw-page', win), changesEl = $('[data-changes]', win);
    const modeBtns = $$('[data-act^="mode-"]', win);
    let mode = 'edit', before = '', pageSnap = '', pending = null;
    const CE = (() => { try { const d = document.createElement('div'); d.contentEditable = 'plaintext-only'; return d.contentEditable === 'plaintext-only' ? 'plaintext-only' : 'true'; } catch (_) { return 'true'; } })();
    const prep = (el) => { el.setAttribute('contenteditable', CE); el.setAttribute('role', 'textbox'); el.spellcheck = false; };
    $$('.pl', page).forEach((el, i) => { prep(el); el.dataset.orig = el.textContent; el.tabIndex = i ? -1 : 0; });

    const ed = base(win, {
      file: 'estimate.pdf',
      save: () => { const n = count(); if (n) ed.open([{ ext: 'PDF', name: 'estimate edited.pdf', meta: plural(n, 'change') }]); },
      restore: (html) => { page.innerHTML = html; if (!$('.pl[tabindex="0"]', page)) { const f = $('.pl', page); if (f) f.tabIndex = 0; } recount(); },
      act: (a) => { if (a === 'mode-edit' || a === 'mode-add') setMode(a.slice(5)); },
    });
    const count = () => $$('.pl', page).filter((el) => (el.classList.contains('pl-add') ? el.textContent.trim() : el.textContent !== el.dataset.orig)).length;
    // Added boxes are positioned, so the page grows to hold one that runs past its foot
    function fitPage() {
      page.style.minHeight = '';
      const need = Math.max(0, ...$$('.pl-add', page).map((x) => x.offsetTop + x.offsetHeight + 16));
      if (need > page.offsetHeight) page.style.minHeight = `${need}px`;
    }
    function recount() {
      fitPage();
      const n = count();
      changesEl.textContent = n ? plural(n, 'change') : 'No changes';
      ed.canSave(n > 0);
    }
    function setMode(mo) {
      mode = mo;
      page.dataset.mode = mo;
      modeBtns.forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.act === `mode-${mo}`)));
      if (mo === 'add') { page.tabIndex = 0; page.setAttribute('role', 'group'); page.setAttribute('aria-label', 'Page. Click where the text goes, or press Return.'); }
      else { page.removeAttribute('tabindex'); page.removeAttribute('role'); page.removeAttribute('aria-label'); }
      ed.say(mo === 'add' ? 'Add Text: click on the page where the text goes.' : 'Edit Text: click a line to change it.');
    }
    const rove = (el) => { $$('.pl[tabindex="0"]', page).forEach((x) => { if (x !== el) x.tabIndex = -1; }); el.tabIndex = 0; };
    const caretEnd = (el) => { const sel = getSelection(); sel.selectAllChildren(el); sel.collapseToEnd(); };
    function commit(el) {
      if (el.classList.contains('pl-add') && !el.textContent.trim()) {
        const isNew = !!el.dataset.new;
        el.remove();
        if (!isNew) ed.push(pageSnap);
        recount();
        return;
      }
      if (el.textContent !== before) {
        ed.push(pageSnap);
        before = el.textContent;
        el.classList.toggle('changed', el.textContent !== el.dataset.orig);
        delete el.dataset.new;
        pageSnap = page.innerHTML;
        ed.say('Changed.');
      }
      delete el.dataset.new;
      recount();
    }
    function addBox(fx, fy) {
      const snap = page.innerHTML;
      const el = document.createElement('p');
      el.className = 'pl pl-add changed';
      el.dataset.new = '1';
      const left = clamp(fx, 0.04, 0.8);
      el.style.left = `${(left * 100).toFixed(1)}%`;
      // It wraps before the page's right edge instead of running off it
      el.style.maxWidth = `calc(${((1 - left) * 100).toFixed(1)}% - 16px)`;
      prep(el);
      el.tabIndex = -1;
      el.textContent = 'Text';
      pending = snap;
      page.append(el);
      place(el, fy * page.clientHeight);
      el.focus({ preventScroll: true });
      getSelection().selectAllChildren(el);
    }

    // Centred on the click, then stepped down past any text it would cover, so new text never lands on old.
    // Stored in em, so it stays with the text when the page's type size follows the window.
    const fsz = () => parseFloat(getComputedStyle(page).fontSize) || 12;
    function place(el, y) {
      const pr = page.getBoundingClientRect(), h = el.offsetHeight, fs = fsz();
      const L = el.offsetLeft, R = L + el.offsetWidth;
      const boxes = $$('.pl', page).filter((x) => x !== el).map((x) => { const r = x.getBoundingClientRect(); return [r.top - pr.top, r.bottom - pr.top, r.left - pr.left, r.right - pr.left]; });
      let top = clamp(y - h / 2, 4, page.clientHeight - h - 4);
      for (let moved = true, n = 0; moved && n < 40; n++) {
        moved = false;
        for (const [t, b, l, r] of boxes) if (top < b + 2 && top + h > t - 2 && L < r && R > l) { top = b + 3; moved = true; }
      }
      el.style.top = `${(top / fs).toFixed(2)}em`;
      fitPage();
      // If that put it below what the desk shows, the desk scrolls to it
      const desk = page.parentElement, dr = desk.getBoundingClientRect(), er = el.getBoundingClientRect();
      const dy = er.bottom + 16 > dr.bottom ? er.bottom + 16 - dr.bottom : er.top - 16 < dr.top ? er.top - 16 - dr.top : 0;
      if (dy) desk.scrollBy({ top: dy, behavior: RM() ? 'auto' : 'smooth' });
    }
    // Return on the page (keyboard Add Text) starts a box at the top of the Notes area
    const notesY = () => { const pn = $('.pn', page); return pn ? (pn.offsetTop + fsz()) / page.clientHeight : 0.9; };
    ed.on(page, 'focusin', (e) => {
      const el = e.target.closest('.pl');
      if (!el) return;
      before = el.dataset.new ? '' : el.textContent;
      pageSnap = pending || page.innerHTML;
      pending = null;
      if (!el.classList.contains('pl-add')) rove(el);
    });
    ed.on(page, 'focusout', (e) => { const el = e.target.closest('.pl'); if (el && el.isConnected) commit(el); });
    ed.on(page, 'input', recount);
    ed.on(page, 'paste', (e) => {
      if (!e.target.closest('.pl')) return;
      e.preventDefault();
      const text = ((e.clipboardData && e.clipboardData.getData('text/plain')) || '').replace(/\s+/g, ' ');
      document.execCommand('insertText', false, text);
    });
    ed.on(page, 'drop', (e) => e.preventDefault());
    ed.on(page, 'keydown', (e) => {
      const el = e.target.closest('.pl');
      if (!el) {
        if (mode === 'add' && e.target === page && e.key === 'Enter') { e.preventDefault(); addBox(0.08, notesY()); }
        return;
      }
      if (e.key === 'Enter') {
        // Return confirms the line
        e.preventDefault();
        commit(el);
        el.classList.remove('ok');
        void el.offsetWidth;
        el.classList.add('ok');
      } else if (e.key === 'Escape') {
        // esc puts the line back as it was when you came to it
        e.preventDefault();
        e.stopPropagation();
        if (el.dataset.new) { el.remove(); page.focus({ preventScroll: true }); recount(); return; }
        el.textContent = before;
        caretEnd(el);
        recount();
        ed.say('Put back.');
      } else if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && !el.classList.contains('pl-add')) {
        const all = $$('.pl:not(.pl-add)', page), j = all.indexOf(el) + (e.key === 'ArrowDown' ? 1 : -1);
        if (all[j]) { e.preventDefault(); all[j].focus(); caretEnd(all[j]); }
      }
    });
    // Add Text: the lines step aside (CSS) and a click on the page puts a text box there
    ed.on(page, 'click', (e) => {
      if (mode !== 'add' || e.target.closest('.pl-add')) return;
      const rc = page.getBoundingClientRect();
      addBox((e.clientX - rc.left) / rc.width, (e.clientY - rc.top) / rc.height);
    });
    recount();
    return { destroy() { ed.ac.abort(); } };
  }

  // ---------- Tabs ----------
  const mqTouch = matchMedia('(hover: none)');
  const COPY = {
    split: { h: 'Split', p: 'Cut one video into parts. Each part is saved as its own file.',
      hint: `<kbd class="k">${MAC ? '⌘' : 'Ctrl'}</kbd><kbd class="k">B</kbd> or the scissors split at the playhead. Drag a split to move it.`,
      touch: { hint: 'Tap the scissors to split at the playhead. Drag a split to move it.' } },
    trim: { h: 'Trim', p: 'Drag the pink edges to keep just the part you want.',
      hint: 'Play plays only what stays. Set Start and Set End use the playhead.' },
    crop: { h: 'Crop', p: 'Drag a corner, an edge or the middle. 1:1, 16:9 and 4:3 lock the shape.',
      hint: '<kbd class="k">Return</kbd> saves. Arrow keys nudge.', touch: { hint: '' } },
    pdf: { h: 'Edit PDF', p: 'Click any line on the page and type over it. Add Text puts new text where you click.',
      hint: '<kbd class="k">Return</kbd> confirms a line, <kbd class="k">esc</kbd> puts it back.',
      touch: { p: 'Tap any line on the page and type over it. Add Text puts new text where you tap.', hint: '' } },
  };
  const BUILD = { split: buildSplit, trim: buildTrim, crop: buildCrop, pdf: buildPdf };
  const tabs = $$('[role="tab"]', tabList);
  let current = null, currentId = '';
  function show(id) {
    if (id === currentId || !BUILD[id]) return;
    if (current) current.destroy();
    currentId = id;
    current = BUILD[id](stage);
    const c = { ...COPY[id], ...(mqTouch.matches && COPY[id].touch) };
    copyEl.innerHTML = `<h3>${c.h}</h3><p>${c.p}</p>${c.hint ? `<p class="ed-hint">${c.hint}</p>` : ''}`;
  }
  function select(t, focus) {
    tabs.forEach((x) => { const sel = x === t; x.setAttribute('aria-selected', String(sel)); x.tabIndex = sel ? 0 : -1; });
    if (focus) t.focus();
    panel.setAttribute('aria-labelledby', t.id);
    show(t.dataset.ed);
  }
  tabList.addEventListener('click', (e) => { const t = e.target.closest('[role="tab"]'); if (t) select(t, false); });
  tabList.addEventListener('keydown', (e) => {
    const i = tabs.indexOf(document.activeElement);
    if (i < 0) return;
    const j = { ArrowRight: (i + 1) % tabs.length, ArrowDown: (i + 1) % tabs.length, ArrowLeft: (i - 1 + tabs.length) % tabs.length,
      ArrowUp: (i - 1 + tabs.length) % tabs.length, Home: 0, End: tabs.length - 1 }[e.key];
    if (j !== undefined) { e.preventDefault(); select(tabs[j], true); }
  });
  const byId = (id) => tabs.find((x) => x.dataset.ed === id);
  // The playground's "See the Split window" links
  window.addEventListener('dw:editor', (ev) => { const t = byId(ev.detail); if (t) select(t, false); });
  // The list of every editor: the ones with a window above open it
  document.addEventListener('click', (e) => {
    const b = e.target.closest('[data-ed-go]');
    if (!b) return;
    const t = byId(b.dataset.edGo);
    if (!t) return;
    select(t, false);
    tabList.scrollIntoView({ block: 'nearest', behavior: RM() ? 'auto' : 'smooth' });
    const w = $('.edw', stage);
    if (w) setTimeout(() => { const f = $('.edw-ph, .edw-cf, .pl', w); if (f) f.focus({ preventScroll: true }); }, RM() ? 0 : 350);
  });
  select(tabs.find((x) => x.getAttribute('aria-selected') === 'true') || tabs[0], false);
})();
