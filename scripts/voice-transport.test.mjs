import http from 'node:http';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

let pending;
let started = false;
let cancelled = false;
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname === '/status') return res.end(JSON.stringify({ started, cancelled }));
  if (url.pathname === '/finish') { pending.end(Buffer.from([23, 31, 47])); return res.end('ok'); }
  assert.equal(url.pathname, '/api/speak');
  assert.equal(req.method, 'GET');
  assert.equal(url.searchParams.get('format'), 'pcm');
  const text = url.searchParams.get('text');
  if (text === 'signed-out') { res.writeHead(401); return res.end('{"error":"Sign in first."}'); }
  if (text === 'fallback') { res.writeHead(200, { 'Content-Type': 'audio/wav' }); return res.end('RIFF'); }
  res.writeHead(200, { 'Content-Type': 'audio/pcm', 'X-Haru-Sample-Rate': text === 'bad-rate' ? 'NaN' : '24000' });
  if (text === 'bad-rate') return res.end(Buffer.alloc(4));
  if (text === 'cancel') {
    started = true;
    res.on('close', () => { cancelled = true; });
    res.flushHeaders();
    return;
  }
  assert.equal(text, 'partial & exact?');
  assert.equal(url.searchParams.get('emotion'), 'affectionate');
  pending = res;
  res.write(Buffer.alloc(4097, 17));
});
server.listen(0, '127.0.0.1', () => {
  const child = spawn(process.argv[2], [`http://127.0.0.1:${server.address().port}`], { stdio: 'inherit' });
  const timeout = setTimeout(() => { console.error('Voice transport test timed out.'); child.kill(); }, 30000);
  child.on('exit', code => {
    clearTimeout(timeout);
    server.closeAllConnections();
    server.close();
    process.exitCode = code ?? 1;
  });
});
