const test = require('node:test');
const assert = require('node:assert');
const app = require('../src/app');

test('GET /api/health returns ok without a database', async () => {
  const server = app.listen(0);
  const { port } = server.address();
  try {
    const res = await fetch(`http://127.0.0.1:${port}/api/health`);
    assert.strictEqual(res.status, 200);
    assert.deepStrictEqual(await res.json(), { status: 'ok' });
  } finally {
    server.close();
  }
});

test('GET /api/info reports version and backend', async () => {
  const server = app.listen(0);
  const { port } = server.address();
  try {
    const body = await (await fetch(`http://127.0.0.1:${port}/api/info`)).json();
    assert.ok(body.version);
    assert.ok(body.servedBy);
  } finally {
    server.close();
  }
});

