import { test } from 'node:test';
import assert from 'node:assert/strict';
import { verifyTestFlight } from './verify-testflight.mjs';

function build(state, internal = 'PROCESSING') {
  return { data: [{ id: 'build-74', type: 'builds', attributes: { processingState: state },
    relationships: { buildBetaDetail: { data: { id: 'detail-74' } } } }],
    included: [{ type: 'buildBetaDetails', id: 'unrelated', attributes: { internalBuildState: 'IN_BETA_TESTING' } },
      { type: 'buildBetaDetails', id: 'detail-74', attributes: { internalBuildState: internal } }] };
}

function fixture(responses) {
  const paths = [];
  let waits = 0;
  const options = {
    buildNumber: '74', bundleId: 'com.toomiiverse.haru.JF3928RYMD', attempts: responses.length,
    log: () => {}, wait: async () => { waits++; },
    api: async (path) => {
      paths.push(path);
      if (path.startsWith('/apps?')) return { data: [{ id: 'haru-app' }] };
      assert.ok(responses.length, 'unexpected status request');
      return responses.shift();
    },
  };
  return { options, paths, waits: () => waits };
}

test('waits through discovery, processing and tester assignment for the exact build', async () => {
  const f = fixture([{ data: [] }, build('PROCESSING'), build('VALID', 'READY_FOR_BETA_TESTING'),
    build('VALID', 'IN_BETA_TESTING')]);
  const result = await verifyTestFlight(f.options);
  assert.equal(result.buildId, 'build-74');
  assert.equal(f.waits(), 3);
  for (const path of f.paths.slice(1)) {
    const url = new URL(path, 'https://example.test');
    assert.equal(url.searchParams.get('filter[app]'), 'haru-app');
    assert.equal(url.searchParams.get('filter[version]'), '74');
  }
});

for (const state of ['INVALID', 'FAILED']) {
  test(`fails promptly when Apple reports ${state}`, async () => {
    const f = fixture([build(state)]);
    await assert.rejects(verifyTestFlight(f.options), /Apple rejected build 74/);
    assert.equal(f.waits(), 0);
  });
}

test('reports an export compliance block', async () => {
  const f = fixture([build('VALID', 'MISSING_EXPORT_COMPLIANCE')]);
  await assert.rejects(verifyTestFlight(f.options), /needs export compliance/);
});

test('does not claim success when a processed build is not assigned to testers', async () => {
  const f = fixture([build('VALID', 'READY_FOR_BETA_TESTING'), build('VALID', 'READY_FOR_BETA_TESTING')]);
  await assert.rejects(verifyTestFlight(f.options), /availability was not confirmed/);
  assert.equal(f.waits(), 1);
});

test('fails before polling when the bundle ID has no app', async () => {
  await assert.rejects(verifyTestFlight({ api: async () => ({ data: [] }), buildNumber: '74',
    bundleId: 'missing' }), /Could not identify/);
});
