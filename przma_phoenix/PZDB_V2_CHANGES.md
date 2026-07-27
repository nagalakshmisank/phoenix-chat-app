# What's different in this build

Base: your working `przma-phoenix` code. Scope: file service / CAS only, dev
and test use, no production data touched.

## 1. mark_synced corruption fix

`record` writes were partial (`{id, upload_status, updated_at}` only).
`PzDb.write` backfills any field missing from the record with a blank
default before upserting — since upsert is delete-by-id-then-add, this wiped
`name`/`content_cas`/`size_bytes`/etc. back to blank on every `mark_synced`
call. This matches the exact corruption bug already found and fixed on the
`local-side-s3-sync` branch (per the team's handoff doc), but that fix was
never merged into this branch — it was still present before this change.

Fixed to read-modify-write: fetch the existing record via `PzDb.query`
(backed by the real `pzdb_read_many` NIF function), merge only the changed
fields (`upload_status`, `updated_at`) into it, write the full merged record
back.

Blast radius checked: `mark_synced/2` is reachable only via
`POST /sync/mark-synced`; nothing else in the codebase calls it directly;
the Swagger request/response schema (`{file_id, space}` in,
`{file_id, status}` out) is unchanged.

`list_pending` / the `sync_queue` table left as-is per instruction — not
reconciled with the handoff's "neutralize it" approach. Revisit later if
needed.

## 2. social/circle migration (CircleSync, ActivitySync)

`lib/przma/social/circle_sync.ex` and `lib/przma/social/activity_sync.ex`
previously bypassed `PzDb` entirely, calling `PRZMA.PzDb.NIF` directly with
their own hand-built path (`{vault_base}/{sanitized_did}/social`, no `space`
segment at all — didn't fit `Namespace`'s grammar).

Migrated to the same pattern as auth/files: both now `alias PRZMA.PzDb` and
build proper `pzdb://{did}/social/core/{res_type}/{id}` URIs, resolved
through `Namespace` like everything else.

**Only the private storage helpers changed** — `upsert/2-3`, `read_table/2`,
`resolve_invite/1` in `circle_sync.ex`; `upsert/3`, `read_table/2` in
`activity_sync.ex`. Every public function and every existing call site
throughout both files (`create_circle`, `join_circle`, `approve_member`,
`publish`, `list_inbox`, etc.) is untouched — they still call the same
private helpers with the same table names ("circles", "circle_members",
"circle_invites", "circle_pins", "outbox", "inbox"); only what those helpers
do internally changed.

- Added `"social"` to `Namespace`'s `@valid_services` (same fix pattern as
  `"auth"` below).
- Table names are singularized before building the URI, then
  re-pluralized by `Namespace.resolve` — verified each one lands on the
  exact string the Rust NIF's `schema_for` matches: `circle`→`circles`,
  `circle_member`→`circle_members`, `circle_invite`→`circle_invites`,
  `circle_pin`→`circle_pins`. `outbox`/`inbox` pass through unchanged
  (already in the exact-match exception list).
- `circle_invites` needs to resolve for *any* user presenting an invite
  code, so it's kept under a fixed pseudo-owner DID (`"przma-directory"`)
  instead of a real one — same convention the codebase already uses
  elsewhere, and `Namespace` doesn't validate DID format so this is safe.
- **Physical S3 path changes** — this was dev/test data only (per earlier
  confirmation), so no migration script was written. If any circle/social
  test data already exists under the old ad-hoc path, it won't be found
  under the new one; re-run your test scenarios fresh.
- Verified with `Namespace.resolve/2` directly (not just reasoning about
  it) — every table name produces the exact expected string with no errors.

## 3. Auth fix (prerequisite — was about to break)

Production `PzDb.resolve/1` now delegating to `Namespace` would have broken
every `PRZMA.Auth` call (`register`, `login`, OTP, password reset — all use
`service = "auth"`) since `"auth"` wasn't in `Namespace`'s `@valid_services`.
Fixed by adding it. Verified directly with `Namespace.resolve/2` — auth and
sessions paths now resolve correctly and land on the exact schema names
(`auth`, `sessions`) the Rust side expects.



`lib/przma/pzdb/pzdb.ex` — `resolve/1` now delegates to
`PRZMA.Platform.Namespace.resolve/2` instead of building its own path, exactly
as requested:

```elixir
defp resolve(pzdb_uri) do
  root = global_base()
  PRZMA.Platform.Namespace.resolve(root, pzdb_uri)
end
```

This is now the single source of truth for path shape and
service/space validation, used by both the file service and (once you extend
scope) everything else.

### Why this needed two more fixes to actually work

