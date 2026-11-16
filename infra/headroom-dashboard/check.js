// Authenticated checks for headroom-dashboard (see README.md "Checks").
// Sign in on the dashboard host, then paste this into the DevTools console.
(async () => {
  const cases = [
    ['GET', '/', 200],
    ['GET', '/dashboard', 200],
    ['GET', '/dashboard/static/alpine.min.js', 200],
    ['GET', '/stats?cached=1', 200],
    ['GET', '/stats-history', 200],
    ['GET', '/stats-lifetime', 200],
    ['GET', '/health', 200],
    ['HEAD', '/dashboard', 404],
    // Easy Auth answers 403 to signed-in fetch() POSTs on its own routes; 404 is Envoy's.
    ['POST', '/stats', [403, 404]],
    // API routes skip Easy Auth: a browser session is not an Entra access token,
    // so Envoy answers 401 (the session cookie never counts there).
    ['POST', '/v1/messages', 401],
    ['GET', '/v1/models', 401],
    ['GET', '/settings/schema', 404],
    ['GET', '/transformations/feed', 404],
  ];
  const rows = [];
  for (const [method, path, want] of cases) {
    const r = await fetch(path, { method, redirect: 'manual', cache: 'no-store' });
    const ok = [].concat(want).includes(r.status);
    rows.push({ method, path, want: String(want), got: r.status, result: ok ? 'PASS' : 'FAIL' });
  }
  console.table(rows);
  console.log(rows.every(r => r.result === 'PASS') ? 'ALL PASS' : 'SOME FAILED');
})();
