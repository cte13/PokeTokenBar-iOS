#!/usr/bin/env node
// PokeTokenBar cloud-session sync — Claude Code hook (Stop / SubagentStop / SessionEnd).
//
// Claude Code on the web runs in a disposable Linux container, so its transcripts never reach
// the Mac that PokeTokenBar reads. This hook runs inside that container after every turn,
// trims the session transcript down to token-usage lines only (no prompts, no code, no tool
// output), encrypts it to the user's device public key, and posts it to a small relay
// (`relay/worker.mjs`) that writes it to the app's CloudKit container. The Mac and iPhone pull
// those records and count them like local transcripts.
//
// No secret lives in the container. Environment variables are readable by every session, so:
//   - encryption uses the device's *public* key; only the Mac/iPhone hold the private key;
//   - the relay's Bearer token is an environment **API credential**: Anthropic's agent proxy
//     attaches it to requests for the relay's host, and the session never sees it;
//   - the CloudKit signing key lives only in the relay.
//
// Zero dependencies: Node's built-in crypto/zlib, and `curl` for the request (curl honours the
// container's HTTPS proxy and CA settings; Node's fetch does not by default).
//
// Environment (both values are public — safe as ordinary environment variables):
//   PTB_SYNC_PUBLIC_KEY   base64 of the 32-byte X25519 public key shown in the Mac app's Settings
//   PTB_RELAY_URL         the relay's URL, e.g. https://ptb-cloud-relay.<you>.workers.dev
//
// The hook never fails the turn: every error is logged to ~/.cache/poketokenbar-cloud-sync/log
// and the process exits 0.

import { createHash, createCipheriv, createPrivateKey, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes } from 'node:crypto';
import { deflateRawSync } from 'node:zlib';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const RECORD_TYPE = 'CloudUsage';
/// Usage entries per record. A trimmed entry deflates to well under 150 bytes, so a full chunk
/// stays far below CloudKit's 1 MB record limit. The Mac app stores each chunk as its own file.
export const CHUNK_SIZE = 5000;
/// The relay accepts at most this many records per request.
export const MAX_RECORDS_PER_REQUEST = 200;

// ── Key material ────────────────────────────────────────────────────────────────────────────
// The device key pair is X25519. Record names and the channel are hashes of fixed labels and the
// public key, so the Mac/iPhone (CloudSessionCrypto.swift) derive the same values from their
// private key, and the container needs nothing secret.

export function parsePublicKey(raw) {
  const key = Buffer.from((raw ?? '').trim(), 'base64');
  if (key.length !== 32) throw new Error('PTB_SYNC_PUBLIC_KEY must be base64 of a 32-byte X25519 public key');
  return key;
}

const sha256 = (...parts) => createHash('sha256').update(Buffer.concat(parts)).digest();
const utf8 = (s) => Buffer.from(s, 'utf8');

/// Records are found by this opaque channel, never by anything that identifies the user.
export const channelFor = (publicKey) =>
  sha256(utf8('ptb-cloud-usage/channel/v2'), publicKey).toString('hex').slice(0, 32);
export const recordNameFor = (publicKey, rel, chunk) =>
  'cu_' + sha256(utf8(`ptb-cloud-usage/record/v2|${rel}|${chunk}`), publicKey).toString('hex').slice(0, 40);

const X25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b656e04220420', 'hex');
const X25519_SPKI_PREFIX = Buffer.from('302a300506032b656e032100', 'hex');
export const x25519PrivateKey = (raw) =>
  createPrivateKey({ key: Buffer.concat([X25519_PKCS8_PREFIX, raw]), format: 'der', type: 'pkcs8' });
const x25519PublicKey = (raw) =>
  createPublicKey({ key: Buffer.concat([X25519_SPKI_PREFIX, raw]), format: 'der', type: 'spki' });
const rawPublic = (keyObject) => Buffer.from(createPublicKey(keyObject).export({ format: 'jwk' }).x, 'base64url');

// ── Transcript trimming ─────────────────────────────────────────────────────────────────────

