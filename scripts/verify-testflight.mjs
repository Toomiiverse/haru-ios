// Check the exact uploaded build, not merely Xcode's successful transfer.
// Read-only: existing TestFlight groups keep their distribution settings.
import { createPrivateKey, sign } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

export async function verifyTestFlight({ api, buildNumber, bundleId, attempts = 30,
    wait = () => delay(20_000), log = console.log }) {
  const query = (values) => new URLSearchParams(values).toString();
  const apps = await api(`/apps?${query({ 'filter[bundleId]': bundleId, limit: '2' })}`);
  if (apps.data?.length !== 1) throw new Error('Could not identify the Haru app in App Store Connect.');
  const appId = apps.data[0].id;
  for (let attempt = 0; attempt < attempts; attempt++) {
    const result = await api(`/builds?${query({ 'filter[app]': appId,
      'filter[version]': String(buildNumber), include: 'buildBetaDetail,betaGroups',
      sort: '-uploadedDate', limit: '1' })}`);
    const build = result.data?.[0];
    const state = build?.attributes?.processingState ?? 'AWAITING_PROCESSING';
    const detailId = build?.relationships?.buildBetaDetail?.data?.id;
    const detail = result.included?.find((item) => item.type === 'buildBetaDetails' && item.id === detailId);
    const internal = detail?.attributes?.internalBuildState ?? 'PENDING';
    log(`TestFlight build ${buildNumber}: ${state}; internal testing: ${internal}`);
    if (state === 'FAILED' || state === 'INVALID') {
      throw new Error(`Apple rejected build ${buildNumber} during processing (${state}).`);
    }
    if (internal === 'MISSING_EXPORT_COMPLIANCE') {
      throw new Error(`Build ${buildNumber} needs export compliance information in App Store Connect.`);
    }
    if (state === 'VALID' && internal === 'IN_BETA_TESTING') {
      log(`Build ${buildNumber} is available for internal testing in TestFlight.`);
      return { appId, buildId: build.id, state, internal };
    }
    if (attempt + 1 < attempts) await wait();
  }
  throw new Error(`Build ${buildNumber} was uploaded, but TestFlight availability was not confirmed within the processing window. Check App Store Connect before uploading again.`);
}

async function main() {
  const { ASC_KEY_ID: kid, ASC_ISSUER_ID: iss, ASC_KEY_P8: rawKey } = process.env;
  const buildNumber = process.argv[2];
  if (!kid || !iss || !rawKey || !/^\d+$/.test(buildNumber ?? '')) {
    throw new Error('App Store Connect credentials and the uploaded build number are required.');
  }
  const pem = rawKey.includes('BEGIN PRIVATE KEY') ? rawKey : Buffer.from(rawKey, 'base64').toString('utf8');
  const key = createPrivateKey(pem);
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const api = async (path) => {
    const now = Math.floor(Date.now() / 1000);
    const payload = `${encode({ alg: 'ES256', kid, typ: 'JWT' })}.${encode({ iss, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' })}`;
    const jwt = `${payload}.${sign('sha256', Buffer.from(payload), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
    const response = await fetch(`https://api.appstoreconnect.apple.com/v1${path}`, {
      headers: { authorization: `Bearer ${jwt}` }, signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) throw new Error(`App Store Connect status check failed (HTTP ${response.status}). The upload may already have succeeded.`);
    return response.json();
  };
  await verifyTestFlight({ api, buildNumber, bundleId: 'com.toomiiverse.haru.JF3928RYMD' });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => { console.error(error.message); process.exitCode = 1; });
}
