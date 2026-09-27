---
summary: "Handoff for the in-progress cloud-session usage sync: goal, what is done, the hook's wire format with a cross-language fixture, remaining phases, open owner decisions, and one-time CloudKit setup."
read_when:
  - Continuing work on branch claude/cloud-token-usage-t5wnk6 (cloud-session sync / phone counting without the Mac)
  - Touching scripts/cloud-session-sync/ or the CloudUsage CloudKit record type
---

# Handoff: cloud-session usage sync (phone works without the Mac)

Branch: `claude/cloud-token-usage-t5wnk6` · Started in a Claude Code on the web session (Linux, no Swift
toolchain) · Continue on a Mac, where `swift build` / `swift test` / `xcodebuild` are available.

Read `CLAUDE.md` first — its rules (English commits/PRs, PR target `cte13/PokeTokenBar-iOS` with
`--repo`, defect protocol, provider-extension rule, `docs/reference/defect-log.md` before touching
CloudKit/caches) all apply. This branch already exists; keep working on it rather than opening a new one.

## 1. Goal (as the owner stated it)

1. Usage from **Claude Code on the web** (cloud containers) must be counted — tokens, cost, burn rate,
   companion progress — live, with no manual steps after one-time setup.
2. The **iPhone must be a full counter on its own**: with the MacBook off, the phone must still show
   up-to-date token totals, burn rate, official limits, and companion progress. The owner sometimes
   works only from the phone + cloud sessions.
3. iCloud (CloudKit) is the transport. The owner's Apple team `B2G47QWXN7` **owns**
   `iCloud.io.github.chattymin.poketokenbar` (the name is historical; confirmed by the owner).

## 2. Why this is needed

- The app counts tokens by reading local transcripts (`~/.claude/projects/**/*.jsonl`,
  `LocalUsageReader.parseClaudeLine`). Cloud sessions write those files inside a disposable container,
  never on the Mac.
- The iPhone does not count anything: the Mac builds `PhonePayload` and writes it to the private CloudKit
  DB (`PokeTokenBarShared/.../CloudKitSync.swift`); the phone only displays it. Mac off → phone frozen.
- Official limits (`OAuthLimitsProvider`, `api.anthropic.com/api/oauth/usage`) did **not** move with cloud
  usage for the owner (0% after cloud work). Owner's working theory: cloud sessions consume prepaid
  credits / extra usage first. Unverified. The usage response has an `extra_usage` object the app ignores
  today (only seen as `{"is_enabled":false}` in the fixture at
  `Tests/PokeTokenBarTests/PokeTokenBarTests.swift:169`). Capture a real response from the owner's
  account before modelling it.

## 3. Done so far (commit `4dcddb9`)

`scripts/cloud-session-sync/`:

| File | What it does |
|---|---|
| `ptb-cloud-sync.mjs` | Claude Code hook (Stop / SubagentStop / SessionEnd). Trims the session transcript + `<session>/subagents/*.jsonl` to usage-only lines, dedups per `(message.id, requestId)` keeping the max total at the first position, chunks (5000 entries), encrypts, and `forceReplace`s records in the **public** DB via CloudKit Web Services (server-to-server key, signature V1). Uses `curl` (honours proxy/CA; Node 22 `fetch` does not). Only changed chunks upload (state in `~/.cache/poketokenbar-cloud-sync/uploaded.json`). Never fails the turn; errors → `~/.cache/poketokenbar-cloud-sync/log`. |
| `install.sh` | For the cloud environment's setup script. Copies/downloads the hook to `~/.claude/hooks/` and merges it into `~/.claude/settings.json` (user level → every repo). Idempotent. `PTB_SYNC_RAW_BASE` overrides the raw URL (defaults to `main`). |
| `ptb-cloud-sync.test.mjs` | `node --test scripts/cloud-session-sync/ptb-cloud-sync.test.mjs` — 10/10 pass. Covers trimming (no prompt/content/cwd leaks), dedup, chunk stability, wire format, signing, request body, subagent pickup, skip-unchanged. |

Measured: a 1.1 MB real transcript → 52 turns → one 4.5 KB encrypted record.

**Not yet verified live:** reachability of `api.apple-cloudkit.com` from cloud containers, the server key,
just-in-time schema creation from Web Services in the Development environment, and indexes. See §6.

### Wire format (the app must implement the reader side exactly)

- Shared secret `S` = 32 random bytes, base64 (`openssl rand -base64 32`).
- Derived with HMAC-SHA256(S, label):
  - encryption key = `HMAC(S, "ptb-cloud-usage/enc/v1")` (32 bytes, AES-256)
  - channel = hex(`HMAC(S, "ptb-cloud-usage/channel/v1")`)[0..<32]
  - recordName = `"cu_" + hex(HMAC(S, "ptb-cloud-usage/record/v1|<rel>|<chunk>"))[0..<40]`
