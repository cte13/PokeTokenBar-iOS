// Run: node --test scripts/cloud-session-sync/relay/worker.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, verify } from 'node:crypto';
import { handle, validate, rawToDer, MAX_RECORDS } from './worker.mjs';

const { privateKey, publicKey } = generateKeyPairSync('ec', {
  namedCurve: 'prime256v1',
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});
const env = {
  RELAY_TOKEN: 'tok-123', CLOUDKIT_KEY_ID: 'kid', CLOUDKIT_PRIVATE_KEY: privateKey,
  CLOUDKIT_CONTAINER: 'iCloud.test', CLOUDKIT_ENV: 'development',
};
const record = { recordName: 'cu_' + 'a'.repeat(40), channel: 'b'.repeat(32), updatedAt: 1_800_000_000_000, payload: 'aGk=' };

function request({ token = 'tok-123', body = { records: [record] }, method = 'POST', path = '/upload' } = {}) {
  return new Request(`https://relay.example${path}`, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: method === 'POST' ? JSON.stringify(body) : undefined,
  });
}

function recordingFetch() {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init });
    return new Response('{"records":[]}', { status: 200 });
  };
  return { calls, fn };
}

test('signs the CloudKit request so Apple can verify it (DER ECDSA over date:bodyhash:subpath)', async () => {
  const cloud = recordingFetch();
  const now = new Date('2026-09-29T10:00:00.123Z');
  const res = await handle(request(), env, cloud.fn, now);
  assert.equal(res.status, 200);
  const { url, init } = cloud.calls[0];
  const subpath = '/database/1/iCloud.test/development/public/records/modify';
  assert.equal(url, `https://api.apple-cloudkit.com${subpath}`);
  assert.equal(init.headers['X-Apple-CloudKit-Request-KeyID'], 'kid');
  assert.equal(init.headers['X-Apple-CloudKit-Request-ISO8601Date'], '2026-09-29T10:00:00Z');
  const message = `2026-09-29T10:00:00Z:${createHash('sha256').update(init.body).digest('base64')}:${subpath}`;
  assert.ok(verify('sha256', Buffer.from(message), publicKey,
    Buffer.from(init.headers['X-Apple-CloudKit-Request-SignatureV1'], 'base64')));

  const op = JSON.parse(init.body).operations[0];
  assert.equal(op.operationType, 'forceReplace');
  assert.equal(op.record.recordType, 'CloudUsage');
  assert.deepEqual(op.record.fields, {
    channel: { value: record.channel, type: 'STRING' },
    updatedAt: { value: record.updatedAt, type: 'TIMESTAMP' },
    payload: { value: record.payload, type: 'BYTES' },
  });
});

test('rejects a missing or wrong token without calling CloudKit', async () => {
  for (const token of [null, 'nope', 'tok-1234', '']) {
    const cloud = recordingFetch();
    const res = await handle(request({ token }), env, cloud.fn);
    assert.equal(res.status, 401, `token ${token}`);
    assert.equal(cloud.calls.length, 0);
  }
  const cloud = recordingFetch();
  assert.equal((await handle(request(), { ...env, RELAY_TOKEN: '' }, cloud.fn)).status, 401, 'unset token never matches');
});

test('only POST /upload exists', async () => {
  const cloud = recordingFetch();
  assert.equal((await handle(request({ method: 'GET' }), env, cloud.fn)).status, 404);
  assert.equal((await handle(request({ path: '/other' }), env, cloud.fn)).status, 404);
  assert.equal(cloud.calls.length, 0);
});

test('accepts only the records the hook writes', async () => {
  const bad = [
    { records: [] },
    { records: Array(MAX_RECORDS + 1).fill(record) },
    { records: [{ ...record, recordName: 'Payload' }] },
    { records: [{ ...record, recordName: 'cu_' + 'A'.repeat(40) }] },
    { records: [{ ...record, channel: 'x' }] },
    { records: [{ ...record, updatedAt: -1 }] },
    { records: [{ ...record, payload: '' }] },
    { records: [{ ...record, payload: 'not base64!' }] },
    {},
  ];
  for (const body of bad) {
    const cloud = recordingFetch();
    const res = await handle(request({ body }), env, cloud.fn);
    assert.equal(res.status, 400, JSON.stringify(body).slice(0, 80));
    assert.equal(cloud.calls.length, 0);
  }
  assert.deepEqual(validate({ records: [{ ...record, extra: 'dropped' }] }), [record]);
});

test('rawToDer pads high-bit integers and strips leading zeros', () => {
  const raw = new Uint8Array(64);
  raw[0] = 0x80; raw[63] = 0x01;
  assert.deepEqual([...rawToDer(raw).slice(0, 5)], [0x30, 0x26, 0x02, 0x21, 0x00]);
  assert.deepEqual([...rawToDer(raw).slice(-3)], [0x02, 0x01, 0x01]);
});
