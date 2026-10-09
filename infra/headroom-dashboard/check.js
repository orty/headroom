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
    // The auth layer in front of Caddy answers 403 to signed-in POSTs (no
    // `Server: Caddy`), so they never reach Caddy or Headroom; 404 would be Caddy's.
    ['POST', '/stats', [403, 404]],
    ['POST', '/v1/messages', [403, 404]],
    ['GET', '/v1/models', 404],
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
