"""Static HTML for the ``/admin`` finance dashboard (ARCHITECTURE.md §14.3).

Plain HTML/CSS/vanilla JS, no build step, no external framework — this is a
one-person internal ops tool (the founder), so legibility beats polish. The
page itself is served with no auth (it's inert without a valid password); the
data it calls (``/admin/finance-summary``, ``/admin/users``) stays behind the
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
</style>
</head>
<body>
<div class="wrap">
  <h1>Ayma Admin — Finance &amp; Usage</h1>
  <p class="sub">Real infra $ cost, token usage, and per-user breakdown. Internal tool — password not stored anywhere but this tab.</p>

  <div class="login">
    <input type="password" id="pw" placeholder="Admin password" autocomplete="off">
    <button id="loadBtn">Load dashboard</button>
    <button id="refreshBtn" class="refresh-btn" style="display:none;">Refresh</button>
    <span class="status muted" id="loginStatus"></span>
  </div>

  <div class="err" id="err"></div>

  <div id="dataArea">
    <div class="cards">
      <div class="card">
        <div class="label">Total real cost (lifetime)</div>
        <div class="value" id="totalCost">—</div>
        <div class="note">Sum of every user's <code>cost_usd</code></div>
      </div>
      <div class="card">
        <div class="label">Total tokens (lifetime)</div>
        <div class="value" id="totalTokens">—</div>
        <div class="note" id="userCountNote"></div>
      </div>
      <div class="card revenue">
        <div class="label">Revenue</div>
        <div class="value" id="revenue">$0</div>
        <div class="note" id="revenueNote">Free during beta — no payments processed yet.</div>
      </div>
    </div>

    <table id="userTable">
      <thead>
        <tr>
          <th data-key="uid">UID</th>
          <th data-key="name">Name</th>
          <th class="num" data-key="total_tokens">Tokens</th>
          <th class="num" data-key="cost_usd">Cost ($)</th>
          <th class="num" data-key="credits_used">Credits used</th>
        </tr>
      </thead>
      <tbody id="userRows"></tbody>
    </table>
    <div class="scan-note" id="scanNote"></div>
  </div>
</div>

<script>
(function () {
  var pwInput = document.getElementById('pw');
  var loadBtn = document.getElementById('loadBtn');
  var refreshBtn = document.getElementById('refreshBtn');
  var loginStatus = document.getElementById('loginStatus');
  var errBox = document.getElementById('err');
  var dataArea = document.getElementById('dataArea');
  var rowsData = [];
  var sortKey = 'cost_usd';
  var sortDesc = true;

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
    return '$' + Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 6 });
  }
  function fmtInt(n) {
    return Number(n).toLocaleString();
  }

  function renderRows() {
    var sorted = rowsData.slice().sort(function (a, b) {
      var av = a[sortKey], bv = b[sortKey];
      if (typeof av === 'string') { av = av.toLowerCase(); bv = (bv || '').toLowerCase(); }
      if (av < bv) return sortDesc ? 1 : -1;
      if (av > bv) return sortDesc ? -1 : 1;
      return 0;
    });
    var tbody = document.getElementById('userRows');
    tbody.innerHTML = '';
    if (!sorted.length) {
      var tr = document.createElement('tr');
      var td = document.createElement('td');
      td.colSpan = 5;
      td.className = 'empty';
      td.textContent = 'No recorded usage yet.';
      tr.appendChild(td);
      tbody.appendChild(tr);
      return;
    }
    sorted.forEach(function (u) {
      var tr = document.createElement('tr');
      tr.innerHTML =
        '<td></td><td></td>' +
        '<td class="num"></td><td class="num"></td><td class="num"></td>';
      var cells = tr.children;
      cells[0].textContent = u.uid || '';
      cells[1].textContent = u.name || '';
      cells[2].textContent = fmtInt(u.total_tokens || 0);
      cells[3].textContent = fmtMoney(u.cost_usd || 0);
      cells[4].textContent = fmtInt(u.credits_used || 0);
      tbody.appendChild(tr);
    });
  }

  document.querySelectorAll('#userTable th[data-key]').forEach(function (th) {
    th.addEventListener('click', function () {
      var key = th.getAttribute('data-key');
      if (sortKey === key) { sortDesc = !sortDesc; } else { sortKey = key; sortDesc = true; }
      renderRows();
    });
  });

  function load(pw) {
    if (!pw) {
      showError('Enter the admin password first.');
      return;
    }
    try { sessionStorage.setItem('ayma_admin_pw', pw); } catch (e) { /* ignore */ }

    clearError();
    loginStatus.textContent = 'Loading…';
    dataArea.style.display = 'none';

    fetch('/admin/finance-summary', {
      headers: { 'X-Admin-Password': pw }
    }).then(function (res) {
      if (res.status === 403) {
        throw new Error('Wrong admin password (403). Nothing loaded.');
      }
      if (!res.ok) {
        throw new Error('Server error (' + res.status + '). Nothing loaded.');
      }
      return res.json();
    }).then(function (data) {
      loginStatus.textContent = 'Loaded.';
      refreshBtn.style.display = '';
      document.getElementById('totalCost').textContent = fmtMoney(data.total_cost_usd || 0);
      document.getElementById('totalTokens').textContent = fmtInt(data.total_tokens || 0);
      document.getElementById('userCountNote').textContent =
        data.user_count + ' user(s) scanned';
      document.getElementById('revenue').textContent = '$' + (data.revenue_usd || 0);
      document.getElementById('revenueNote').textContent =
        data.revenue_note || 'Free during beta — no payments processed yet.';
      document.getElementById('scanNote').textContent =
        'Bounded scan: up to ' + data.scanned_limit + ' user docs. ' +
        (data.user_count >= data.scanned_limit
          ? 'Scan limit reached — totals may be incomplete as the user base grows.'
          : 'Covers every user.');
      rowsData = data.users || [];
      renderRows();
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
})();
</script>
</body>
</html>
"""