- **Table-name pluralization mismatch.** `Namespace.resolve` auto-pluralizes
  the URI's resource-type segment (`file` → `files`). Your existing URIs
  already used the plural form directly (`.../files/#{space}/files/#{id}`),
  which would have become `filess`. Fixed the 4 call sites in
  `file_sync_controller.ex` that build "files" table URIs to use the singular
  `file` segment, so Namespace re-pluralizes back to the same `files` table
  you already have.

- **Schema-name exact match.** The Rust side's `schema_for/1` matches a few
  table names *literally*: `cas_meta`, `auth`, `sessions`, `outbox`, `inbox`.
  If `Namespace` pluralized `cas_meta` → `cas_metas`, it would silently fall
  through to the generic files schema — the exact CAS ref-count bug already
  fixed once in this codebase. Added an exception list to
  `lib/przma/platform/namespace.ex`'s `table_for/1` so these stay unpluralized.

- **`sync_queue` didn't fit the space model.** `.../files/sync_queue/#{id}`
  had no valid space segment (`core`/`commons`/`circle:*`) — `Namespace`
  requires one and would raise `unknown space`. Fixed both `sync_queue` URIs
  to `.../files/core/sync_queue/#{id}`. **Behavior change worth testing**: the
  old code's fallback parsing put the file_id in the *table* position, so
  every queued file effectively got its own table. It now lands in one shared
  `sync_queues` table, which is almost certainly what was intended, but
  re-test `mark_synced` / `list_pending` explicitly.

- **`cas_meta` URIs needed no changes** — they already had a valid space
  segment and, with the exception list above, resolve to the same table name
  as before.

## 4. PzDbV2 — the six enterprise pieces, trial-scoped to CAS

`lib/przma/pzdb_v2/` — WriteRouter, VaultWriter, HealthMonitor, ReadCache,
Compaction (disabled), Supervisor, and a fixed `pzdb.ex`, all under the
`PRZMA.PzDbV2` namespace so nothing collides with production `PzDb`.

Fixed from the original enterprise code:
- Wrong NIF module aliased (`PRZMA.Calendar.NIF`, a stub) → now
  `PRZMA.PzDb.NIF`, the real working one. Same bug existed in `compaction.ex`
  in two more places.
- `resolve_table_path` fused the connection directory and table name into one
  string and passed it as the table-name argument to the NIF — LanceDB
  rejects `/` in table names, so this would have failed. Replaced entirely
  with a delegate to `Namespace.resolve/2`, same as production PzDb, which
  also fixes the missing DID colon-sanitization the original had.
- `VaultWriter.active_dids/0`, called by Compaction, was never implemented.
  `NIF.pzdb_compact/2`, also called by Compaction, doesn't exist even in the
  real Rust NIF. **Compaction stays disabled** in `supervisor.ex` until both
  exist — don't turn it on without writing that Rust function first.
- `provision_vault/1` (bootstraps tables for all 9 services) has the same
  pluralization problem across ~20 entries and references a `"social"`
  service that isn't in `Namespace`'s valid service list. Only the `files`
  entry is fixed — this function is **not safe to call** beyond that until
  each service's paths are reviewed. Out of scope for this trial.
- Encryption stays **off** (`encrypt: false`) — depends on `EncryptionContext`,
  which depends on the same broken NIF path. Separate fix.

## 5. Wired in

- `lib/przma/application.ex` — `PRZMA.PzDbV2.Supervisor` added to the
  supervision tree.
- `lib/przma_web/controllers/file_sync_controller.ex` — the CAS metadata
  write/ensure_table calls in `record_cas_meta/5` now go through `PzDbV2`
  instead of `PzDb`. Everything else in the controller (and every other
  service in the app) is untouched and still uses production `PzDb`.

## Verification done, and what's left

Elixir isn't able to reach `hex.pm` in the sandbox this was built in, so a
real `mix deps.get` / `mix compile` couldn't be run end-to-end here. What was
verified instead: an isolated `elixirc` compile of the entire `lib/` tree,
which surfaced and let me fix every real cross-module bug above (wrong NIF
module, fused path/table string, missing functions, pluralization mismatches).
The only remaining compile error found (`Phoenix.Presence` not loaded) is
purely a missing-hex-dependency artifact of the sandbox, unrelated to any of
these changes.

To actually run it:
```
git checkout -b pzdb-v2-namespace-trial   # keep this off main
mix deps.get
mix compile
mix phx.server
```
Then hit `/api/openapi` / `/swaggerui` and exercise the file-sync endpoints —
upload → `mark_synced` → `list_remote` → `sync/cas-meta` — and check the S3
bucket for the new `PzDbV2`-shaped paths.
