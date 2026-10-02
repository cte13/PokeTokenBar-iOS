---
summary: "How Claude Code on the web gets counted, and how the iPhone counts usage with the Mac off: why no secret lives in the cloud container, the hook's wire format and relay, the Mac mirror, the private-DB usage ledger, the phone overlay, CloudKit schema and setup, and the remaining phases (limits, companion)."
read_when:
  - Touching scripts/cloud-session-sync/ (hook or relay), CloudSessionSync.swift, or the PokeTokenBarShared usage engine / ledger / overlay
  - Adding a provider to the phone ledger (`UsageProvider.phoneLedgerEntries`)
  - Adding or changing a CloudKit record type (CloudUsage, UsageLedgerChunk, UsageLedgerManifest, CloudSessionKey)
  - Continuing Phase 2 (limits on the phone) or Phase 3 (companion on the phone)
---

# Cloud-session sync and counting on the iPhone

## Goal

1. Usage from **Claude Code on the web** (disposable cloud containers) is counted everywhere —
   tokens, cost, burn, companion — with no manual step after one-time setup.
2. The **iPhone counts on its own**: with the Mac asleep or off, it still shows current totals,
   cost and burn rate.

Transport is CloudKit, container `iCloud.io.github.chattymin.poketokenbar` (owned by team
`B2G47QWXN7`; the name is historical).

## Data flow

```
cloud container ──hook──▶ relay (Cloudflare Worker) ──signed──▶ public DB  CloudUsage (sealed, per chunk)
                                │                     │
                        Mac: CloudSessionMirror   iPhone/widget: PhoneUsageSync
                        writes files into a            │
                        curated Claude root            │
                                │                      │
Mac scan (all numbers,  ◀───────┘                      │
companion) ──PhoneLedgerPublisher──▶ private DB  UsageLedgerChunk + UsageLedgerManifest
                                                       │
                     Mac PhonePayload (private DB) ──▶ PhoneLedgerOverlay ──▶ dashboard + widget
```

- **One engine.** Entries, pricing and every aggregation live in
  `PokeTokenBarShared/UsageEngine.swift` (`UsageEntry`, `UsageBucket`, `UsageAggregation`,
  `ModelPricing`, `ProviderEnrichment.local`). The Mac keeps its historical names as typealiases
  and forwarders (`LocalUsageReader.Entry`, `DailyUsage`, …). Do not fork a phone copy.
- **Entries, not totals, cross devices.** A cloud turn reaches the phone twice: directly, and
  through the Mac's ledger after the Mac mirrored it. Only entries merge without double counting
  (`dedupKeepMax` by `message.id|requestId`).

## No secret in the cloud container

Cloud environment variables are readable by every session that uses the environment, including
Claude and any command it runs. A session that gets prompt-injected could leak whatever is there.
The environment's **API credentials** keep a key out of the session, but only as a fixed header the
agent proxy attaches to requests for listed hosts. CloudKit Web Services instead needs a fresh ECDSA
signature over the date and the body hash on every request. So:

- **Confidentiality uses a device key pair.** The Mac creates an X25519 key pair. The container gets
  only the public key (`PTB_SYNC_PUBLIC_KEY`, fine as a plain variable). The private key lives on the
  Mac and in the user's private iCloud DB, where the iPhone reads it.
- **Writes go through a relay.** `relay/worker.mjs` is a Cloudflare Worker that holds the CloudKit
  signing key. Sessions call it with no secret of their own. The Bearer token is an environment API
  credential for the relay's host, so the proxy attaches it and the session never sees it. The relay
  accepts only `forceReplace` of well-formed `CloudUsage` records, so a leaked relay URL writes
  nothing, and even a leaked token could only add records that look like usage.

## Hook → relay → public DB (`scripts/cloud-session-sync/`)

`ptb-cloud-sync.mjs` runs on Stop / SubagentStop / SessionEnd inside the cloud container. It trims
the transcript and its `subagents/*.jsonl` down to usage lines, dedups per turn, chunks (5000),
seals each chunk to the device public key, and posts the records to `PTB_RELAY_URL/upload`. Only
changed chunks upload. It never fails the turn. Every run overwrites
`~/.cache/poketokenbar-cloud-sync/status` with one line (uploaded N, up to date, skipped and why,
or failed), and uploads and errors are appended to `.../log`. Run `cat` on the status file in a
cloud session first when diagnosing. Tests:
`node --test scripts/cloud-session-sync/ptb-cloud-sync.test.mjs scripts/cloud-session-sync/relay/worker.test.mjs`.

Wire format (reader: `CloudSessionCrypto`):

- Device key P = X25519 public key (32 bytes, base64 in the environment). The channel is
  hex(SHA-256("ptb-cloud-usage/channel/v2" ‖ P))[0..<32], and recordName is
  `cu_` + hex(SHA-256("ptb-cloud-usage/record/v2|<rel>|<chunk>" ‖ P))[0..<40].
