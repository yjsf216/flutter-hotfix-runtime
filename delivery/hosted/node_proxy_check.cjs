const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const createProxy = require('./node_proxy.cjs');

test('fixed loopback proxy forwards upload auth, strips cookies and blocks unrelated routes', async () => {
  const seen = [];
  const backend = http.createServer((req, res) => {
    let body = '';
    req.on('data', data => { body += data; });
    req.on('end', () => {
      seen.push({ path: req.url, headers: req.headers, body });
      res.setHeader('Content-Type', 'application/json');
      res.setHeader('Set-Cookie', 'must-not-forward=true');
      res.end('{"status":"uploaded"}');
    });
  });
  await new Promise(resolve => backend.listen(0, '127.0.0.1', resolve));
  const gateway = http.createServer(createProxy(backend.address().port));
  await new Promise(resolve => gateway.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${gateway.address().port}`;
  try {
    const response = await fetch(origin + '/uploads', { method: 'POST',
      headers: { authorization: 'Bearer test-credential', cookie: 'business-session=private' }, body: 'test' });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('set-cookie'), null);
    assert.deepEqual(await response.json(), { status: 'uploaded' });
    assert.equal(seen[0].path, '/v1/uploads');
    assert.equal(seen[0].headers.authorization, 'Bearer test-credential');
    assert.equal(seen[0].headers.cookie, undefined);
    assert.equal(seen[0].body, 'test');
    for (const path of ['/releases', '/arbitrary', '//example.com/uploads']) {
      assert.equal((await fetch(origin + path, { method: 'POST' })).status, 404);
    }
    assert.equal(seen.length, 1);
    const baseline = 'a'.repeat(64);
    for (const [method, path] of [['GET', '/baselines'], ['POST', '/baselines'], ['POST', '/patch-numbers'],
      ['POST', `/baselines/${baseline}/chunks/0`], ['POST', `/baselines/${baseline}/finish`],
      ['POST', `/baselines/${baseline}/delete`], ['POST', `/baselines/${baseline}/restore`],
      ['GET', '/uploads?includeDeleted=1'], ['POST', `/uploads/${baseline}/patch-1/delete`],
      ['POST', `/uploads/${baseline}/patch-1/restore`], ['GET', '/retention'],
      ['POST', '/retention/register'], ['POST', '/retention/lease'],
      ['POST', '/retention/reconcile'], ['POST', '/retention/cleanup']]) {
      assert.equal((await fetch(origin + path, { method })).status, 200);
      assert.equal(seen.at(-1).path, '/v1' + path);
    }
    for (const path of ['/baselines/invalid/finish', `/baselines/${baseline}/purge`,
      `/baselines/${baseline}/chunks/-1`, `/uploads/${baseline}/patch-1/purge`,
      '/uploads/invalid/patch-1/delete', `/uploads/${baseline}/patch%2F1/delete`, '/retention/enable']) {
      assert.equal((await fetch(origin + path, { method: 'POST' })).status, 404);
    }
  } finally {
    gateway.closeAllConnections(); backend.closeAllConnections();
    await Promise.all([new Promise(r => gateway.close(r)), new Promise(r => backend.close(r))]);
  }
});
