"""Static HTML for the ``/admin`` provider-spend dashboard (ARCHITECTURE.md §14.3).

Plain HTML/CSS/vanilla JS, no build step, no external framework — this is a
one-person internal ops tool (the founder), so legibility beats polish. The
page itself is served with no auth (it's inert without a valid password); the
data it calls (``/admin/provider-spend``, ``/admin/users``) stays behind the
exact same ``require_admin_password`` gate as every other ``/admin/*`` route.

The admin password is:
  - never embedded in this HTML/JS source,
  - never put in a URL query param,
  - never logged (client or server side),
  - kept only in this browser tab's ``sessionStorage`` once typed in, sent
    solely as the ``X-Admin-Password`` header on same-origin fetch() calls.
"""

from __future__ import annotations

DASHBOARD_HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ayma Admin — Finance</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 24px 16px 64px;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: #f4f5f7; color: #1a1a1a;
  }
  @media (prefers-color-scheme: dark) {
    body { background: #14161a; color: #e8e8e8; }
    .card, table { background: #1e2126 !important; border-color: #333 !important; }
    input { background: #22252a !important; color: #eee !important; border-color: #444 !important; }
    th { background: #23262c !important; }
    tr:nth-child(even) td { background: #1a1d22 !important; }
    .muted { color: #999 !important; }
    .err { background: #3a1c1c !important; color: #ff8a8a !important; }
  }
  .wrap { max-width: 1100px; margin: 0 auto; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .sub { color: #666; font-size: 13px; margin: 0 0 20px; }
  .muted { color: #666; }

  .login {
    display: flex; gap: 8px; flex-wrap: wrap; align-items: center;
    background: #fff; border: 1px solid #ddd; border-radius: 8px;
    padding: 14px; margin-bottom: 20px;
  }
  .login input[type=password] {
    flex: 1 1 220px; padding: 8px 10px; border: 1px solid #ccc; border-radius: 6px;
    font-size: 14px;
  }
  .login button, .refresh-btn {
    padding: 8px 16px; border: 0; border-radius: 6px; background: #2b6cb0;
    color: #fff; font-size: 14px; cursor: pointer;
  }
  .login button:hover, .refresh-btn:hover { background: #245a92; }
  .login .status { font-size: 13px; }

  .cards { display: flex; gap: 14px; flex-wrap: wrap; margin-bottom: 22px; }
  .card {
    flex: 1 1 220px; background: #fff; border: 1px solid #ddd; border-radius: 8px;
    padding: 16px;
  }
  .card .label { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: #777; margin-bottom: 6px; }
  .card .value { font-size: 26px; font-weight: 600; }
  .card .note { font-size: 12px; color: #888; margin-top: 6px; }
  .card.revenue .value { color: #b7791f; }

  .badge.api { background: #e6f4ea; color: #1e7e34; }
  .badge.muse { background: #e8eefc; color: #2b4fa0; }
  .badge.stale { background: #fff4e0; color: #a06a00; }
  .vendor-unavail { color: #a06a00; font-size: 13px; }
  .vendor-entry { margin: 4px 0; font-size: 13px; }
  details.how ol { margin: 6px 0 4px 18px; padding: 0; }
  @media (prefers-color-scheme: dark) {
    .badge.api { background: #16321f; color: #7fe3a0; }
    .badge.muse { background: #1c2440; color: #9db4f5; }
    .badge.stale { background: #3a2c10; color: #ffcf7a; }
    .vendor-unavail { color: #ffcf7a; }
  }
  .err {
    background: #fdecea; color: #a02020; border: 1px solid #f2b8b5;
    padding: 10px 12px; border-radius: 6px; margin-bottom: 16px; font-size: 14px;
    display: none;
  }
  .err.show { display: block; }

  table { width: 100%; border-collapse: collapse; background: #fff; border: 1px solid #ddd; border-radius: 8px; overflow: hidden; font-size: 13px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #eee; }
  th { background: #fafafa; cursor: pointer; user-select: none; white-space: nowrap; }
  th:hover { text-decoration: underline; }
  td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
  tr:last-child td { border-bottom: none; }
  .empty { padding: 20px; text-align: center; color: #888; }
  .scan-note { font-size: 12px; color: #888; margin-top: 8px; }
  #dataArea { display: none; }

  /* ---- User lookup section ---- */
  .section { background: #fff; border: 1px solid #ddd; border-radius: 8px; padding: 12px 14px; margin-bottom: 14px; }
  .section > summary { cursor: pointer; font-weight: 600; font-size: 14px; }
  .section > summary .count { color: #888; font-weight: 400; font-size: 12px; margin-left: 4px; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; margin-left: 8px; vertical-align: middle; }
  .badge.live { background: #e6f4ea; color: #1e7e34; }
  .badge.archived { background: #fdecea; color: #a02020; }
  .badge.quarantined { background: #fff4e0; color: #a06a00; }
  .badge.knowledge { background: #e8eefc; color: #2b4fa0; }
  .lookup-box { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin-bottom: 14px; }
  .lookup-box input[type=text] { flex: 1 1 220px; padding: 8px 10px; border: 1px solid #ccc; border-radius: 6px; font-size: 14px; }
  .photo-grid { display: flex; flex-wrap: wrap; gap: 10px; }
  .photo-grid figure { margin: 0; width: 140px; }
  .photo-grid img { width: 140px; height: 140px; object-fit: cover; border-radius: 6px; border: 1px solid #ddd; display: block; background: #eee; }
  .photo-grid figcaption { font-size: 11px; color: #888; margin-top: 2px; word-break: break-all; }
  .chat-list { display: flex; flex-direction: column; gap: 6px; max-height: 420px; overflow-y: auto; padding: 8px; background: #fafafa; border-radius: 6px; }
  .bubble { max-width: 85%; padding: 6px 10px; border-radius: 10px; font-size: 13px; background: #fff; border: 1px solid #ddd; }
  .bubble .meta { font-size: 10px; color: #999; margin-bottom: 2px; }
  .json-table { border-collapse: collapse; width: 100%; font-size: 12px; }
  .json-table td { vertical-align: top; padding: 3px 6px; border-top: 1px solid #eee; }
  .json-table td.jkey { color: #666; white-space: nowrap; width: 170px; font-family: monospace; }
  .json-array-item { border-top: 1px solid #eee; padding: 3px 0; }
  .archive-list-item { padding: 6px 10px; border: 1px solid #ddd; border-radius: 6px; margin-bottom: 6px; display: flex; justify-content: space-between; align-items: center; gap: 10px; }
  .archive-list-item button { padding: 4px 10px; font-size: 12px; }
  .lookup-warn { background: #fdecea; color: #a02020; border: 1px solid #f2b8b5; padding: 8px 12px; border-radius: 6px; margin-bottom: 12px; font-size: 13px; }
  @media (prefers-color-scheme: dark) {
    .section, .bubble, .archive-list-item { background: #1e2126 !important; border-color: #333 !important; }
    .chat-list { background: #181a1e !important; }
    .json-table td { border-color: #333 !important; }
    .photo-grid img { background: #2a2d33; }
    .lookup-warn { background: #3a1c1c !important; color: #ff8a8a !important; border-color: #663 !important; }
    .badge.live { background: #16321f; color: #7fe3a0; }
    .badge.archived { background: #3a1c1c; color: #ff8a8a; }
    .badge.quarantined { background: #3a2c10; color: #ffcf7a; }
    .badge.knowledge { background: #1c2440; color: #9db4f5; }
  }
</style>
</head>
<body>
<div class="wrap">
  <h1>Ayma Admin — Provider Spend &amp; Usage</h1>
  <p class="sub">Every figure is fetched live from the provider that bills it (Google Cloud Billing export, LiveKit Analytics API), with its source and fetch time. A panel with no reachable source says "unavailable" and why. Internal tool — password not stored anywhere but this tab.</p>

  <div class="login">
    <input type="password" id="pw" placeholder="Admin password" autocomplete="off">
    <button id="loadBtn">Load dashboard</button>
    <button id="refreshBtn" class="refresh-btn" style="display:none;">Refresh</button>
    <span class="status muted" id="loginStatus"></span>
  </div>

  <div class="err" id="err"></div>

  <div id="dataArea">
    <h2>Feature flags (read-only)</h2>
    <div class="scan-note">Effective values. Source: env = FLAG_ override, firestore = config/feature_flags, default = code default. Change with scripts/flags.py.</div>
    <div id="flagList"></div>

    <h2>All vendors</h2>
    <div class="scan-note" id="vendorMeta"></div>
    <div id="vendorList"></div>

    <h2>Google Cloud spend</h2>
    <div class="scan-note" id="googleMeta"></div>
    <div class="cards" id="googleCards"></div>
    <h3>Month-to-date by service</h3>
    <div id="googleServices"></div>
    <h3>Gemini / Vertex AI cost per day (last 31 days)</h3>
    <div id="googleDaily"></div>
    <h3>Gemini / Vertex AI by SKU (month-to-date)</h3>
    <div id="googleSkus"></div>

    <h2 style="margin-top:32px;">LiveKit Cloud</h2>
    <div class="scan-note" id="livekitMeta"></div>
    <div class="cards" id="livekitCards"></div>
    <h3>LiveKit usage per day</h3>
    <div id="livekitDaily"></div>
  </div>

  <h1 style="margin-top:36px;">User Lookup — full data pull</h1>
  <p class="sub">Pull any user by UID: live account (profile, photos, appearance/deep-dive reports, stories, chats, skill runs, credits), an archived/deleted account, and any "delete everything Ayma knows" snapshots. Uses the same admin password entered above.</p>
  <div class="lookup-box">
    <input type="text" id="lookupUid" placeholder="UID or name" autocomplete="off">
    <button id="lookupBtn">Look up</button>
    <span class="status muted" id="lookupStatus"></span>
  </div>
  <div class="err" id="lookupErr"></div>
  <div id="lookupResults"></div>
</div>

<script>
(function () {
  var pwInput = document.getElementById('pw');
  var loadBtn = document.getElementById('loadBtn');
  var refreshBtn = document.getElementById('refreshBtn');
  var loginStatus = document.getElementById('loginStatus');
  var errBox = document.getElementById('err');
  var dataArea = document.getElementById('dataArea');
  // The password lives ONLY in this tab's sessionStorage once entered — never
  // hardcoded in this page's HTML/JS, never in a URL, never logged. The
  // visible <input> is never pre-filled from it on page load; sessionStorage
  // is read back only internally, by the "Refresh" button, to avoid
  // re-prompting mid-session.
  function storedPw() {
    try { return sessionStorage.getItem('ayma_admin_pw') || ''; }
    catch (e) { return ''; }
  }

  function showError(msg) {
    errBox.textContent = msg;
    errBox.classList.add('show');
    dataArea.style.display = 'none';
  }
  function clearError() {
    errBox.textContent = '';
    errBox.classList.remove('show');
  }
  function fmtMoney(n) {
    return '$' + Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 4 });
  }
  function fmtInt(n) {
    return Number(n).toLocaleString();
  }

  function el(tag, text, cls) {
    var e = document.createElement(tag);
    if (text != null) e.textContent = text;
    if (cls) e.className = cls;
    return e;
  }
  function card(label, value, note) {
    var c = el('div', null, 'card');
    c.appendChild(el('div', label, 'label'));
    c.appendChild(el('div', value, 'value'));
    if (note) c.appendChild(el('div', note, 'note'));
    return c;
  }
  function unavailableCard(label, reason) {
    return card(label, 'unavailable', reason || 'No reason reported.');
  }
  function table(host, headers, rows) {
    host.innerHTML = '';
    if (!rows.length) { host.appendChild(el('div', 'No rows returned by the source.', 'empty')); return; }
    var t = el('table');
    var thead = el('thead'), hr = el('tr');
    headers.forEach(function (h) { hr.appendChild(el('th', h.label, h.num ? 'num' : '')); });
    thead.appendChild(hr); t.appendChild(thead);
    var tb = el('tbody');
    rows.forEach(function (r) {
      var tr = el('tr');
      headers.forEach(function (h, i) { tr.appendChild(el('td', r[i], h.num ? 'num' : '')); });
      tb.appendChild(tr);
    });
    t.appendChild(tb); host.appendChild(t);
  }
  function fmtBytes(n) {
    var gb = Number(n) / 1073741824;
    return gb >= 0.01 ? gb.toFixed(2) + ' GB' : (Number(n) / 1048576).toFixed(2) + ' MB';
  }
  function reset(ids) { ids.forEach(function (i) { document.getElementById(i).innerHTML = ''; }); }

  function renderGoogle(g, fetchedAt) {
    reset(['googleCards', 'googleServices', 'googleDaily', 'googleSkus']);
    var meta = document.getElementById('googleMeta');
    var cards = document.getElementById('googleCards');
    if (!g || !g.available) {
      meta.textContent = 'Source: Google Cloud Billing export (BigQuery).';
      cards.appendChild(unavailableCard('Google Cloud spend', g && g.reason));
      return;
    }
    meta.textContent = 'Source: ' + g.source + '. Fetched ' + (g.fetched_at || fetchedAt) +
      '. Export data through ' + (g.data_through || 'unknown') + ' (the export lags real time by hours).';
    var cur = g.currency || 'USD';
    cards.appendChild(card('Month-to-date cost (' + g.month_start + ' on)', fmtMoney(g.mtd_total_cost), 'Sum of export cost, before credits. ' + cur));
    cards.appendChild(card('Credits applied (MTD)', fmtMoney(g.mtd_total_credits), 'Sum of export credits (negative = credit applied).'));
    cards.appendChild(card('Net after credits (MTD)', fmtMoney(g.mtd_total_net), 'Cost plus credits, as exported.'));
    table(document.getElementById('googleServices'),
      [{label: 'Service'}, {label: 'Cost', num: 1}, {label: 'Credits', num: 1}, {label: 'Net', num: 1}],
      (g.mtd_by_service || []).map(function (s) { return [s.service, fmtMoney(s.cost), fmtMoney(s.credits), fmtMoney(s.net)]; }));
    var svcs = g.ai_daily_services || [];
    table(document.getElementById('googleDaily'),
      [{label: 'Day'}].concat(svcs.map(function (s) { return {label: s, num: 1}; })),
      (g.ai_daily || []).map(function (d) { return [d.day].concat(svcs.map(function (s) { return fmtMoney(d[s] || 0); })); }));
    table(document.getElementById('googleSkus'),
      [{label: 'Service'}, {label: 'SKU'}, {label: 'Usage', num: 1}, {label: 'Unit'}, {label: 'Cost', num: 1}],
      (g.ai_skus_mtd || []).map(function (k) { return [k.service, k.sku, fmtInt(k.usage), k.unit, fmtMoney(k.cost)]; }));
    if (g.ai_note) document.getElementById('googleSkus').appendChild(el('div', g.ai_note, 'scan-note'));
  }

  function renderLivekit(l, fetchedAt) {
    reset(['livekitCards', 'livekitDaily']);
    var cards = document.getElementById('livekitCards');
    var u = (l && l.usage) || {};
    var b = (l && l.billing) || {};
    document.getElementById('livekitMeta').textContent =
      'Series tracked from ' + (l && l.tracking_started_at) + '. Source: LiveKit Cloud Analytics API. Fetched ' +
      ((l && l.fetched_at) || fetchedAt) + '.';
    if (u.available) {
      cards.appendChild(card('Participant minutes (WebRTC)', fmtInt(u.participant_minutes),
        'Sum of session connectionMinutes for ' + u.minutes_sessions_covered + ' of ' + u.sessions + ' sessions.'));
      cards.appendChild(card('Sessions', fmtInt(u.sessions), 'Since ' + u.window_start + '. ' + (u.note || '')));
      cards.appendChild(card('Bandwidth out / in', fmtBytes(u.bandwidth_out_bytes) + ' / ' + fmtBytes(u.bandwidth_in_bytes), 'Sum of session bandwidth.'));
      cards.appendChild(card('Sessions with egress', fmtInt(u.egress_sessions), 'Sessions whose egress flag is active or ended.'));
      table(document.getElementById('livekitDaily'),
        [{label: 'Day'}, {label: 'Sessions', num: 1}, {label: 'Participants', num: 1}, {label: 'Minutes', num: 1}, {label: 'Bandwidth', num: 1}],
        (u.daily || []).map(function (d) { return [d.day, fmtInt(d.sessions), fmtInt(d.participants), fmtInt(d.minutes), fmtBytes(d.bandwidth_bytes)]; }));
    } else {
      cards.appendChild(unavailableCard('Usage (participant minutes, bandwidth, egress)', u.reason));
    }
    ['Plan', 'Credit balance and expiry', 'Current invoice', 'Agent session minutes', 'Inference spend'].forEach(function (label) {
      cards.appendChild(unavailableCard(label, b.reason));
    });
  }

  function renderVendors(v) {
    var host = document.getElementById('vendorList');
    host.innerHTML = '';
    document.getElementById('vendorMeta').textContent =
      'Method badge: API = pulled from the provider; Muse = collected by the browser agent from the billing page. STALE = older than ' +
      v.stale_after_hours + 'h. No value shows "unavailable" with the reason.';
    var t = el('table');
    var hr = el('tr');
    ['Vendor', 'Billing unit', 'Scales with users', 'Value', 'How to check'].forEach(function (h) { hr.appendChild(el('th', h)); });
    var thead = el('thead'); thead.appendChild(hr); t.appendChild(thead);
    var tb = el('tbody');
    (v.vendors || []).forEach(function (r) {
      var tr = el('tr');
      var name = el('td', r.name);
      name.appendChild(el('div', r.group, 'muted'));
      if (r.status_note) name.appendChild(el('div', r.status_note, 'muted'));
      tr.appendChild(name);
      tr.appendChild(el('td', r.billing_unit));
      tr.appendChild(el('td', r.scales_with_users ? 'Yes' : 'No'));
      var val = el('td');
      if (!r.entries.length) {
        val.appendChild(el('div', 'unavailable: ' + (r.unavailable_reason || 'no reason reported'), 'vendor-unavail'));
      }
      r.entries.forEach(function (e) {
        var line = el('div', null, 'vendor-entry');
        var amt = e.unit === 'USD' ? fmtMoney(e.amount) : Number(e.amount).toLocaleString() + ' ' + e.unit;
        line.appendChild(document.createTextNode(e.metric + ': ' + amt + ' (' + e.period + ') '));
        line.appendChild(el('span', e.method === 'api' ? 'API' : 'Muse', 'badge ' + (e.method === 'api' ? 'api' : 'muse')));
        if (e.stale) line.appendChild(el('span', 'STALE', 'badge stale'));
        line.appendChild(el('div', 'fetched ' + (e.fetched_at || 'unknown') + (e.note ? ' - ' + e.note : ''), 'muted'));
        val.appendChild(line);
      });
      tr.appendChild(val);
      var how = el('td');
      var d = el('details', null, 'how');
      d.appendChild(el('summary', 'Steps'));
      var ol = el('ol');
      r.how_to_check.steps.forEach(function (s) { ol.appendChild(el('li', s)); });
      d.appendChild(ol);
      var a = el('a', 'Open billing / usage page');
      a.href = r.how_to_check.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
      d.appendChild(a);
      how.appendChild(d);
      tr.appendChild(how);
      tb.appendChild(tr);
    });
    t.appendChild(tb); host.appendChild(t);
  }

  function renderFlags(d) {
    var host = document.getElementById('flagList');
    host.innerHTML = '';
    var t = el('table');
    var hr = el('tr');
    ['Flag', 'Value', 'Source', 'What it does'].forEach(function (h) { hr.appendChild(el('th', h)); });
    var thead = el('thead'); thead.appendChild(hr); t.appendChild(thead);
    var tb = el('tbody');
    Object.keys(d.flags || {}).forEach(function (name) {
      var f = d.flags[name];
      var tr = el('tr');
      tr.appendChild(el('td', name));
      tr.appendChild(el('td', Array.isArray(f.value) ? f.value.join(', ') || '(none)' : String(f.value)));
      tr.appendChild(el('td', f.source));
      tr.appendChild(el('td', f.description));
      tb.appendChild(tr);
    });
    t.appendChild(tb); host.appendChild(t);
  }

  function loadFlags(pw) {
    return fetch('/admin/feature-flags', { headers: { 'X-Admin-Password': pw } }).then(function (res) {
      if (!res.ok) { throw new Error('Feature flags failed (' + res.status + ').'); }
      return res.json();
    }).then(renderFlags);
  }

  function loadVendors(pw) {
    return fetch('/admin/vendors', { headers: { 'X-Admin-Password': pw } }).then(function (res) {
      if (!res.ok) { throw new Error('Vendor list failed (' + res.status + ').'); }
      return res.json();
    }).then(renderVendors);
  }

  function loadProviderSpend(pw) {
    return fetch('/admin/provider-spend', {
      headers: { 'X-Admin-Password': pw }
    }).then(function (res) {
      if (res.status === 403) { throw new Error('Wrong admin password (403). Nothing loaded.'); }
      if (!res.ok) { throw new Error('Server error (' + res.status + '). Nothing loaded.'); }
      return res.json();
    }).then(function (d) {
      renderGoogle(d.google, d.fetched_at);
      renderLivekit(d.livekit, d.fetched_at);
    });
  }

  function load(pw) {
    if (!pw) {
      showError('Enter the admin password first.');
      return;
    }
    try { sessionStorage.setItem('ayma_admin_pw', pw); } catch (e) { /* ignore */ }

    clearError();
    loginStatus.textContent = 'Loading…';
    dataArea.style.display = 'none';

    Promise.all([loadProviderSpend(pw), loadVendors(pw), loadFlags(pw)]).then(function () {
      loginStatus.textContent = 'Loaded.';
      refreshBtn.style.display = '';
      dataArea.style.display = 'block';
    }).catch(function (err) {
      loginStatus.textContent = '';
      refreshBtn.style.display = 'none';
      showError(err.message || String(err));
    });
  }

  loadBtn.addEventListener('click', function () { load(pwInput.value); });
  refreshBtn.addEventListener('click', function () { load(storedPw()); });
  pwInput.addEventListener('keydown', function (e) {
    if (e.key === 'Enter') load(pwInput.value);
  });

  // =====================================================================
  // User lookup — pull any user's full data (founder request 2026-09-20):
  // live account, archived/deleted account, and "delete everything Ayma
  // knows" snapshots. Reuses the same X-Admin-Password gate (storedPw())
  // as the finance panel above — nothing here is reachable without it,
  // since every fetch below hits a require_admin_password route.
  // =====================================================================
  var lookupInput = document.getElementById('lookupUid');
  var lookupBtn = document.getElementById('lookupBtn');
  var lookupStatus = document.getElementById('lookupStatus');
  var lookupErr = document.getElementById('lookupErr');
  var lookupResults = document.getElementById('lookupResults');
  var mediaUrlCache = {};

  function lookupShowError(msg) {
    lookupErr.textContent = msg;
    lookupErr.classList.add('show');
  }
  function lookupClearError() {
    lookupErr.textContent = '';
    lookupErr.classList.remove('show');
  }

  // Same 403-on-wrong-password / never-log-the-password discipline as
  // load() above — the password only ever travels as this header.
  function adminFetch(pw, path) {
    return fetch(path, { headers: { 'X-Admin-Password': pw } }).then(function (res) {
      if (res.status === 403) throw new Error('Wrong admin password (403).');
      if (!res.ok && res.status !== 404) {
        throw new Error(path + ': server error (' + res.status + ').');
      }
      return res.status === 404 ? null : res.json();
    });
  }

  function mediaUrl(pw, path) {
    if (!path) return Promise.resolve(null);
    if (mediaUrlCache[path]) return mediaUrlCache[path];
    var p = adminFetch(pw, '/admin/media-url?path=' + encodeURIComponent(path))
      .then(function (d) { return d && d.url; })
      .catch(function () { return null; });
    mediaUrlCache[path] = p;
    return p;
  }

  function mk(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  }

  function byMediaId(rows) {
    var m = {};
    (rows || []).forEach(function (r) { m[r.id] = r; });
    return m;
  }

  // Generic, schema-drift-proof renderer: any nested dict/list of
  // primitives becomes a collapsible-friendly table/list. Used both as the
  // catch-all for fields not given bespoke treatment below, and inside
  // the bespoke sections for their own nested structures (e.g. an
  // appearance report's face/body/attributes objects).
  function renderJson(container, value) {
    if (value === null || value === undefined || value === '') {
      container.appendChild(document.createTextNode('—'));
      return;
    }
    if (typeof value !== 'object') {
      container.appendChild(document.createTextNode(String(value)));
      return;
    }
    if (Array.isArray(value)) {
      if (!value.length) { container.appendChild(document.createTextNode('[]')); return; }
      var wrap = mk('div');
      value.forEach(function (item) {
        var row = mk('div', 'json-array-item');
        renderJson(row, item);
        wrap.appendChild(row);
      });
      container.appendChild(wrap);
      return;
    }
    var keys = Object.keys(value);
    if (!keys.length) { container.appendChild(document.createTextNode('{}')); return; }
    var table = mk('table', 'json-table');
    keys.forEach(function (k) {
      var tr = document.createElement('tr');
      var tdVal = document.createElement('td');
      tdVal.className = 'jval';
      renderJson(tdVal, value[k]);
      tr.appendChild(mk('td', 'jkey', k));
      tr.appendChild(tdVal);
      table.appendChild(tr);
    });
    container.appendChild(table);
  }

  function sectionBox(title, count) {
    var details = document.createElement('details');
    details.className = 'section';
    details.open = true;
    var summary = document.createElement('summary');
    summary.appendChild(document.createTextNode(title + ' '));
    if (count !== undefined) summary.appendChild(mk('span', 'count', '(' + count + ')'));
    details.appendChild(summary);
    return details;
  }

  function renderPhotosSection(pw, profileRows, userMediaRows) {
    var profile = (profileRows && profileRows[0]) || {};
    var photos = profile.photos || [];
    var mediaById = byMediaId(userMediaRows);
    var sec = sectionBox('Photos', (userMediaRows || []).length);
    var grid = mk('div', 'photo-grid');
    sec.appendChild(grid);

    var shown = {};
    photos.slice().sort(function (a, b) { return (a.order || 0) - (b.order || 0); })
      .forEach(function (p) {
        shown[p.media_id] = true;
        addPhotoFigure(grid, pw, p.media_id, mediaById[p.media_id], 'profile #' + p.order);
      });
    (userMediaRows || []).forEach(function (m) {
      if (shown[m.id]) return;
      addPhotoFigure(grid, pw, m.id, m, m.moderation_status || 'not in grid');
    });
    if (!(userMediaRows || []).length) grid.appendChild(mk('div', 'muted', 'No photos.'));
    return sec;
  }

  function addPhotoFigure(grid, pw, mediaId, mediaDoc, caption) {
    var fig = mk('figure');
    var img = document.createElement('img');
    img.alt = mediaId;
    fig.appendChild(img);
    fig.appendChild(mk('figcaption', null, caption + ' · ' + mediaId));
    grid.appendChild(fig);
    var path = mediaDoc && (mediaDoc.storage_path || mediaDoc.path);
    if (!path) { img.replaceWith(mk('div', 'muted', 'no storage_path on file')); return; }
    mediaUrl(pw, path).then(function (url) {
      if (url) { img.src = url; } else { img.replaceWith(mk('div', 'muted', 'image unavailable')); }
    });
  }

  function renderChatBubbles(list, kind) {
    var wrap = mk('div', 'chat-list');
    (list || []).slice().sort(function (a, b) {
      return String(a.created_at || '').localeCompare(String(b.created_at || ''));
    }).forEach(function (m) {
      var bubble = mk('div', 'bubble');
      var who = kind === 'dm' ? (m.sender_uid || '?') : (m.role || '?');
      var text = kind === 'dm' ? m.body : m.text;
      bubble.appendChild(mk('div', 'meta', who + (m.created_at ? ' · ' + m.created_at : '')));
      bubble.appendChild(document.createTextNode(text || ''));
      wrap.appendChild(bubble);
    });
    if (!(list || []).length) wrap.appendChild(mk('div', 'muted', 'No messages.'));
    return wrap;
  }

  function renderDmThreads(title, threads, msgKey) {
    var sec = sectionBox(title, (threads || []).length);
    (threads || []).forEach(function (t) {
      var box = mk('div');
      box.style.marginBottom = '14px';
      box.appendChild(mk('div', null,
        'Thread ' + (t.id || '') + ' — participants: ' + ((t.participants || []).join(', '))));
      box.appendChild(renderChatBubbles(t[msgKey || 'messages'] || [], 'dm'));
      sec.appendChild(box);
    });
    if (!(threads || []).length) sec.appendChild(mk('div', 'muted', 'No DM threads.'));
    return sec;
  }

  function renderWikiPages(pages) {
    var sec = sectionBox('Stories (wiki pages)', (pages || []).length);
    (pages || []).forEach(function (p) {
      var box = mk('div');
      box.style.marginBottom = '12px';
      box.appendChild(mk('div', null,
        (p.id || '') + ' · ' + (p.page_type || '') + ' · visibility: ' + (p.visibility || '') +
        (p.user_hidden ? ' · hidden by user' : '')));
      if (p.ai_body) box.appendChild(mk('div', 'muted', 'AI: ' + p.ai_body));
      if (p.user_edits) box.appendChild(mk('div', 'muted', 'User edit: ' + p.user_edits));
      if (p.versions && p.versions.length) {
        box.appendChild(mk('div', 'muted', p.versions.length + ' version(s) in history'));
      }
      if (p.lint_flags && p.lint_flags.length) {
        box.appendChild(mk('div', 'muted', 'lint flags: ' + p.lint_flags.join(', ')));
      }
      sec.appendChild(box);
    });
    if (!(pages || []).length) sec.appendChild(mk('div', 'muted', 'No story pages.'));
    return sec;
  }

  function renderGenericList(title, rows) {
    var sec = sectionBox(title, (rows || []).length);
    renderJson(sec, rows || []);
    return sec;
  }

  function renderSummaryCard(uid, account, profileRows, badgeText, badgeClass) {
    var profile = (profileRows && profileRows[0]) || {};
    var card = mk('div', 'card');
    var h = mk('div');
    h.appendChild(mk('strong', null, profile.name || '(no name)'));
    h.appendChild(document.createTextNode(' — ' + uid));
    if (badgeText) h.appendChild(mk('span', 'badge ' + badgeClass, badgeText));
    card.appendChild(h);
    var kv = mk('table', 'json-table');
    [['community', account.community], ['session_mode', account.session_mode],
     ['paused', profile.paused], ['gender', profile.gender], ['location', profile.location],
     ['trust_flags', (account.trust_flags || []).length]].forEach(function (pair) {
      var tr = document.createElement('tr');
      var td = document.createElement('td');
      td.textContent = pair[1] === undefined || pair[1] === null ? '—' : String(pair[1]);
      tr.appendChild(mk('td', 'jkey', pair[0]));
      tr.appendChild(td);
      kv.appendChild(tr);
    });
    card.appendChild(kv);
    return card;
  }

  function renderCreditsCard(c) {
    var sec = sectionBox('Credits & usage', undefined);
    var kv = mk('table', 'json-table');
    [['total tokens', c.total], ['real cost ($)', c.cost_usd],
     ['credits grant', c.credits && c.credits.grant], ['credits added', c.credits && c.credits.added],
     ['credits used', c.credits && c.credits.used], ['credits remaining', c.credits && c.credits.remaining]]
      .forEach(function (pair) {
        var tr = document.createElement('tr');
        var td = document.createElement('td');
        td.textContent = pair[1] === undefined || pair[1] === null ? '—' : String(pair[1]);
        tr.appendChild(mk('td', 'jkey', pair[0]));
        tr.appendChild(td);
        kv.appendChild(tr);
      });
    sec.appendChild(kv);
    return sec;
  }

  // Keys given bespoke rendering below — everything else (raw_turns,
  // pending_questions, questionnaire, completeness_cache, photo_notes, the
  // appearance/physical "current" pointers, physical_reports, face_reports,
  // body_reports, oauth_tokens, notifications, notification_prefs,
  // match_candidates, likes, explore_passed, tier, recovery_pending, etc.)
  // still lands in the catch-all "Other raw data" tree below — nothing is
  // silently dropped even as the schema evolves.
  var HANDLED_KEYS = {
    uid: 1, exists: 1, found: 1, account: 1, profile: 1, user_media: 1,
    wiki_pages: 1, dm_threads: 1, dm_threads_snapshot: 1, chat_messages: 1,
    matches: 1, matches_snapshot: 1, blocks: 1, feedback: 1, product_feedback: 1,
    bug_reports: 1, appearance_reports: 1, deep_dives: 1, skill_runs: 1,
    identity_mappings: 1
  };

  function renderDetail(pw, uid, detail, badgeText, badgeClass) {
    var out = mk('div');
    out.appendChild(renderSummaryCard(uid, detail.account || {}, detail.profile, badgeText, badgeClass));
    out.appendChild(renderPhotosSection(pw, detail.profile, detail.user_media));
    if (detail.appearance_reports) out.appendChild(renderGenericList('Appearance report (score + findings)', detail.appearance_reports));
    if (detail.deep_dives) out.appendChild(renderGenericList('Deep-dive / web-search report', detail.deep_dives));
    if (detail.wiki_pages) out.appendChild(renderWikiPages(detail.wiki_pages));
    if (detail.chat_messages) {
      var csec = sectionBox('AI companion chat transcript', detail.chat_messages.length);
      csec.appendChild(renderChatBubbles(detail.chat_messages, 'ai'));
      out.appendChild(csec);
    }
    if (detail.dm_threads) out.appendChild(renderDmThreads('DM chats with other users', detail.dm_threads, 'messages'));
    if (detail.dm_threads_snapshot) out.appendChild(renderDmThreads('DM chats with other users (at time of deletion)', detail.dm_threads_snapshot, 'messages'));
    if (detail.skill_runs) out.appendChild(renderGenericList('Skill-run history', detail.skill_runs));
    if (detail.matches) out.appendChild(renderGenericList('Matches', detail.matches));
    if (detail.matches_snapshot) out.appendChild(renderGenericList('Matches (at time of deletion)', detail.matches_snapshot));
    if (detail.blocks) out.appendChild(renderGenericList('Blocks', detail.blocks));
    if (detail.identity_mappings) out.appendChild(renderGenericList('Linked identities', detail.identity_mappings));
    ['feedback', 'product_feedback', 'bug_reports'].forEach(function (k) {
      if (detail[k] && detail[k].length) out.appendChild(renderGenericList(k, detail[k]));
    });
    var rest = {};
    Object.keys(detail).forEach(function (k) { if (!HANDLED_KEYS[k]) rest[k] = detail[k]; });
    if (Object.keys(rest).length) {
      var sec = sectionBox('Other raw data', Object.keys(rest).length);
      renderJson(sec, rest);
      out.appendChild(sec);
    }
    return out;
  }

  function renderArchiveList(pw, uid, archives) {
    var sec = sectionBox('"Delete everything Ayma knows" snapshots', archives.length);
    if (!archives.length) {
      sec.appendChild(mk('div', 'muted', 'No knowledge-wipe snapshots for this uid.'));
      return sec;
    }
    archives.forEach(function (a) {
      var row = mk('div', 'archive-list-item');
      row.appendChild(mk('span', null, (a.archive_id || '') + ' · archived_at: ' + (a.archived_at || '—')));
      var btn = mk('button', 'refresh-btn', 'View');
      var body = mk('div');
      body.hidden = true;
      btn.addEventListener('click', function () {
        if (!body.hidden) { body.hidden = true; return; }
        body.hidden = false;
        if (body.childNodes.length) return;
        body.appendChild(mk('div', 'muted', 'Loading…'));
        adminFetch(pw, '/admin/knowledge-archives/' + encodeURIComponent(uid) + '/' + encodeURIComponent(a.archive_id))
          .then(function (d) {
            body.innerHTML = '';
            if (!d) { body.appendChild(mk('div', 'muted', 'Not found.')); return; }
            body.appendChild(renderDetail(pw, uid, d, 'SNAPSHOT', 'knowledge'));
          })
          .catch(function (err) {
            body.innerHTML = '';
            body.appendChild(mk('div', 'muted', err.message || String(err)));
          });
      });
      row.appendChild(btn);
      sec.appendChild(row);
      sec.appendChild(body);
    });
    return sec;
  }

  function renderCandidatePicker(pw, candidates) {
    var box = sectionBox('Multiple matches — pick one', candidates.length);
    candidates.forEach(function (c) {
      var row = mk('div', 'archive-list-item');
      row.appendChild(mk('span', null, (c.name || '(no name)') + ' — ' + c.uid + ' · ' + (c.community || '')));
      var btn = mk('button', 'refresh-btn', 'Open');
      btn.addEventListener('click', function () { pullUser(pw, c.uid); });
      row.appendChild(btn);
      box.appendChild(row);
    });
    lookupResults.appendChild(box);
  }

  function pullUser(pw, uid) {
    lookupInput.value = uid;
    lookupStatus.textContent = 'Loading ' + uid + '…';
    lookupResults.innerHTML = '';

    Promise.all([
      adminFetch(pw, '/admin/users/' + encodeURIComponent(uid) + '/full'),
      adminFetch(pw, '/admin/archived-accounts/' + encodeURIComponent(uid)),
      adminFetch(pw, '/admin/knowledge-archives/' + encodeURIComponent(uid)),
      adminFetch(pw, '/admin/users/' + encodeURIComponent(uid) + '/credits').catch(function () { return null; })
    ]).then(function (results) {
      var live = results[0], archived = results[1], archivesResp = results[2], credits = results[3];
      lookupStatus.textContent = 'Loaded.';
      lookupResults.innerHTML = '';

      if (live && live.exists) {
        lookupResults.appendChild(renderDetail(pw, uid, live, 'LIVE', 'live'));
        if (credits) lookupResults.appendChild(renderCreditsCard(credits));
      } else if (archived && archived.found) {
        lookupResults.appendChild(mk('div', 'lookup-warn',
          'This account is ARCHIVED / DELETED (tier: ' + archived.tier + '). Showing archived data below — clearly not a live account.'));
        lookupResults.appendChild(renderDetail(pw, uid, archived, archived.tier.toUpperCase(), archived.tier));
      } else {
        lookupResults.appendChild(mk('div', 'muted', 'No live or archived account found for uid "' + uid + '".'));
      }

      var archives = (archivesResp && archivesResp.archives) || [];
      lookupResults.appendChild(renderArchiveList(pw, uid, archives));
    }).catch(function (err) {
      lookupStatus.textContent = '';
      lookupShowError(err.message || String(err));
    });
  }

  function runLookup() {
    var pw = storedPw();
    var query = (lookupInput.value || '').trim();
    if (!pw) { lookupShowError('Enter the admin password above first.'); return; }
    if (!query) { lookupShowError('Enter a UID or a name to search.'); return; }
    lookupClearError();
    lookupStatus.textContent = 'Searching…';
    lookupResults.innerHTML = '';

    adminFetch(pw, '/admin/users?q=' + encodeURIComponent(query)).then(function (d) {
      var candidates = (d && d.users) || [];
      if (candidates.length === 1) {
        pullUser(pw, candidates[0].uid);
      } else if (candidates.length > 1) {
        lookupStatus.textContent = candidates.length + ' matches.';
        renderCandidatePicker(pw, candidates);
      } else {
        // No live uid/name match (admin.search_users only scans the live
        // `users` collection) — the uid may still exist only as an
        // archived/deleted account or a knowledge-wipe snapshot, so fall
        // back to treating the query as a literal uid.
        pullUser(pw, query);
      }
    }).catch(function (err) {
      lookupStatus.textContent = '';
      lookupShowError(err.message || String(err));
    });
  }

  lookupBtn.addEventListener('click', runLookup);
  lookupInput.addEventListener('keydown', function (e) { if (e.key === 'Enter') runLookup(); });
})();
</script>
</body>
</html>
"""
