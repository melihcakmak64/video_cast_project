const String watch_page = r'''
<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Video Player</title>
<style>
  html, body { margin: 0; height: 100%; background: #000; overflow: hidden;
               font-family: sans-serif; user-select: none; }
  video { width: 100%; height: 100%; object-fit: contain; background: #000; }

  #status {
    position: fixed; top: 16px; left: 16px; z-index: 5;
    color: #fff; font-size: 20px; opacity: .9; text-shadow: 0 0 4px #000;
  }

  #controls {
    position: fixed; left: 0; right: 0; bottom: 0; z-index: 10;
    padding: 24px 32px 28px;
    background: linear-gradient(transparent, rgba(0,0,0,.85));
    color: #fff; transition: opacity .3s;
  }
  #controls.hidden { opacity: 0; pointer-events: none; }

  #bar { position: relative; height: 8px; background: rgba(255,255,255,.3);
         border-radius: 4px; cursor: pointer; margin-bottom: 14px; }
  #fill { position: absolute; left: 0; top: 0; bottom: 0; width: 0;
          background: #e50914; border-radius: 4px; }
  #knob { position: absolute; top: 50%; width: 18px; height: 18px;
          margin: -9px 0 0 -9px; background: #fff; border-radius: 50%; left: 0; }

  #row { display: flex; align-items: center; gap: 20px; }
  .btn { background: none; border: none; color: #fff; font-size: 32px;
         cursor: pointer; padding: 4px 10px; }
  .btn:hover { background: rgba(255,255,255,.2); border-radius: 8px; }
  #time { font-size: 20px; margin-left: auto; }
  #fs { margin-left: 8px; }
</style>
</head>
<body>
<div id="status">Bağlanıyor...</div>

<video id="v" autoplay playsinline></video>

<div id="controls">
  <div id="bar"><div id="fill"></div><div id="knob"></div></div>
  <div id="row">
    <button class="btn" id="back">⏪ 10</button>
    <button class="btn" id="play">⏸</button>
    <button class="btn" id="fwd">10 ⏩</button>
    <span id="time">0:00 / 0:00</span>
    <button class="btn" id="fs" title="Tam ekran">⛶</button>
  </div>
</div>

<script>
  const v = document.getElementById('v');
  const statusEl = document.getElementById('status');
  const controls = document.getElementById('controls');
  const bar = document.getElementById('bar');
  const fill = document.getElementById('fill');
  const knob = document.getElementById('knob');
  const playBtn = document.getElementById('play');
  const timeEl = document.getElementById('time');
  const fsBtn = document.getElementById('fs');

  let ws;
  let baseUrl = null;
  let offset = 0;
  let duration = 0;
  let hideTimer;

  function fmt(s) {
    s = Math.max(0, Math.floor(s || 0));
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    const mm = h > 0 ? String(m).padStart(2, '0') : String(m);
    const ss = String(sec).padStart(2, '0');
    return h > 0 ? h + ':' + mm + ':' + ss : mm + ':' + ss;
  }

  function setStatus(t) {
    statusEl.textContent = t;
    statusEl.style.display = t ? 'block' : 'none';
  }

  function showControls() {
    controls.classList.remove('hidden');
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      if (!v.paused) controls.classList.add('hidden');
    }, 4000);
  }

  function currentPos() { return offset + (v.currentTime || 0); }

  function loadVideo(start) {
    if (!baseUrl) return;
    offset = Math.max(0, start || 0);
    v.src = baseUrl + '&start=' + offset;
    v.load();
    v.play().then(() => setStatus('')).catch(() => {
      setStatus('Oynatmak için OK / ekrana tıklayın');
    });
  }

  function seekTo(sec) {
    if (duration > 0) sec = Math.min(sec, Math.max(0, duration - 1));
    loadVideo(sec);
    sendState();
  }

  function togglePlay() {
    if (v.paused) v.play().catch(() => {}); else v.pause();
    sendState();
  }

  // --- Tam ekran ---
  function isFullscreen() {
    return !!(document.fullscreenElement || document.webkitFullscreenElement);
  }

  function toggleFullscreen() {
    const el = document.documentElement;
    if (!isFullscreen()) {
      const req = el.requestFullscreen || el.webkitRequestFullscreen;
      if (req) {
        const p = req.call(el);
        if (p && p.catch) p.catch(() => {});
      }
    } else {
      const exit = document.exitFullscreen || document.webkitExitFullscreen;
      if (exit) {
        const p = exit.call(document);
        if (p && p.catch) p.catch(() => {});
      }
    }
  }

  function updateFsIcon() {
    fsBtn.textContent = isFullscreen() ? '🗗' : '⛶';
  }

  document.addEventListener('fullscreenchange', updateFsIcon);
  document.addEventListener('webkitfullscreenchange', updateFsIcon);

  function updateUi() {
    const pos = currentPos();
    const pct = duration > 0 ? Math.min(100, (pos / duration) * 100) : 0;
    fill.style.width = pct + '%';
    knob.style.left = pct + '%';
    timeEl.textContent = fmt(pos) + ' / ' + fmt(duration);
    playBtn.textContent = v.paused ? '▶' : '⏸';
  }

  function sendState() {
    if (ws && ws.readyState === WebSocket.OPEN && baseUrl) {
      ws.send(JSON.stringify({
        event: 'timeupdate',
        currentTime: currentPos(),
        duration: duration,
        paused: v.paused
      }));
    }
  }

  // --- Kontroller ---
  playBtn.addEventListener('click', (e) => { e.stopPropagation(); togglePlay(); showControls(); });
  document.getElementById('back').addEventListener('click', (e) => {
    e.stopPropagation(); seekTo(currentPos() - 10); showControls();
  });
  document.getElementById('fwd').addEventListener('click', (e) => {
    e.stopPropagation(); seekTo(currentPos() + 10); showControls();
  });
  fsBtn.addEventListener('click', (e) => {
    e.stopPropagation(); toggleFullscreen(); showControls();
  });
  bar.addEventListener('click', (e) => {
    e.stopPropagation();
    if (duration <= 0) return;
    const r = bar.getBoundingClientRect();
    seekTo(((e.clientX - r.left) / r.width) * duration);
    showControls();
  });

  // Ekrana tıklayınca kontrolleri göster/gizle
  document.body.addEventListener('click', () => {
    if (controls.classList.contains('hidden')) showControls();
    else togglePlay();
  });

  // Çift tıklayınca tam ekran
  document.body.addEventListener('dblclick', toggleFullscreen);

  // TV kumandası
  document.addEventListener('keydown', (e) => {
    showControls();
    switch (e.key) {
      case 'Enter': case ' ': case 'MediaPlayPause':
        togglePlay(); break;
      case 'MediaPlay': v.play(); sendState(); break;
      case 'MediaPause': v.pause(); sendState(); break;
      case 'ArrowLeft': case 'MediaRewind':
        seekTo(currentPos() - 10); break;
      case 'ArrowRight': case 'MediaFastForward':
        seekTo(currentPos() + 10); break;
      case 'f': case 'F':
        toggleFullscreen(); break;
    }
  });

  // --- WebSocket ---
  function connect() {
    ws = new WebSocket('ws://' + location.host + '/ws');

    ws.onopen = () => setStatus('Bağlandı, video bekleniyor...');

    ws.onmessage = (e) => {
      let msg;
      try { msg = JSON.parse(e.data); } catch (_) { return; }

      switch (msg.command) {
        case 'reload':
          baseUrl = msg.url;
          duration = msg.duration || 0;
          loadVideo(0);
          break;
        case 'play':
          v.play().catch(() => {});
          break;
        case 'pause':
          v.pause();
          break;
        case 'seek':
          loadVideo(msg.seconds);
          break;
      }
    };

    ws.onclose = () => {
      setStatus('Bağlantı koptu, yeniden deneniyor...');
      setTimeout(connect, 1500);
    };
    ws.onerror = () => ws.close();
  }

  setInterval(() => { updateUi(); sendState(); }, 1000);
  v.addEventListener('timeupdate', updateUi);
  v.addEventListener('play', () => { updateUi(); showControls(); });
  v.addEventListener('pause', () => { updateUi(); controls.classList.remove('hidden'); });
  v.addEventListener('playing', () => setStatus(''));
  v.addEventListener('error', () => setStatus('Video yüklenemedi'));

  connect();
</script>
</body>
</html>
''';
