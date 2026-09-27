#!/usr/bin/env node
// PokeTokenBar cloud-session sync — Claude Code hook (Stop / SubagentStop / SessionEnd).
//
// Claude Code on the web runs in a disposable Linux container, so its transcripts never reach
// the Mac that PokeTokenBar reads. This hook runs inside that container after every turn,
// trims the session transcript down to token-usage lines only (no prompts, no code, no tool
// output), encrypts it with a secret shared with the Mac app, and writes it to the app's
// CloudKit container through CloudKit Web Services. The Mac app pulls those records on each
// refresh and scans them like a local `~/.claude/projects` tree.
//
// Zero dependencies: Node's built-in crypto/zlib, and `curl` for the request (curl honours the
// container's HTTPS proxy and CA settings; Node 22's fetch does not by default).
//
// Environment (set as environment variables in the cloud environment's settings):
//   PTB_SYNC_SECRET            base64 of 32 random bytes — the same key saved in the Mac app
//   PTB_CLOUDKIT_KEY_ID        server-to-server key ID from the CloudKit Console
//   PTB_CLOUDKIT_PRIVATE_KEY   the matching EC P-256 private key: PEM, or base64 of the PEM
//   PTB_CLOUDKIT_ENV           "development" (default) or "production" — must match the Mac build
//   PTB_CLOUDKIT_CONTAINER     defaults to iCloud.io.github.chattymin.poketokenbar
//
// The hook never fails the turn: every error is logged to ~/.cache/poketokenbar-cloud-sync/log
// and the process exits 0.

import { createHash, createHmac, createCipheriv, createPrivateKey, randomBytes, sign } from 'node:crypto';
import { deflateRawSync } from 'node:zlib';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const RECORD_TYPE = 'CloudUsage';
export const DEFAULT_CONTAINER = 'iCloud.io.github.chattymin.poketokenbar';
/// Usage entries per record. A trimmed entry deflates to well under 150 bytes, so a full chunk
/// stays far below CloudKit's 1 MB record limit. The Mac app stores each chunk as its own file.
export const CHUNK_SIZE = 5000;
const MAX_OPS_PER_REQUEST = 200;

// ── Key material ────────────────────────────────────────────────────────────────────────────
// Every derived value is an HMAC of the shared secret with a fixed label, so the Mac app can
// derive the same values (CloudSessionCrypto.swift) and nothing else needs to be shared.

export function parseSecret(raw) {
  const key = Buffer.from((raw ?? '').trim(), 'base64');
  if (key.length !== 32) throw new Error('PTB_SYNC_SECRET must be base64 of exactly 32 bytes');
  return key;
}

const hmac = (secret, label) => createHmac('sha256', secret).update(label, 'utf8').digest();

export const encryptionKey = (secret) => hmac(secret, 'ptb-cloud-usage/enc/v1');
/// Public-database records are visible to anyone holding the container's API token, so records
/// are found by this opaque channel, never by anything that identifies the user.
export const channelFor = (secret) => hmac(secret, 'ptb-cloud-usage/channel/v1').toString('hex').slice(0, 32);
export const recordNameFor = (secret, rel, chunk) =>
  'cu_' + hmac(secret, `ptb-cloud-usage/record/v1|${rel}|${chunk}`).toString('hex').slice(0, 40);

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
// Wire format (read by CloudSessionCrypto.open): AES-256-GCM combined box
//   nonce(12) || ciphertext || tag(16)
// over raw-deflate(JSON {v:1, rel, chunk, jsonl}).

export function sealPayload(secret, payload, nonce = randomBytes(12)) {
  const plain = deflateRawSync(Buffer.from(JSON.stringify(payload), 'utf8'));
  const cipher = createCipheriv('aes-256-gcm', encryptionKey(secret), nonce);
  const body = Buffer.concat([cipher.update(plain), cipher.final()]);
  return Buffer.concat([nonce, body, cipher.getAuthTag()]);
}

// ── CloudKit Web Services (server-to-server key) ────────────────────────────────────────────

export function loadPrivateKey(raw) {
  let pem = (raw ?? '').trim().replace(/\\n/g, '\n');
  if (!pem.includes('BEGIN')) pem = Buffer.from(pem, 'base64').toString('utf8');
  return createPrivateKey(pem);
}

export const cloudKitDate = (d = new Date()) => d.toISOString().replace(/\.\d{3}Z$/, 'Z');

