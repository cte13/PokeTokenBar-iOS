// Run: node --test scripts/cloud-session-sync/ptb-cloud-sync.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { createDecipheriv, generateKeyPairSync, createHash, verify } from 'node:crypto';
import { inflateRawSync } from 'node:zlib';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  trimLine, trimTranscript, chunkEntries, sealPayload, encryptionKey, channelFor, recordNameFor,
  parseSecret, signRequest, modifyBody, sessionFiles, pendingRecords,
} from './ptb-cloud-sync.mjs';

// Shared with Tests/PokeTokenBarTests/CloudSessionSyncTests.swift — change both together.
export const FIXTURE_SECRET = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 1));
const FIXTURE_NONCE = Buffer.from(Array.from({ length: 12 }, (_, i) => 0xa0 + i));

const assistant = (id, req, out, extra = {}) => JSON.stringify({
  parentUuid: 'p', type: 'assistant', timestamp: '2026-09-27T10:00:00.000Z', requestId: req, cwd: '/secret/path',
  message: {
    id, model: 'claude-opus-5-5', role: 'assistant', content: [{ type: 'text', text: 'PRIVATE PROMPT TEXT' }],
    usage: { input_tokens: 10, output_tokens: out, cache_creation_input_tokens: 2, cache_read_input_tokens: 3 },
  },
  ...extra,
});

test('trimLine keeps only the fields the Mac parser reads', () => {
  const e = trimLine(assistant('m1', 'r1', 5));
  assert.deepEqual(Object.keys(e).sort(), ['message', 'requestId', 'timestamp', 'type']);
  assert.deepEqual(Object.keys(e.message).sort(), ['id', 'model', 'usage']);
  assert.ok(!JSON.stringify(e).includes('PRIVATE'), 'content must not survive trimming');
  assert.ok(!JSON.stringify(e).includes('/secret/path'));
  // The Mac reader pre-filters on these substrings before parsing.
  const line = JSON.stringify(e);
  assert.ok(line.includes('"usage"') && line.includes('"assistant"'));
});

test('trimLine skips non-assistant and malformed lines', () => {
  assert.equal(trimLine('{"type":"user","message":{"usage":{}},"x":"assistant"}'), null);
  assert.equal(trimLine('not json "usage" "assistant"'), null);
  assert.equal(trimLine(JSON.stringify({ type: 'assistant', message: { usage: {} } })), null, 'no timestamp');
});

test('trimTranscript keeps one entry per turn, at its first position, with the largest total', () => {
  const text = [assistant('m1', 'r1', 1), assistant('m2', 'r2', 7), assistant('m1', 'r1', 50), ''].join('\n');
  const out = trimTranscript(text);
  assert.equal(out.length, 2);
  assert.equal(out[0].message.id, 'm1');
  assert.equal(out[0].message.usage.output_tokens, 50);
  assert.equal(out[1].message.id, 'm2');
});

test('chunks are stable as the transcript grows', () => {
  const entries = Array.from({ length: 7 }, (_, i) => i);
  assert.deepEqual(chunkEntries(entries, 3), [[0, 1, 2], [3, 4, 5], [6]]);
  assert.deepEqual(chunkEntries([...entries, 7], 3).slice(0, 2), [[0, 1, 2], [3, 4, 5]]);
});

test('sealPayload opens with AES-256-GCM + raw inflate (the Mac wire format)', () => {
  const payload = { v: 1, rel: 'proj/s.jsonl', chunk: 0, jsonl: 'x\n' };
  const box = sealPayload(FIXTURE_SECRET, payload, FIXTURE_NONCE);
  const decipher = createDecipheriv('aes-256-gcm', encryptionKey(FIXTURE_SECRET), box.subarray(0, 12));
  decipher.setAuthTag(box.subarray(box.length - 16));
  const plain = Buffer.concat([decipher.update(box.subarray(12, box.length - 16)), decipher.final()]);
  assert.deepEqual(JSON.parse(inflateRawSync(plain).toString('utf8')), payload);
});

test('fixture values for the Swift test', () => {
  // If this fails, update PokeTokenBarShared/Tests/PokeTokenBarSharedTests/CloudSessionCryptoTests.swift with the printed values.
  const box = sealPayload(FIXTURE_SECRET, { v: 1, rel: 'proj/s.jsonl', chunk: 2, jsonl: '{"a":1}\n' }, FIXTURE_NONCE);
  const expected = {
    channel: channelFor(FIXTURE_SECRET),
    recordName: recordNameFor(FIXTURE_SECRET, 'proj/s.jsonl', 2),
    box: box.toString('base64'),
  };
  console.log(JSON.stringify(expected));
  assert.equal(expected.channel.length, 32);
  assert.match(expected.recordName, /^cu_[0-9a-f]{40}$/);
});

test('parseSecret rejects keys that are not 32 bytes', () => {
  assert.throws(() => parseSecret(Buffer.alloc(16).toString('base64')));
  assert.equal(parseSecret(FIXTURE_SECRET.toString('base64')).length, 32);
});

test('signRequest signs date:bodyhash:subpath with ECDSA P-256', () => {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const body = '{"x":1}';
  const subpath = '/database/1/iCloud.x/development/public/records/modify';
  const h = signRequest({ keyID: 'kid', privateKey, subpath, body, date: '2026-09-27T10:00:00Z' });
  assert.equal(h['X-Apple-CloudKit-Request-ISO8601Date'], '2026-09-27T10:00:00Z');
  const message = `2026-09-27T10:00:00Z:${createHash('sha256').update(body).digest('base64')}:${subpath}`;
  assert.ok(verify('sha256', Buffer.from(message), publicKey,
    Buffer.from(h['X-Apple-CloudKit-Request-SignatureV1'], 'base64')));
});

test('modifyBody writes channel / updatedAt / payload with CloudKit types', () => {
  const body = JSON.parse(modifyBody([{ recordName: 'cu_x', channel: 'c', updatedAt: 5, payload: Buffer.from('hi') }]));
  const op = body.operations[0];
  assert.equal(op.operationType, 'forceReplace');
  assert.equal(op.record.recordType, 'CloudUsage');
  assert.deepEqual(op.record.fields.payload, { value: Buffer.from('hi').toString('base64'), type: 'BYTES' });
  assert.equal(op.record.fields.updatedAt.type, 'TIMESTAMP');
});

test('sessionFiles + pendingRecords: subagents included, unchanged chunks skipped', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ptb-sync-'));
  const proj = path.join(root, '-home-user-repo');
  fs.mkdirSync(path.join(proj, 'sess', 'subagents'), { recursive: true });
  const main = path.join(proj, 'sess.jsonl');
  fs.writeFileSync(main, assistant('m1', 'r1', 5) + '\n');
  fs.writeFileSync(path.join(proj, 'sess', 'subagents', 'agent-1.jsonl'), assistant('m9', 'r9', 5) + '\n');

  const files = sessionFiles(main);
  assert.deepEqual(files.map((f) => f.rel).sort(),
    ['-home-user-repo/sess.jsonl', '-home-user-repo/sess/subagents/agent-1.jsonl']);

  const first = pendingRecords(FIXTURE_SECRET, files, {});
  assert.equal(first.length, 2);
  const uploaded = Object.fromEntries(first.map((r) => [r.recordName, r.digest]));
  assert.equal(pendingRecords(FIXTURE_SECRET, files, uploaded).length, 0, 'nothing changed');

  fs.appendFileSync(main, assistant('m2', 'r2', 5) + '\n');
  const next = pendingRecords(FIXTURE_SECRET, files, uploaded);
  assert.equal(next.length, 1, 'only the grown transcript re-uploads');
});