/// Keeps exactly what `LocalUsageReader.parseClaudeLine` reads; drops everything else.
export function trimLine(line) {
  if (!line.includes('"usage"') || !line.includes('"assistant"')) return null;
  let obj;
  try { obj = JSON.parse(line); } catch { return null; }
  const msg = obj?.message;
  if (obj?.type !== 'assistant' || !msg?.usage || typeof obj.timestamp !== 'string') return null;
  return {
    type: 'assistant',
    timestamp: obj.timestamp,
    requestId: obj.requestId ?? '',
    message: { id: msg.id ?? '', model: msg.model ?? 'unknown', usage: msg.usage },
  };
}

const usageTotal = (u) =>
  ['input_tokens', 'output_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens']
    .reduce((sum, k) => sum + (Number(u?.[k]) || 0), 0);

/// Streaming writes the same `(message.id, requestId)` several times with a growing output
/// count. Keep one entry per turn at its first position (so chunk boundaries stay stable as the
/// transcript grows) holding the largest total — the same rule as `dedupKeepMax` on the Mac.
export function trimTranscript(text) {
  const out = [];
  const index = new Map();
  for (const line of text.split('\n')) {
    const e = trimLine(line);
    if (!e) continue;
    const key = `${e.message.id}|${e.requestId}`;
    const at = index.get(key);
    if (at === undefined) {
      index.set(key, out.length);
      out.push(e);
    } else if (usageTotal(e.message.usage) > usageTotal(out[at].message.usage)) {
      out[at] = { ...e, timestamp: out[at].timestamp };
    }
  }
  return out;
}

export function chunkEntries(entries, size = CHUNK_SIZE) {
  const chunks = [];
  for (let i = 0; i < entries.length; i += size) chunks.push(entries.slice(i, i + size));
  return chunks;
}

// ── Payload ─────────────────────────────────────────────────────────────────────────────────
// Wire format (read by CloudSessionCrypto.open): sealed to the device public key P with a fresh
// ephemeral X25519 key E per record:
//   key  = HKDF-SHA256(ikm = X25519(E, P), salt = E.pub || P, info = "ptb-cloud-usage/seal/v2", 32)
//   box  = E.pub(32) || nonce(12) || AES-256-GCM ciphertext || tag(16)
// over raw-deflate(JSON {v:2, rel, chunk, jsonl}).

export function sealPayload(publicKey, payload, { ephemeral = generateKeyPairSync('x25519').privateKey,
                                                 nonce = randomBytes(12) } = {}) {
  const ephemeralPublic = rawPublic(ephemeral);
  const shared = diffieHellman({ privateKey: ephemeral, publicKey: x25519PublicKey(publicKey) });
  const key = Buffer.from(hkdfSync('sha256', shared, Buffer.concat([ephemeralPublic, publicKey]),
                                   utf8('ptb-cloud-usage/seal/v2'), 32));
  const plain = deflateRawSync(utf8(JSON.stringify(payload)));
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  const body = Buffer.concat([cipher.update(plain), cipher.final()]);
  return Buffer.concat([ephemeralPublic, nonce, body, cipher.getAuthTag()]);
}

// ── Relay ───────────────────────────────────────────────────────────────────────────────────

export function relayBody(records) {
  return JSON.stringify({
    records: records.map((r) => ({
      recordName: r.recordName, channel: r.channel, updatedAt: r.updatedAt, payload: r.payload.toString('base64'),
    })),
  });
}

