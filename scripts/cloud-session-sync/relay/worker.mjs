// PokeTokenBar cloud-session relay — a Cloudflare Worker between cloud sessions and CloudKit.
//
// Why it exists: CloudKit Web Services needs every request signed with an EC private key
// (signature V1 over date, body hash and path). A cloud container cannot hold that key safely —
// environment variables are readable by every session — and the container's hidden "API
// credentials" can only attach a fixed header, not compute a signature. So the signing key lives
// here, and sessions reach this relay with a Bearer token that Anthropic's agent proxy attaches
// (an environment API credential), which the session itself never sees.
//
// It only ever does one thing: forceReplace `CloudUsage` records in the public database, with the
// exact fields the hook writes. Payloads are already encrypted to the user's device key, so the
// relay cannot read them either.
//
// Secrets (`npx wrangler secret put <NAME>`):
//   RELAY_TOKEN            random string; the same value goes into the cloud environment's API credential
//   CLOUDKIT_KEY_ID        server-to-server key ID from the CloudKit Console
//   CLOUDKIT_PRIVATE_KEY   the matching P-256 private key, PKCS#8 PEM ("BEGIN PRIVATE KEY")
// Variables (wrangler.toml): CLOUDKIT_CONTAINER, CLOUDKIT_ENV ("development" | "production").

export const MAX_RECORDS = 200;
/// A chunk of 5000 trimmed entries deflates to well under this; CloudKit's record limit is 1 MB.
export const MAX_PAYLOAD_BASE64 = 1_000_000;

export default {
  async fetch(request, env) {
    return handle(request, env, fetch);
  },
};

export async function handle(request, env, fetchImpl, now = new Date()) {
  const url = new URL(request.url);
  if (request.method !== 'POST' || url.pathname !== '/upload') return json(404, { error: 'not found' });
  if (!env.RELAY_TOKEN || !(await tokenMatches(request.headers.get('Authorization'), env.RELAY_TOKEN))) {
    return json(401, { error: 'unauthorized' });
  }

  let records;
  try {
    records = validate(await request.json());
  } catch (err) {
    return json(400, { error: String(err.message ?? err) });
  }

  const subpath = `/database/1/${env.CLOUDKIT_CONTAINER}/${env.CLOUDKIT_ENV || 'development'}/public/records/modify`;
  const body = modifyBody(records);
  const date = cloudKitDate(now);
  const signature = await sign(env.CLOUDKIT_PRIVATE_KEY, `${date}:${await sha256Base64(body)}:${subpath}`);
  const response = await fetchImpl(`https://api.apple-cloudkit.com${subpath}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Apple-CloudKit-Request-KeyID': env.CLOUDKIT_KEY_ID,
      'X-Apple-CloudKit-Request-ISO8601Date': date,
      'X-Apple-CloudKit-Request-SignatureV1': signature,
    },
    body,
  });
  // CloudKit's own response (per-record serverErrorCode) is what the hook reads.
  return new Response(await response.text(), {
    status: response.status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/// Accept exactly what the hook sends, nothing more: the token only lets a caller write
/// encrypted usage records, never arbitrary CloudKit operations.
export function validate(input) {
  const records = input?.records;
  if (!Array.isArray(records) || records.length === 0 || records.length > MAX_RECORDS) {
    throw new Error(`records must be an array of 1…${MAX_RECORDS}`);
  }
  return records.map((r, i) => {
    if (typeof r?.recordName !== 'string' || !/^cu_[0-9a-f]{40}$/.test(r.recordName)) throw new Error(`records[${i}].recordName`);
    if (typeof r.channel !== 'string' || !/^[0-9a-f]{32}$/.test(r.channel)) throw new Error(`records[${i}].channel`);
    if (!Number.isSafeInteger(r.updatedAt) || r.updatedAt <= 0) throw new Error(`records[${i}].updatedAt`);
    if (typeof r.payload !== 'string' || r.payload.length === 0 || r.payload.length > MAX_PAYLOAD_BASE64
        || !/^[A-Za-z0-9+/]+={0,2}$/.test(r.payload)) throw new Error(`records[${i}].payload`);
    return { recordName: r.recordName, channel: r.channel, updatedAt: r.updatedAt, payload: r.payload };
  });
}

export function modifyBody(records) {
  return JSON.stringify({
    atomic: false,
    operations: records.map((r) => ({
      operationType: 'forceReplace',
      record: {
        recordType: 'CloudUsage',
        recordName: r.recordName,
        fields: {
          channel: { value: r.channel, type: 'STRING' },
          updatedAt: { value: r.updatedAt, type: 'TIMESTAMP' },
          payload: { value: r.payload, type: 'BYTES' },
        },
      },
    })),
  });
}

export const cloudKitDate = (d) => d.toISOString().replace(/\.\d{3}Z$/, 'Z');

/// Constant-time over equal-length digests, so the comparison leaks nothing about the token.
async function tokenMatches(header, token) {
  const given = header?.startsWith('Bearer ') ? header.slice(7) : '';
  const [a, b] = await Promise.all([given, token].map((s) =>
    crypto.subtle.digest('SHA-256', new TextEncoder().encode(s))));
  const x = new Uint8Array(a), y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0 && given.length > 0;
}

async function sha256Base64(text) {
  return toBase64(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))));
}

/// ECDSA P-256 / SHA-256, DER-encoded as CloudKit expects. WebCrypto returns raw r‖s.
export async function sign(pem, message) {
  const der = fromBase64(pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const raw = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key,
    new TextEncoder().encode(message)));
  return toBase64(rawToDer(raw));
}

export function rawToDer(raw) {
  const integer = (bytes) => {
    let i = 0;
    while (i < bytes.length - 1 && bytes[i] === 0) i++;
    const trimmed = bytes.slice(i);
    const body = trimmed[0] & 0x80 ? [0, ...trimmed] : [...trimmed];
    return [0x02, body.length, ...body];
  };
  const seq = [...integer(raw.slice(0, 32)), ...integer(raw.slice(32))];
  return new Uint8Array([0x30, seq.length, ...seq]);
}

function toBase64(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function fromBase64(b64) {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

function json(status, value) {
  return new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
}
