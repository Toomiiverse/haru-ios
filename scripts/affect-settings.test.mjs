import http from 'node:http';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

let writes = 0;
let statusReads = 0;
const snapshot = {
  version: 1, enabled: true, revision: 7,
  preferences: { reactToConversation: true, allowDecline: true },
  current: { emotion: 'curious', disposition: 'engage', episodes: [{ emotion: 'interest', intensity: 0.4 }, { emotion: 'longing', intensity: 0.6 }], mood: { pleasantness: 0.7, activation: 0.6, tension: 0.2, energy: 0.8, sleepiness: 0.1 } },
  controls: [{ key: 'reactToConversation', label: 'React to conversation', description: 'A server-authored description.' }],
};
const server = http.createServer(async (req, res) => {
  if (req.url === '/status-test/api/affect/settings') {
    assert.equal(req.method, 'GET', 'Status must never write affect preferences');
    const read = ++statusReads;
    if (read === 3) { res.writeHead(503); return res.end('unavailable'); }
    const value = structuredClone(snapshot);
    value.current.emotion = read === 1 ? 'happy' : 'worried';
    if (read === 4) { value.enabled = false; value.current.episodes = []; }
    res.setHeader('Content-Type', 'application/json');
    if (read === 1) return setTimeout(() => res.end(JSON.stringify(value)), 250);
    return res.end(JSON.stringify(value));
  }
  assert.equal(req.url, '/api/affect/settings');
  res.setHeader('Content-Type', 'application/json');
  if (req.method === 'GET') return res.end(JSON.stringify(snapshot));
  assert.equal(req.method, 'POST');
  assert.equal(req.headers['x-haru-affect-ui'], '1');
  assert.equal(req.headers['content-type'], 'application/json');
  let body = '';
  for await (const chunk of req) body += chunk;
  const command = JSON.parse(body);
  assert.deepEqual(Object.keys(command).sort(), ['expectedRevision', 'preferences']);
  assert.deepEqual(command.preferences, { reactToConversation: false, allowDecline: true });
  writes++;
  if (writes === 1) {
    assert.equal(command.expectedRevision, 7);
    snapshot.revision = 8;
    snapshot.preferences = command.preferences;
    return res.end(JSON.stringify(snapshot));
  }
  const status = writes === 2 ? 409 : 401;
  assert.equal(command.expectedRevision, writes === 2 ? 7 : 8);
  res.writeHead(status);
  res.end(JSON.stringify({ error: status === 409 ? 'affect_settings_unconfirmed' : 'Sign in first.' }));
});
server.listen(0, '127.0.0.1', () => {
  const child = spawn(process.argv[2], [`http://127.0.0.1:${server.address().port}`], { stdio: 'inherit' });
  const timeout = setTimeout(() => child.kill(), 30000);
  child.on('exit', code => {
    clearTimeout(timeout);
    server.closeAllConnections();
    server.close();
    assert.equal(writes, 3, 'An unconfirmed write was retried');
    assert.equal(statusReads, 4, 'Status refresh cases did not complete');
    process.exitCode = code ?? 1;
  });
});
