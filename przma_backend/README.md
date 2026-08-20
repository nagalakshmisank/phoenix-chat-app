# PRZMA Backend — Keycloak + REAL pzdb/Lance Profile & Spaces

Standalone, runnable Phoenix project implementing: Keycloak JWT auth,
the pzdb:// namespace/authorization layer, and profile + 3-default-space
(vault/public/professional) provisioning — now wired to the REAL
`przma_pzdb_nif` LanceDB NIF (found in the mentor's other repo,
`phoenix-chat-app-circle`), not a placeholder.

## Run it

```bash
mix deps.get
mix compile   # compiles the real Rust NIF via Rustler — needs your
              # real Rust toolchain, NOT apt's (too old). Per the
              # crate's own Cargo.toml: use lancedb 0.9 + arrow
              # 52.2.0, or lancedb 0.10 + arrow 53 if you hit a lance
              # recursion-overflow error. Also: Rust 1.97.1 is known
              # to cause that overflow — use 1.95.0 (per your own
              # JuiceFS doc's note on this exact issue).

export KEYCLOAK_URL=http://172.235.18.126:8180
export KEYCLOAK_REALM=przma
export VAULT_BASE_PATH=s3://perkeep
export CAS_BACKEND=s3
export AWS_ENDPOINT=https://in-maa-1.linodeobjects.com
export AWS_DEFAULT_REGION=in-maa-1
export S3_REGION=in-maa-1
export AWS_ACCESS_KEY_ID=<rotate the key you pasted in chat before using it>
export AWS_SECRET_ACCESS_KEY=<same>
export SECRET_KEY_BASE=$(mix phx.gen.secret)

mix phx.server
# -> http://localhost:4200
```

Get a real Bearer token first, straight from Keycloak:
```bash
curl -X POST http://172.235.18.126:8180/realms/przma/protocol/openid-connect/token \
  -d "client_id=przma-app" -d "client_secret=przma-secret-2024" \
  -d "grant_type=password" -d "username=kc_user1" -d "password=<their password>" \
  -d "scope=openid profile email"
```

## Test in Swagger

Once `mix phx.server` is running, open **http://localhost:4200/swaggerui**
in a browser — the same `open_api_spex` pattern your real,
already-working project uses (`PRZMAWeb.ApiSpec` + `PutApiSpec` +
`OpenApiSpex.Plug.SwaggerUI`), ported here and scoped to this
project's actual 4 endpoints rather than copying your other project's
full files/social/circles surface. Ships its own bundled UI assets —
no CDN dependency, unlike an earlier version of this file. The raw
spec JSON is also servable directly at `/api/openapi`, in case you
want to feed it to another tool (Postman's "Import from URL", etc.).

Click **Authorize**, paste a Keycloak `access_token`, then try each
endpoint live. The spec itself lives in `lib/przma_web/api_spec.ex` —
edit that file directly (not a static yaml) to add or change
documented endpoints; it's the single source of truth, generated at
request time, so there's nothing to keep in sync manually.

## What changed since the last version of this project — read before running

The earlier version of this project used a placeholder adapter
(plain JSON to S3 via ExAws) because the real Rust NIF wasn't
available. It has since been found — in your other repo,
`phoenix-chat-app-circle`, at
`native/przma_pzdb_nif/src/lib.rs` + `lib/przma/pzdb/{nif,pzdb}.ex` —
and is now wired in for real. Three things changed as a direct result,
all worth your team's attention before this goes further:

### 1. It is NOT verified compiling — I tried, and hit a sandbox limit
`lib.rs`'s own header comment says it was never compiled by whoever
wrote it either ("NOT compiled in the assistant's sandbox — build it
in your container"). I installed a Rust toolchain here and ran
`cargo check`: dependency resolution succeeded and pulled the exact
arrow/lancedb versions the Cargo.toml specifies, but failed on a
transitive dependency requiring `edition2024`, which needs a newer
`rustc` than apt provides (1.75.0) — and I can't reach
`rustup.rs`/`static.rust-lang.org` from this sandbox to install a
newer one. **This means the 3 real functions (`pzdb_provision_table`,
`pzdb_upsert`, `pzdb_read_many`) are a credible, well-modeled attempt,
not a confirmed-working implementation.** Compile it for real in your
own environment before trusting it in production.

### 2. The real S3 path shape does NOT match anything designed earlier
The real, working `PRZMA.PzDb.resolve/1` builds paths as
`pzdb://{did}/{service}/{space}/{table}` — **no `tenant_uuid` segment
anywhere.** Every path shown earlier in this project's design
(`{tenant_uuid}/{did}/vault/profile.lance/`) does not match what this
real code actually produces. `lance_linode_adapter.ex` now bridges to
the real shape — tenant_uuid still gets stamped into each row's `gid`
field and still gates authorization, it's just not part of *where the
file lands in S3* anymore. Real path now:
```
s3://perkeep/did_przma_keerthi/vault/core/profile.lance
s3://perkeep/did_przma_keerthi/public/core/_meta.lance
s3://perkeep/did_przma_keerthi/professional/core/_meta.lance
```
This is a genuine architecture decision, not a cosmetic change —
confirm it with your supervisor.

### 3. "profile" and "_meta" needed NEW schema entries in the Rust code
The real `lib.rs` had no `"profile"` or `"_meta"` case in `schema_for`
— both were silently falling through to `files_schema()` (a 22-column
schema built for file records), which would have written a mostly-
garbage row for both. I added `profile_schema()`/`json_to_profile_batch`
and `space_meta_schema()`/`json_to_space_meta_batch`, following the
exact pattern already used for `contacts`/`circles` etc. in the same
file. **These are proposed additions for your team's review** — same
unverified-compilation caveat as point 1 applies to them too.

### 4. `pzdb_read` (single-record fetch) is a real stub — always null
Confirmed in `lib.rs`'s own `// STUBS` section. `Profile.get/2` now
goes through `pzdb_read_many` with a `did = '...'` filter and
`limit: 1` instead, since that path IS real.

## Endpoints

| Method | Path | Auth |
|---|---|---|
| POST | `/api/v1/registration/complete` | Bearer |
| POST | `/api/v1/profile` | Bearer |
| GET | `/api/v1/profile` | Bearer |
| PATCH | `/api/v1/profile` | Bearer |

## Still stubbed on purpose (not yet designed, not blockers for this scope)

`lib/przma/identity/stubs.ex`, `lib/przma/federation/stubs.ex` —
capability grants, circles, federation. Every owner can read/write
their own `vault`/`public`/`professional` spaces; nobody else can
access anything yet (fails closed).
