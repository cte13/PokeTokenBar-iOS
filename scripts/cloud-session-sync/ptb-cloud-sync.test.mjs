// Run: node --test scripts/cloud-session-sync/ptb-cloud-sync.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { createDecipheriv, diffieHellman, hkdfSync, createPublicKey } from 'node:crypto';
import { inflateRawSync } from 'node:zlib';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  trimLine, trimTranscript, chunkEntries, sealPayload, channelFor, recordNameFor,
  parsePublicKey, relayBody, sessionFiles, pendingRecords, x25519PrivateKey,
} from './ptb-cloud-sync.mjs';

// Shared with PokeTokenBarShared/Tests/PokeTokenBarSharedTests/CloudSessionCryptoTests.swift — change both together.
const DEVICE_PRIVATE = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 1));
const EPHEMERAL_PRIVATE = Buffer.from(Array.from({ length: 32 }, (_, i) => 0x41 + i));
const FIXTURE_NONCE = Buffer.from(Array.from({ length: 12 }, (_, i) => 0xa0 + i));
const devicePrivate = x25519PrivateKey(DEVICE_PRIVATE);
export const DEVICE_PUBLIC = Buffer.from(createPublicKey(devicePrivate).export({ format: 'jwk' }).x, 'base64url');

/// What CloudSessionCrypto.open does, in Node — proves the box opens with only the private key.
function openBox(box) {
  const ephemeralPublic = box.subarray(0, 32);
  const shared = diffieHellman({
    privateKey: devicePrivate,
    publicKey: createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), ephemeralPublic]), format: 'der', type: 'spki' }),
  });
  const key = Buffer.from(hkdfSync('sha256', shared, Buffer.concat([ephemeralPublic, DEVICE_PUBLIC]),
                                   Buffer.from('ptb-cloud-usage/seal/v2'), 32));
  const decipher = createDecipheriv('aes-256-gcm', key, box.subarray(32, 44));
  decipher.setAuthTag(box.subarray(box.length - 16));
  const plain = Buffer.concat([decipher.update(box.subarray(44, box.length - 16)), decipher.final()]);
  return JSON.parse(inflateRawSync(plain).toString('utf8'));
}

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

test('sealPayload opens with the device private key (the Mac wire format)', () => {
  const payload = { v: 2, rel: 'proj/s.jsonl', chunk: 0, jsonl: 'x\n' };
  const box = sealPayload(DEVICE_PUBLIC, payload);
  assert.deepEqual(openBox(box), payload);
  assert.notDeepEqual(sealPayload(DEVICE_PUBLIC, payload).subarray(0, 32), box.subarray(0, 32),
    'a fresh ephemeral key per record');
});

test('fixture values for the Swift test', () => {
  // If this fails, update PokeTokenBarShared/Tests/PokeTokenBarSharedTests/CloudSessionCryptoTests.swift with the printed values.
  const box = sealPayload(DEVICE_PUBLIC, { v: 2, rel: 'proj/s.jsonl', chunk: 2, jsonl: '{"a":1}\n' },
    { ephemeral: x25519PrivateKey(EPHEMERAL_PRIVATE), nonce: FIXTURE_NONCE });
  const expected = {
    publicKey: DEVICE_PUBLIC.toString('base64'),
    channel: channelFor(DEVICE_PUBLIC),
    recordName: recordNameFor(DEVICE_PUBLIC, 'proj/s.jsonl', 2),
    box: box.toString('base64'),
  };
  console.log(JSON.stringify(expected));
  assert.equal(expected.channel.length, 32);
  assert.match(expected.recordName, /^cu_[0-9a-f]{40}$/);
});

test('parsePublicKey rejects keys that are not 32 bytes', () => {
  assert.throws(() => parsePublicKey(Buffer.alloc(16).toString('base64')));
  assert.deepEqual(parsePublicKey(` ${DEVICE_PUBLIC.toString('base64')}\n`), DEVICE_PUBLIC);
});

test('relayBody sends exactly what the relay validates', () => {
  const body = JSON.parse(relayBody([{ recordName: 'cu_x', channel: 'c', updatedAt: 5, payload: Buffer.from('hi'), digest: 'd' }]));
  assert.deepEqual(body, { records: [{ recordName: 'cu_x', channel: 'c', updatedAt: 5, payload: Buffer.from('hi').toString('base64') }] });
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

  const first = pendingRecords(DEVICE_PUBLIC, files, {});
  assert.equal(first.length, 2);
  const uploaded = Object.fromEntries(first.map((r) => [r.recordName, r.digest]));
  assert.equal(pendingRecords(DEVICE_PUBLIC, files, uploaded).length, 0, 'nothing changed');

  fs.appendFileSync(main, assistant('m2', 'r2', 5) + '\n');
  const next = pendingRecords(DEVICE_PUBLIC, files, uploaded);
  assert.equal(next.length, 1, 'only the grown transcript re-uploads');
});