- Each record uses a fresh ephemeral key E. The payload is E.pub(32) ‖ nonce(12) ‖ AES-256-GCM
  ciphertext ‖ tag(16), with key = HKDF-SHA256(X25519(E, P), salt E.pub ‖ P, info
  "ptb-cloud-usage/seal/v2"). The ciphertext covers raw deflate of `{"v":2,"rel","chunk","jsonl"}`.
- Record `CloudUsage`: `channel` (String), `updatedAt` (Date — the container's clock), `payload` (Bytes).
- `rel` is validated on read (relative, no `.`/`..`/empty/hidden components, `.jsonl`).
- `cost-state` lines are not sent. `applyReportedCost` spreads a session's cost over one file's
  entries, which would double count across chunks. Cloud turns are priced from `ModelPricing`.
- The cross-language fixture is pinned on both sides: the Node test "fixture values for the Swift
  test" and `CloudSessionCryptoTests` (Swift opens the box Node sealed). Change both together.

## Mac

- `CloudSessionKeyStore`: the device private key in a 0600 file `cloud-session-key.txt` in
  `AppStatePaths`, not Keychain (see `CredentialFileProtection`). Settings → "Claude Code on the web"
  creates the key pair, shows and copies the public key, and removes it. The private key is also
  written to the private DB (`CloudSessionKey`), which is how the phone gets it. At launch the Mac
  publishes its key, or adopts the one in iCloud if it has none (a reinstalled Mac).
- `CloudSessionMirror`: started (not awaited) at the top of `UsageStore.refresh()`. It queries
  `channel == X AND updatedAt > watermark − 10 min` (the first pull reaches back 40 days), writes
  each chunk to `<state>/cloud-sessions/c<chunk>/<rel>` only if the bytes changed, and triggers one
  more refresh when a file changed. The folder is a curated Claude root
  (`computeClaudeProjectRoots(cloudSessionsRoot:)`, `CustomScanRoots.curatedRoots`). An unopenable
  record is skipped, and the watermark still moves past it. A failed fetch moves nothing.
- `PhoneLedgerPublisher`: after Phase 2 of each refresh, providers that implement
  `UsageProvider.phoneLedgerEntries(now:)` publish their enrichment-window entries as
  `UsageLedgerChunk` records (one per provider, Mac-local day and chunk of 4000; deflated compact
  JSON). Then a `UsageLedgerManifest` lists every chunk with its SHA-256. Only changed chunks upload.
  Days that left the window are deleted. A failed upload leaves the saved manifest alone, so the next
  refresh retries. **Only Claude opts in** (owner decision 2026-09-28). To add a provider, implement
  `phoneLedgerEntries`; there is no id branch anywhere.
- Every CloudKit call uses `UsageCloudKit.operationConfiguration()`: `.userInitiated` with a
  120-second resource cap. At CloudKit's default `.utility`, a menu-bar app's requests are
  discretionary and are held while a MacBook runs on battery (see the defect log).
- Every CloudKit call goes through `CloudSyncGate`. The new calls throw `CloudSyncGate.Disabled`
  rather than returning, so a skipped call never records success. The production closures in
  `UsageStore` also require `AppEnv.isBundledApp`, so test stores never touch CloudKit.
- `PhonePayload.providers` now carries each provider's week, month, burn and daily series. The
  overlay needs that split.

## iPhone and widget

`PhoneUsageSync` (Shared; its state is in the App Group container, and the app and widget both
reload it per call):

1. `update(macPayload:)` keeps the raw Mac payload (iCloud or LAN), newest wins.
2. `syncLedger()` fetches the manifest, fetches only chunks whose digest changed (by record ID, so
   no index is needed), and pulls cloud records since the watermark.
3. `display()` runs `PhoneLedgerOverlay`. Providers the manifest lists are recounted from ledger and
   cloud entries. Every other provider keeps the Mac's numbers, but only while they still describe
   the current day, week or month; a Mac-reported burn rate counts only if under 10 minutes old.
   With no manifest (an older Mac), the Mac payload is shown as-is. `lastUpdated` =
   max(Mac, last ledger sync).

The widget refreshes before completing its timeline, with an 8 s budget before it falls back to the
cached count.

## CloudKit schema and one-time setup

Record types: public `CloudUsage`; private `UsageLedgerChunk`, `UsageLedgerManifest`,
`CloudSessionKey` (and the existing `Payload`). In Development, the private types are created the
first time the Mac app writes them. **`CloudUsage` is not**: the relay writes with a
server-to-server key, and CloudKit Web Services does not create record types. Every upload fails
with `NOT_FOUND could not find record_type with name 'CloudUsage'` until the type is created by
hand (step 6), as confirmed in the live setup on 2026-09-29. **Before any production build,
deploy the schema to Production**, and set the relay's `CLOUDKIT_ENV` (in `wrangler.toml`) to
`production`.

1. CloudKit signing key (PKCS#8, which the relay's WebCrypto needs):
   `openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ptb-cloudkit.pem`;
   `openssl pkey -in ptb-cloudkit.pem -pubout`.
2. CloudKit Console → container → Development → Tokens & Keys → Server-to-Server Keys → add the
   public key; note the Key ID.
3. Relay: `cd scripts/cloud-session-sync/relay`, `npx wrangler login`, `npx wrangler deploy`, then
   `npx wrangler secret put` for `CLOUDKIT_KEY_ID`, `CLOUDKIT_PRIVATE_KEY` (the PEM) and
   `RELAY_TOKEN` (`openssl rand -hex 32`). Note the `*.workers.dev` URL.
4. Mac Settings → Claude Code on the web → Create key → Copy (the public key).
5. Cloud environment: environment variables `PTB_SYNC_PUBLIC_KEY` and `PTB_RELAY_URL` (both
   public). Add an **API credential** for the relay's host with header `Authorization`, prefix `Bearer`,
   and the `RELAY_TOKEN` as its value. Setup script:
   `curl -fsSL https://raw.githubusercontent.com/cte13/PokeTokenBar-iOS/main/scripts/cloud-session-sync/install.sh | bash`
6. Console → Schema → Record Types → **+** `CloudUsage` with fields `channel` (String),
   `updatedAt` (Date/Time), `payload` (Bytes). Then add single-field indexes: on the record type
   page use the **•••** next to each field, or Schema → Indexes → **+** (an index's name is only a
   label). The indexes are `channel` QUERYABLE, `updatedAt` QUERYABLE + SORTABLE, and `recordName`
   QUERYABLE. Without the type the Mac logs `Did not find record type: CloudUsage`; without the
   indexes it logs `Type is not marked indexable: CloudUsage`. A failed upload is retried after the
   next cloud turn.
7. Check: send a message in a cloud session, then run `cat ~/.cache/poketokenbar-cloud-sync/status`
   there; it should say `uploaded N record(s)`. Within a refresh the Mac logs
   `cloud sessions: 1 record(s), 1 file(s) updated`.

## Known limits

- Public records accumulate. Pruning (e.g. delete records older than ~40 days) is not built yet; it
  would be a relay endpoint too.
- API credentials exist only on Pro and Max plans. On Team or Enterprise the relay token would have
  to be an environment variable, readable by sessions.
- The hook runs synchronously in Stop (about one request, 20 s cap). Concurrent Stop and
  SubagentStop hooks can race on `uploaded.json`; the worst case is a redundant upload.
- Cloud entries reach the phone's count only while the Mac's manifest lists Claude. A phone paired
  with a Mac that never published a ledger shows the Mac payload only.

## Remaining phases (owner approved 2026-09-28)

### Phase 2: official Claude limits on the phone (built)

- The Mac shares its claude.ai **session key** and the organization it resolved, as private-DB
  record `ClaudeSessionKey` (`UsageStore.shareSessionKeyIfChanged`, after each limits fetch). It
  shares again only when the pair changes. Removing the key deletes the record, and a failed share
  retries at the next refresh. The Claude Code OAuth token is never shared: its refresh rotation
  would fight the CLI on the Mac. A Mac with no session key (OAuth only) shares nothing, and the
  phone keeps showing the Mac's last limits.
- The phone sends the Mac's exact request (`ClaudeWebUsage.request` builds the headers for both
  devices) to `/api/organizations/{org}/usage`, at most once per `LimitsPollCadence.minimumInterval`
  across the app and the widget (`PhoneUsageSync.syncClaudeLimits`):
  - On 401 it stops until the Mac shares a new key.
  - On 403 (lost access, or a Cloudflare challenge; the phone can't tell which) it backs off 30
    minutes. On 429 it backs off per Retry-After, defaulting to 10 minutes.
  - It never rediscovers organizations; that stays on the Mac.
- `PhoneClaudeLimits.windows` is the one Claude-window mapping. The Mac uses it with its
  localized labels, and the phone uses it with the labels the Mac last sent, matching per-model
  windows by `PhoneLimitWindow.scopeModel`, never by localized text. The phone's limits replace
  the Mac's only while they are newer than the Mac payload.
- The limit models (`LimitStatus`, `LimitWindow`, `OAuthLimitEntry`), `LimitsPollCadence` and the
  5-hour depletion math (`ClaudeLimitForecast`) moved to `PokeTokenBarShared/ClaudeLimits.swift`.
- Not built: recomputing the 5-hour depletion forecast on the phone, and other providers' limits
  (they stay Mac-only). `extra_usage` (credits) is still ignored.
- Owner step: Mac Settings → Advanced → claude.ai session key. Paste the `sessionKey` cookie from
  a browser logged in to claude.ai. Keys expire every few weeks, and the app shows an expiry badge.

### Phase 3: companion progress on the phone

Companion state moves to the private DB under a **single-writer lease** (~10 min, renewed by the
holder). The Mac holds it while awake. When the lease lapses the phone takes it and advances progress
from the ledger count, and the Mac loads the phone's state before resuming. The lease exists because
`CompanionStore.applyUsage` mutates incrementally and uses random picks, so two writers would diverge.
This requires the companion engine in Shared and writable Shop, Bag and Collection tabs on the phone.
Read the defect log (save migration, CloudKit) first.