/// Signature V1: ECDSA-SHA256 over "<date>:<base64(sha256(body))>:<subpath>".
export function signRequest({ keyID, privateKey, subpath, body, date = cloudKitDate() }) {
  const bodyHash = createHash('sha256').update(body, 'utf8').digest('base64');
  const signature = sign('sha256', Buffer.from(`${date}:${bodyHash}:${subpath}`, 'utf8'), privateKey)
    .toString('base64');
  return {
    'X-Apple-CloudKit-Request-KeyID': keyID,
    'X-Apple-CloudKit-Request-ISO8601Date': date,
    'X-Apple-CloudKit-Request-SignatureV1': signature,
  };
}

export function modifyBody(records) {
  return JSON.stringify({
    atomic: false,
    operations: records.map((r) => ({
      operationType: 'forceReplace',
      record: {
        recordType: RECORD_TYPE,
        recordName: r.recordName,
        fields: {
          channel: { value: r.channel, type: 'STRING' },
          updatedAt: { value: r.updatedAt, type: 'TIMESTAMP' },
          payload: { value: r.payload.toString('base64'), type: 'BYTES' },
        },
      },
    })),
  });
}

function postModify({ container, environment, keyID, privateKey, records }) {
  const subpath = `/database/1/${container}/${environment}/public/records/modify`;
  const body = modifyBody(records);
  const headers = signRequest({ keyID, privateKey, subpath, body });
  const args = ['-sS', '--max-time', '20', '-X', 'POST', '-H', 'Content-Type: application/json'];
  for (const [k, v] of Object.entries(headers)) args.push('-H', `${k}: ${v}`);
  args.push('--data-binary', '@-', '-w', '\n%{http_code}', `https://api.apple-cloudkit.com${subpath}`);
  const out = execFileSync('curl', args, { input: body, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });
  const cut = out.lastIndexOf('\n');
  const status = Number(out.slice(cut + 1));
  const text = out.slice(0, cut);
  if (status !== 200) throw new Error(`CloudKit HTTP ${status}: ${text.slice(0, 500)}`);
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
export function pendingRecords(secret, files, uploaded, now = Date.now()) {
  const channel = channelFor(secret);
  const records = [];
  for (const { file, rel } of files) {
    const chunks = chunkEntries(trimTranscript(fs.readFileSync(file, 'utf8')));
    chunks.forEach((entries, chunk) => {
      const jsonl = entries.map((e) => JSON.stringify(e)).join('\n') + '\n';
      const recordName = recordNameFor(secret, rel, chunk);
      const digest = createHash('sha256').update(jsonl).digest('hex');
      if (uploaded[recordName] === digest) return;
      records.push({
        recordName, channel, updatedAt: now, digest,
        payload: sealPayload(secret, { v: 1, rel, chunk, jsonl }),
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
  if (!env.PTB_SYNC_SECRET || !env.PTB_CLOUDKIT_KEY_ID || !env.PTB_CLOUDKIT_PRIVATE_KEY) return;
  const input = JSON.parse((await readStdin()) || '{}');
  const transcriptPath = input.transcript_path;
  if (!transcriptPath || !fs.existsSync(transcriptPath)) return;

  const secret = parseSecret(env.PTB_SYNC_SECRET);
  const statePath = path.join(stateDir(), 'uploaded.json');
  let uploaded = {};
  try { uploaded = JSON.parse(fs.readFileSync(statePath, 'utf8')); } catch { /* first run */ }

  const records = pendingRecords(secret, sessionFiles(transcriptPath), uploaded);
  if (records.length === 0) return;

  const privateKey = loadPrivateKey(env.PTB_CLOUDKIT_PRIVATE_KEY);
  for (let i = 0; i < records.length; i += MAX_OPS_PER_REQUEST) {
    const batch = records.slice(i, i + MAX_OPS_PER_REQUEST);
    const failed = postModify({
      container: env.PTB_CLOUDKIT_CONTAINER || DEFAULT_CONTAINER,
      environment: env.PTB_CLOUDKIT_ENV || 'development',
      keyID: env.PTB_CLOUDKIT_KEY_ID,
      privateKey,
      records: batch,
    });
    for (const r of batch) if (!failed.has(r.recordName)) uploaded[r.recordName] = r.digest;
  }
  fs.mkdirSync(stateDir(), { recursive: true });
  fs.writeFileSync(statePath, JSON.stringify(uploaded));
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((err) => log(`sync failed: ${err?.stack ?? err}`)).finally(() => process.exit(0));
}