- Record type `CloudUsage`, public DB, fields: `channel` (String), `updatedAt` (Date/TIMESTAMP ms),
  `payload` (Bytes).
- `payload` = AES-256-GCM combined box `nonce(12) ‖ ciphertext ‖ tag(16)` — exactly what
  `CryptoKit.AES.GCM.SealedBox(combined:)` takes.
- Plaintext = **raw deflate** (RFC 1951, no zlib header) of JSON
  `{"v":1,"rel":"<project>/<session>.jsonl","chunk":N,"jsonl":"<lines>\n"}`.
  On Apple: `(data as NSData).decompressed(using: .zlib)` is raw deflate.
- `rel` shapes: `<project>/<session>.jsonl` or `<project>/<session>/subagents/<agent>.jsonl`.
- Each `jsonl` line is exactly what `LocalUsageReader.parseClaudeLine` reads:
  `{"type":"assistant","timestamp":…,"requestId":…,"message":{"id":…,"model":…,"usage":{…}}}`.
- `cost-state` lines are deliberately **not** sent: `applyReportedCost` spreads a whole-session cost over
  the entries of one file, which would double count across chunks. Cloud turns are priced from
  `ModelPricing` (`claude-opus-5-5` etc. are present).

### Cross-language fixture (put this in the Swift test; the Node test prints the same values)

```
secret  = bytes 0x01, 0x02, …, 0x20 (32 bytes)
nonce   = bytes 0xA0 … 0xAB (12 bytes)
payload = {"v":1,"rel":"proj/s.jsonl","chunk":2,"jsonl":"{\"a\":1}\n"}
channel    = eb4bca572ba7c3fab549b8d529a9f79a
recordName = cu_5d5e8e9f412201ae5b00dcc97138f0aecb8317d1   (rel "proj/s.jsonl", chunk 2)
box (b64)  = oKGio6Slpqeoqaqr3+gleGVX1SySEWRalLGzyz0L/07zxidj+o6Hl/VVwIy6wrEL3exVAigHw0pe0xFfOE59T3L87MdnYl8//YZK0PqRJPUmmNydnhU=
```

The Swift test must decrypt `box` to that payload and derive the same channel/recordName. If the Node
test's printed values ever change, update both sides together.

## 4. Remaining work (one PR per phase; each is usable alone)

### Phase 1 — shared usage ledger + counting on both devices (do first)

Target: phone shows today/week/month tokens, cost, and burn rate including cloud sessions **and** Mac
usage, with the Mac off.

1. **Move the counting engine to `PokeTokenBarShared`** so Mac and iPhone compute identical numbers:
   `LocalUsageReader.Entry`, `dedupKeepMax`, `daily`/`period`/`activeBlock`/`startOfWeek`/`monthKey`,
   `ProviderEnrichment.local`, `ModelPricing`, `UsageCost`. Keep file-system scanning on the Mac.
   Watch the defect log's "append-only watermark" (#157) note — one assembly site, not copies.
2. **Cloud records reader (Shared)**: `CloudSessionCrypto` (derive keys, open box, inflate, validate
   `rel`: no absolute path, no `..`/empty/`.`-prefixed components — `jsonlFiles` uses
   `skipsHiddenFiles` — must end `.jsonl`, `chunk >= 0`) + a query of public DB `CloudUsage` where
   `channel == X AND updatedAt > watermark − overlap` (paginate with the cursor; set
   `timeoutIntervalForRequest`). Use a 10-minute overlap: `updatedAt` is the container's clock.
3. **Mac: mirror cloud records into a scanned folder.** Write each record to
   `AppStatePaths.directory()/cloud-sessions/c<chunk>/<rel>` (atomic, only if bytes changed). The
   `c<chunk>/` prefix keeps `claudeSessionID(forTranscript:)` correct. Add that folder to
   `LocalUsageReader.computeClaudeProjectRoots` as a curated root via a new parameter defaulting to
   `nil` (tests pass a `home` and must stay hermetic — see `LocalUsageReaderTests` ~L210–L285,
   `CustomScanRootsTests` ~L170–L210) and to `CustomScanRoots.curatedRoots("claude_code")`. Pull at the
   start of `UsageStore.refresh()` with a short timeout so Phase 1 daily is never blocked.
   All Mac CloudKit calls go through `CloudSyncGate` (missing entitlement = SIGTRAP, not an error).
