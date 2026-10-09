import http from 'node:http';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

let writes = 0;
const snapshot = {
  version: 1, enabled: true, revision: 7,
  preferences: { reactToConversation: true, allowDecline: true },
  current: { emotion: 'curious', disposition: 'engage', episodes: [{ emotion: 'interest', intensity: 0.4 }] },
  controls: [{ key: 'reactToConversation', label: 'React to conversation', description: 'A server-authored description.' }],
};
const server = http.createServer(async (req, res) => {
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
    process.exitCode = code ?? 1;
  });
});
