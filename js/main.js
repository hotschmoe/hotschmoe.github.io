(() => {
  'use strict';

  const el = (tag, props = {}, ...kids) => {
    const n = Object.assign(document.createElement(tag), props);
    kids.forEach(k => n.append(k));
    return n;
  };

  const revText = p => {
    const bits = [];
    if (p.built_at) {
      const d = new Date(p.built_at);
      if (!isNaN(d)) bits.push(d.toISOString().slice(0, 10));
    }
    if (p.commit) bits.push(String(p.commit).slice(0, 7));
    return bits.join(' / ');
  };

  const meta = (p, withTech) => {
    const m = el('p', { className: 'meta' });
    const rev = revText(p);
    if (withTech && p.tech && p.tech.length) m.append(el('span', { textContent: p.tech.join(' + ') }));
    if (rev) m.append(el('span', { textContent: 'REV ' + rev, title: 'last assembled / commit' }));
    if (p.github) m.append(el('a', { href: p.github, textContent: 'source listing', rel: 'noopener' }));
    return m;
  };

  const gameRow = (p, i) => {
    const li = el('li', { className: 'game' });
    li.append(
      el('span', { className: 'seq', textContent: String(i + 1).padStart(2, '0'), ariaHidden: 'true' }),
      el('div', {},
        el('h3', { textContent: p.title }),
        el('p', { className: 'tag', textContent: p.tagline || '' }),
        el('p', { className: 'desc', textContent: p.description || '' }),
        meta(p, true)),
      el('a', { className: 'run', href: p.path, textContent: 'Run', ariaLabel: 'Run ' + p.title })
    );
    li.dataset.key = String(i + 1);
    return li;
  };

  const entry = p => {
    const li = el('li');
    li.append(el('a', { className: 't', href: p.path, textContent: p.title }));
    if (p.tagline) li.append(el('p', { textContent: p.tagline }));
    li.append(meta(p, true));
    return li;
  };

  const section = (title, note) => {
    const s = el('section');
    s.append(el('h2', { className: 'sec' }, title, el('span', { textContent: note || '' })));
    const ul = el('ul', { className: 'entries' });
    s.append(ul);
    return { s, ul };
  };

  function render(items) {
    const games = items.filter(p => p.kind === 'game');
    if (games.length) {
      const list = document.getElementById('games-list');
      list.replaceChildren(...games.map(gameRow));
      document.getElementById('games-count').textContent = games.length + ' PROGRAM' + (games.length === 1 ? '' : 'S') + ' ON FILE';
      const needGpu = games.some(g => (g.requires || []).includes('webgpu'));
      document.getElementById('gpu-note').dataset.needed = needGpu ? '1' : '';
      syncGpu();
    }

    const toolsUl = document.getElementById('tools-list');
    const projUl = document.getElementById('projects-list');
    items.filter(p => p.kind === 'tool').forEach(p => toolsUl.append(entry(p)));
    items.filter(p => p.kind === 'project').forEach(p => projUl.prepend(entry(p)));

    const known = new Set(['game', 'tool', 'project']);
    const others = {};
    items.filter(p => !known.has(p.kind)).forEach(p => (others[p.kind] ||= []).push(p));
    const anchor = document.getElementById('about');
    Object.keys(others).forEach(kind => {
      const { s, ul } = section(String(kind), others[kind].length + ' ON FILE');
      others[kind].forEach(p => ul.append(entry(p)));
      anchor.before(s);
    });
  }

  function syncGpu() {
    const note = document.getElementById('gpu-note');
    note.hidden = !!navigator.gpu || !note.dataset.needed;
  }

  // keyboard: press a program number to run it
  document.addEventListener('keydown', e => {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    if (/^(INPUT|TEXTAREA|SELECT|BUTTON)$/.test(e.target.tagName)) return;
    const row = document.querySelector('#games-list .game[data-key="' + e.key + '"] .run');
    if (row) row.click();
  });

  // opt-in audio, off by default, nothing loads until asked
  const btn = document.getElementById('audio-btn');
  if (btn) {
    const audio = new Audio();
    audio.loop = true;
    audio.preload = 'none';
    audio.volume = 0.2;
    const vol = document.getElementById('audio-vol');
    const status = document.getElementById('audio-status');
    btn.addEventListener('click', () => {
      if (audio.paused) {
        if (!audio.src) audio.src = '/assets/background-music.ogg';
        audio.play().then(() => {
          btn.setAttribute('aria-pressed', 'true');
          btn.textContent = 'MOTOR ON: STOP';
          status.textContent = 'playing';
        }).catch(() => { status.textContent = 'unit not ready'; });
      } else {
        audio.pause();
        btn.setAttribute('aria-pressed', 'false');
        btn.textContent = 'MOTOR OFF: START';
        status.textContent = 'stopped';
      }
    });
    vol.addEventListener('input', () => { audio.volume = vol.value / 100; });
  }

  syncGpu();
  fetch('/projects.json', { cache: 'no-cache' })
    .then(r => { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then(items => { if (Array.isArray(items)) render(items); })
    .catch(() => { /* static fallback rows stay in place */ });
})();