4. **Mac: publish its own usage to the ledger** so the phone can compute burn rate: upload trimmed
   entries for **every** local provider (not only Claude — keep it generic per
   `docs/reference/provider-extension.md`, no `== "claude_code"` branches) to the **private** DB
   (the Mac has the user's iCloud account; no encryption layer needed there). Same chunk/dedup idea,
   record per (provider, source file, chunk), upload only changed chunks.
5. **iPhone: count from the ledger** — private-DB Mac entries + public-DB cloud entries → shared engine
   → totals, cost, burn. Mac's `PhonePayload` stays the source for things not yet ported. Treat a Mac
   snapshot from a previous local day as zero for today.
6. **Shared secret distribution**: Settings row on Mac to generate/save the secret (store like
   `SessionKeyStore`: 0600 file in `AppStatePaths`, not Keychain — see `CredentialFileProtection` for
   why) and a "copy" button; Mac also writes it to a **private-DB** record so iPhone + widget pick it
   up with no step on the phone. UI strings via `L.t(...)` (6-arg overload for fork-only strings;
   German falls back to English).
7. Widget: include ledger totals within WidgetKit's refresh budget.

### Phase 2 — official limits on the phone

- Owner has **not yet confirmed** this approach. Proposal: phone fetches Claude limits itself with the
  claude.ai **session key** path (`SessionKeyLimitsProvider`; move the fetch to Shared). Do not copy the
  Claude Code OAuth token to the phone (refresh rotation would fight the CLI on the Mac).
  Key reaches the phone via the private DB (or entered on the phone). Whichever device fetched last
  publishes; both display the freshest.
- Other providers' limits (Codex, Cursor, …) stay Mac-only unless the owner asks.
- Consider surfacing `extra_usage` (credits) once a real enabled response is captured.

### Phase 3 — companion progress on the phone

- Owner has **not yet confirmed**. Proposal: companion state in the private DB with a **single-writer
  lease** (~10 min, renewed by the holder). Mac holds it while awake; when it lapses the phone acquires
  it and advances progress from the ledger; the Mac loads the phone's state before resuming.
  Reason: `CompanionStore.applyUsage` mutates state incrementally (`usedAtStage += delta`, per-provider
  ledger watermarks) and uses random picks, so two concurrent writers diverge.
- Requires moving the companion engine to Shared and making the phone's Shop/Bag/Collection tabs
  writable. Largest piece — read `docs/reference/defect-log.md` (save migration, CloudKit) first.

## 5. Ask the owner before building

- Phase 2: session-key route OK? (keys expire every few weeks; the app already shows an expiry badge)
- Phase 3: single-writer lease handoff OK?
- Mac → private DB upload in Phase 1 includes all providers' usage metadata (no prompts). Confirm.

## 6. One-time setup + first live check (do this before writing Phase 1 Swift)

1. `openssl ecparam -name prime256v1 -genkey -noout -out ptb-cloudkit.pem` and
   `openssl ec -in ptb-cloudkit.pem -pubout`.
2. CloudKit Console → the container → **Development** → Tokens & Keys → Server-to-Server Keys → add the
   public key; note the Key ID.
3. `openssl rand -base64 32` → the shared secret.
4. Cloud environment settings (environment menu → Edit): env vars `PTB_SYNC_SECRET`,
   `PTB_CLOUDKIT_KEY_ID`, `PTB_CLOUDKIT_PRIVATE_KEY` (PEM or base64 of PEM); optional
   `PTB_CLOUDKIT_ENV` (default `development` — must match the environment the Mac/iPhone builds use;
   xcodebuild development signing → Development) and `PTB_CLOUDKIT_CONTAINER`. Allow
   `api.apple-cloudkit.com` in Network access. Setup script (until merged to `main`):
   ```
   curl -fsSL https://raw.githubusercontent.com/cte13/PokeTokenBar-iOS/claude/cloud-token-usage-t5wnk6/scripts/cloud-session-sync/install.sh \
     | PTB_SYNC_RAW_BASE=https://raw.githubusercontent.com/cte13/PokeTokenBar-iOS/claude/cloud-token-usage-t5wnk6 bash
   ```
5. Start a new cloud session, do one turn, then check the Console → Records → public DB for
   `CloudUsage`. If absent, read `~/.cache/poketokenbar-cloud-sync/log` in that session.
6. In the Console add indexes on `CloudUsage`: `channel` QUERYABLE, `updatedAt` QUERYABLE + SORTABLE
   (and `recordName` QUERYABLE if the query complains). Before any production build, deploy the schema
   to Production and point `PTB_CLOUDKIT_ENV` at it.

## 7. Known limits / follow-ups

- Public-DB records accumulate; add pruning (e.g. delete records older than ~40 days) later.
- `updatedAt` is client time; the overlap window covers skew, dedup covers re-reads.
- Streaming duplicates across chunks are collapsed by the Mac's global `dedupKeepMax`.
- Hook runs synchronously in Stop (≈1 request, 20 s cap). Concurrent Stop/SubagentStop can race on
  `uploaded.json`; worst case is a redundant upload.
- When done, replace this handoff with a permanent `docs/reference/cloud-session-sync.md` (same
  frontmatter style) describing the finished design, and remove its row from the `CLAUDE.md` index.
