package main

// indexHTML polls /api/color continuously. Every response becomes one tile,
// coloured by whichever version answered, so an ALB weight change shows up on
// screen within a second or two. Errors render as dark red tiles.
const indexHTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Argo Rollouts traffic</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; background:#0b1020; color:#e6edf7;
         font:15px/1.45 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; }
  header { padding:18px 24px 12px; border-bottom:1px solid #1e2a44; }
  h1 { margin:0 0 4px; font-size:17px; letter-spacing:.2px; font-weight:600; }
  .sub { color:#8b9ec4; font-size:13px; }
  .stats { display:flex; flex-wrap:wrap; gap:10px; padding:14px 24px; }
  .stat { background:#111a30; border:1px solid #1e2a44; border-radius:10px;
          padding:10px 14px; min-width:132px; }
  .stat .k { font-size:11px; text-transform:uppercase; letter-spacing:.7px; color:#8b9ec4; }
  .stat .v { font-size:22px; font-weight:650; margin-top:3px; font-variant-numeric:tabular-nums; }
  .dot { display:inline-block; width:10px; height:10px; border-radius:3px;
         margin-right:7px; vertical-align:middle; }
  #grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(15px,1fr));
          gap:3px; padding:8px 24px 28px; }
  .t { aspect-ratio:1; border-radius:3px; }
  .err { background:#7f1d1d !important; box-shadow:inset 0 0 0 1.5px #ef4444; }
</style>
</head>
<body>
<header>
  <h1>Argo Rollouts &mdash; live traffic</h1>
  <div class="sub">Each tile is one response through the load balancer, newest first.</div>
</header>
<div class="stats" id="stats"></div>
<div id="grid"></div>
<script>
const MAX = 600;
const tiles = [];
const counts = new Map();
let errors = 0, total = 0;
const grid = document.getElementById('grid');
const stats = document.getElementById('stats');

function render() {
  const rows = [...counts.entries()].sort((a,b) => a[0].localeCompare(b[0]));
  let html = '<div class="stat"><div class="k">Responses</div><div class="v">'
           + total.toLocaleString() + '</div></div>';
  for (const [ver, c] of rows) {
    const pct = total ? (c.n / total * 100) : 0;
    html += '<div class="stat"><div class="k"><span class="dot" style="background:'
          + c.color + '"></span>' + ver + '</div><div class="v">'
          + pct.toFixed(1) + '%</div></div>';
  }
  const errPct = total ? (errors / total * 100) : 0;
  html += '<div class="stat"><div class="k"><span class="dot" style="background:#ef4444">'
        + '</span>Errors</div><div class="v">' + errPct.toFixed(2) + '%</div></div>';
  stats.innerHTML = html;
}

function push(color, ver, isErr) {
  total++;
  if (isErr) errors++;
  if (ver) {
    const c = counts.get(ver) || { n: 0, color: color };
    c.n++; c.color = color || c.color;
    counts.set(ver, c);
  }
  const el = document.createElement('div');
  el.className = 't' + (isErr ? ' err' : '');
  el.style.background = color || '#334155';
  grid.prepend(el);
  tiles.push(el);
  if (tiles.length > MAX) tiles.shift().remove();
}

async function poll() {
  try {
    const r = await fetch('/api/color', { cache: 'no-store' });
    if (!r.ok) { push('#7f1d1d', r.headers.get('X-Demo-Version'), true); }
    else { const d = await r.json(); push(d.color, d.version, false); }
  } catch (e) {
    push('#7f1d1d', null, true);
  }
  render();
}

setInterval(poll, 120);
for (let i = 0; i < 6; i++) setTimeout(poll, i * 40);
</script>
</body>
</html>`