/// Posts to the relay. No Authorization header here — the agent proxy adds the API credential
/// for the relay's host after the request leaves the container. Returns the record names the
/// relay (CloudKit) rejected.
function postToRelay(relayURL, records) {
  const url = new URL('/upload', relayURL).toString();
  const args = ['-sS', '--max-time', '20', '-X', 'POST', '-H', 'Content-Type: application/json',
    '--data-binary', '@-', '-w', '\n%{http_code}', url];
  const out = execFileSync('curl', args, { input: relayBody(records), encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  const cut = out.lastIndexOf('\n');
  const status = Number(out.slice(cut + 1));
  const text = out.slice(0, cut);
  if (status !== 200) throw new Error(`relay HTTP ${status}: ${text.slice(0, 500)}`);
  const failed = new Set();
  for (const r of JSON.parse(text).records ?? []) {
    if (r.serverErrorCode) {
      failed.add(r.recordName);
      log(`record ${r.recordName}: ${r.serverErrorCode} ${r.reason ?? ''}`);
    }
  }
  return failed;
}

// ── Hook entry ──────────────────────────────────────────────────────────────────────────────

const stateDir = () => path.join(os.homedir(), '.cache', 'poketokenbar-cloud-sync');
function log(message) {
  try {
    fs.mkdirSync(stateDir(), { recursive: true });
    fs.appendFileSync(path.join(stateDir(), 'log'), `${new Date().toISOString()} ${message}\n`);
  } catch { /* logging must never fail the hook */ }
}

/// The session's own transcript plus its subagent transcripts, each with its path relative to
/// the projects root (`<project>/<session>.jsonl`, `<project>/<session>/subagents/<agent>.jsonl`)
/// — the shapes `LocalUsageReader.claudeSessionID(forTranscript:)` understands.
export function sessionFiles(transcriptPath) {
  const projectsRoot = path.dirname(path.dirname(transcriptPath));
  const files = [transcriptPath];
  const subDir = path.join(transcriptPath.replace(/\.jsonl$/, ''), 'subagents');
  try {
    for (const name of fs.readdirSync(subDir)) {
      if (name.endsWith('.jsonl')) files.push(path.join(subDir, name));
    }
  } catch { /* no subagents */ }
  return files
    .filter((f) => fs.existsSync(f))
    .map((f) => ({ file: f, rel: path.relative(projectsRoot, f).split(path.sep).join('/') }));
}

/// Builds the records whose content changed since the last successful upload.
export function pendingRecords(publicKey, files, uploaded, now = Date.now()) {
  const channel = channelFor(publicKey);
  const records = [];
  for (const { file, rel } of files) {
    const chunks = chunkEntries(trimTranscript(fs.readFileSync(file, 'utf8')));
    chunks.forEach((entries, chunk) => {
      const jsonl = entries.map((e) => JSON.stringify(e)).join('\n') + '\n';
      const recordName = recordNameFor(publicKey, rel, chunk);
      const digest = createHash('sha256').update(jsonl).digest('hex');
      if (uploaded[recordName] === digest) return;
      records.push({
        recordName, channel, updatedAt: now, digest,
        payload: sealPayload(publicKey, { v: 2, rel, chunk, jsonl }),
      });
    });
  }
  return records;
}

async function readStdin() {
  let data = '';
  for await (const part of process.stdin) data += part;
  return data;
}

async function main() {
  const env = process.env;
  if (!env.PTB_SYNC_PUBLIC_KEY || !env.PTB_RELAY_URL) return;
  const input = JSON.parse((await readStdin()) || '{}');
  const transcriptPath = input.transcript_path;
  if (!transcriptPath || !fs.existsSync(transcriptPath)) return;

  const publicKey = parsePublicKey(env.PTB_SYNC_PUBLIC_KEY);
  const statePath = path.join(stateDir(), 'uploaded.json');
  let uploaded = {};
  try { uploaded = JSON.parse(fs.readFileSync(statePath, 'utf8')); } catch { /* first run */ }

  const records = pendingRecords(publicKey, sessionFiles(transcriptPath), uploaded);
  if (records.length === 0) return;

  for (let i = 0; i < records.length; i += MAX_RECORDS_PER_REQUEST) {
    const batch = records.slice(i, i + MAX_RECORDS_PER_REQUEST);
    const failed = postToRelay(env.PTB_RELAY_URL, batch);
    for (const r of batch) if (!failed.has(r.recordName)) uploaded[r.recordName] = r.digest;
  }
  fs.mkdirSync(stateDir(), { recursive: true });
  fs.writeFileSync(statePath, JSON.stringify(uploaded));
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((err) => log(`sync failed: ${err?.stack ?? err}`)).finally(() => process.exit(0));
}
