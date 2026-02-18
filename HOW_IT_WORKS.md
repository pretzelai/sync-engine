# How the sync engine works (deep internal writeup)

This document is a code-accurate explanation of **how syncing is triggered, queued, processed, retried, and observed** in this repo. It is intended to be a “single source of truth” you can use while debugging production behavior.

It covers:
- **Supabase deployment & first-time setup**
- **Edge Functions and how they authenticate**
- **Database schema: runs, object runs, cursors**
- **pg_cron + pg_net trigger loop**
- **pgmq queue semantics**
- **Worker processing & re-queue behavior**
- **Webhook processing**
- **Event catch-up (`_event_catchup`)**
- **Sigma worker (separate loop)**
- **CLI modes (local/dev + backfills)**

Throughout, code references are to the monorepo package `packages/sync-engine`.

---

## Mental model (big picture)

There are **two complementary sync mechanisms**:

1. **Realtime updates via Stripe webhooks**
   - Stripe calls a Supabase Edge Function (`stripe-webhook`)
   - The engine verifies the signature, routes by event type, and upserts/deletes rows accordingly.

2. **Continuous reconciliation via a scheduled worker**
   - Postgres `pg_cron` periodically calls another Edge Function (`stripe-worker`) via `pg_net`
   - That worker pulls work items from a **durable pgmq queue**
   - Each work item is “sync the next page of object X”
   - If more pages exist, the worker **re-enqueues** the same object so it will be picked up again

Additionally:
- A special object `_event_catchup` uses Stripe Events API to catch missed webhook changes.
- If Sigma is enabled, a **separate Sigma worker** runs on its own schedule and continues via a self-trigger.

---

## Components and where they live

### Edge Functions (Supabase)

Source files (checked into this repo):
- `packages/sync-engine/src/supabase/edge-functions/stripe-setup.ts`
- `packages/sync-engine/src/supabase/edge-functions/stripe-webhook.ts`
- `packages/sync-engine/src/supabase/edge-functions/stripe-worker.ts`
- `packages/sync-engine/src/supabase/edge-functions/sigma-data-worker.ts`

Deployment plumbing (turns those TS files into deployable function bodies):
- `packages/sync-engine/src/supabase/edge-function-code.ts`
- `packages/sync-engine/src/supabase/supabase.ts` (Supabase Management API client + installer)

### Core engine

Main class:
- `packages/sync-engine/src/stripeSync.ts` (`StripeSync`)

Database access:
- `packages/sync-engine/src/database/postgres.ts` (`PostgresClient`)
- migrations in `packages/sync-engine/src/database/migrations/*.sql`
- migrations runner in `packages/sync-engine/src/database/migrate.ts`

### CLI (local/dev + manual backfill)

- `packages/sync-engine/src/cli/commands.ts`

---

## Setup & first deployment on Supabase

The install flow is orchestrated by `SupabaseSetupClient.install()`:
- `packages/sync-engine/src/supabase/supabase.ts`

At a high level it does:
1. Validate project access via Supabase Management API
2. Create schema (so it can store an installation comment marker)
3. Deploy edge functions
4. Set function secrets (env vars)
5. Invoke `stripe-setup` (POST) to run migrations + create a managed webhook in Stripe
6. Create pg_cron job(s) and queue(s)
7. Update schema comment to reflect successful installation

### Installation status marker

Supabase install writes a comment on the `stripe` schema used by `stripe-setup` GET “status” endpoint:
- logic in `packages/sync-engine/src/supabase/supabase.ts` (`updateInstallationComment`, `isInstalled`)
- status endpoint in `packages/sync-engine/src/supabase/edge-functions/stripe-setup.ts` (GET)

The comment includes `stripe-sync` plus suffixes like:
- `installation:started`
- `installation:error`
- `installed`

This is how the system distinguishes:
- “not installed”
- “installation started but incomplete”
- “installed”
- “failed install”

### `stripe-setup` Edge Function (install + uninstall + status)

`stripe-setup.ts` is a multipurpose function:
- **GET**: returns installation status and recent run summaries (if present)
- **POST**: runs migrations and creates/ensures a managed webhook
- **DELETE**: uninstall: deletes managed webhooks, unschedules cron, deletes vault secrets, drops schema, deletes edge functions and secrets

File: `packages/sync-engine/src/supabase/edge-functions/stripe-setup.ts`

#### Authentication model for `stripe-setup`

Every request must have `Authorization: Bearer <token>`.

`stripe-setup` then validates this bearer token by calling Supabase’s **Management API**:
- It extracts the project ref from `SUPABASE_URL`
- It calls `GET /v1/projects/{projectRef}` with that bearer token
- If that succeeds, the token is valid for that project

This is why `stripe-setup` can be invoked from the installer using the Supabase access token.

---

## Webhook path (realtime updates)

### How Stripe events reach the system

During install, `stripe-setup` creates (or reuses) a **managed webhook** in Stripe whose URL is:
- `SUPABASE_URL + '/functions/v1/stripe-webhook'`

`stripe-setup` uses:
- `StripeSync.findOrCreateManagedWebhook(url)` (in `packages/sync-engine/src/stripeSync.ts`)

### `stripe-webhook` Edge Function

File: `packages/sync-engine/src/supabase/edge-functions/stripe-webhook.ts`

Flow:
1. Requires `POST`
2. Reads `stripe-signature` header
3. Reads raw request body
4. Instantiates `StripeSync`
5. Calls `stripeSync.processWebhook(rawBody, sig)`

### Webhook signature verification

Inside `StripeSync.processWebhook(payload, signature)`:
- If `stripeWebhookSecret` is configured explicitly, it uses that.
- Otherwise it fetches the **managed webhook secret** from the DB table `stripe._managed_webhooks` scoped to the current account and uses it to verify the signature.

That’s why managed webhooks work even without the caller supplying a signing secret.

### Event routing

After signature verification, `StripeSync.processEvent(event)`:
1. Resolves the Stripe account ID for the current API key (and upserts account into DB if needed)
2. Looks up the handler in an `eventHandlers` map (event type → handler)
3. Calls the handler which upserts/deletes entities

The handler registry is in `packages/sync-engine/src/stripeSync.ts` as `eventHandlers`.

### Important nuance: revalidation via Stripe API (optional)

The engine supports a safety mode where webhook payloads are treated as “triggers” and the engine refetches the canonical object from Stripe before writing, controlled by:
- `StripeSyncConfig.revalidateObjectsViaStripeApi`
- helpers in `StripeSync` like `shouldRefetchEntity()` / `fetchOrUseWebhookData()`

This is not a separate trigger mechanism; it changes how webhook handlers source truth.

---

## Continuous worker path (cron + queue + processNext)

### The cron job that triggers the worker

`SupabaseSetupClient.setupPgCronJob()` installs:
- extensions: `pg_cron`, `pg_net`, `pgmq`
- a pgmq queue named `stripe_sync_work`
- a vault secret `stripe_sync_worker_secret`
- a cron job `stripe-sync-worker` that periodically calls:
  - `net.http_post('https://{projectRef}.supabase.co/functions/v1/stripe-worker', Authorization: Bearer <vault_secret>)`

All of that is assembled and run via Supabase Management API in:
- `packages/sync-engine/src/supabase/supabase.ts`

### `stripe-worker` Edge Function authentication

File: `packages/sync-engine/src/supabase/edge-functions/stripe-worker.ts`

The worker:
1. Requires `Authorization: Bearer <token>`
2. Fetches the expected secret from `vault.decrypted_secrets` where name is `stripe_sync_worker_secret`
3. Compares the bearer token to the stored secret

This design avoids relying on Supabase `service_role` JWTs; the database itself issues and validates the secret.

### Queue behavior (pgmq)

Worker constants:
- Queue: `stripe_sync_work`
- Visibility timeout: 60 seconds
- Batch size: 10 messages per invocation

The worker reads with:
- `pgmq.read(queue, vt_seconds, qty)`

Semantics:
- Messages are hidden from other readers for `vt` seconds (visibility timeout).
- If a worker crashes and doesn’t delete the message, it reappears after `vt` seconds.

### Enqueue strategy (when the queue is empty)

If `pgmq.read()` returns no messages, the worker enqueues *one message per object*.

To discover which objects exist, it calls:
- `StripeSync.joinOrCreateSyncRun('worker')`

That method returns an ordered list from:
- `StripeSync.getSupportedSyncObjects()`

and it also ensures corresponding `_sync_obj_runs` rows exist for observability.

Then the worker sends a batch of JSON messages:
- `{ "object": "<objectName>" }`

### Processing strategy (when queue has messages)

For each message in the batch, the worker does (in parallel via `Promise.all`):
1. Read `{ object }`
2. Call `stripeSync.processNext(object)`
3. If successful: `pgmq.delete(msg_id)`
4. If `hasMore`: `pgmq.send({object})` to requeue it
5. If error: it logs and leaves the message (it becomes visible again after vt)

### **Important nuance: `triggered_by` mismatch in runs**

This is subtle but critical if you are reading `stripe.sync_runs` for observability.

- When the queue is empty, the worker calls `joinOrCreateSyncRun('worker')` (triggered_by = `'worker'`) to enqueue objects.
- But when processing messages, it calls `processNext(object)` **without parameters**.
- `processNext()` defaults to `triggeredBy = 'processNext'` when it creates/joins a run.

So “enqueue run” and “processing run” can be **different runs**, because they use different `triggered_by` values.

If you expect “the run created during enqueue” to reflect processing progress, it may not.

If you want run tracking to be aligned, the worker would need to pass `{ triggeredBy: 'worker', runStartedAt: ... }` into `processNext()`. (This is not what the current worker does.)

---

## What `processNext()` actually does (paging + cursors + object run status)

`StripeSync.processNext(object, params?)` is the engine’s unit of work for the worker queue.

File: `packages/sync-engine/src/stripeSync.ts`

### Run and object-run bookkeeping

For each call:
1. Ensure account exists in DB for FK integrity (`getCurrentAccount()`)
2. Determine the run:
   - use `params.runStartedAt` if provided
   - else `joinOrCreateSyncRun(params.triggeredBy ?? 'processNext')`
3. Ensure an object-run row exists for this object in that run:
   - `postgresClient.createObjectRuns(...)`
4. If object is already terminal (`complete` / `error`), return `hasMore=false`
5. If object is `pending`, try to claim it via `tryStartObjectSync()` which enforces `max_concurrent`
   - If not claimed (at concurrency limit), return `hasMore=true` so the caller can retry later

### Two distinct cursors

There are **two** independent pieces of state:

1. **Incremental cursor** (`_sync_obj_runs.cursor`)
   - Used as `created.gte` for most Stripe list endpoints
   - It typically stores the maximum `created` timestamp seen so far (monotonically increasing)
   - `processNext()` intentionally does **not** use the current run’s cursor for created filtering; it prefers the previous completed run’s cursor unless an explicit created filter is passed.

2. **Page cursor** (`_sync_obj_runs.page_cursor`)
   - Used as `starting_after` for Stripe pagination within a single sweep/backfill
   - It stores the last object ID (or last event ID for `_event_catchup`)

### Completion

When Stripe returns `has_more=false`, `processNext()` completes the object-run:
- `postgresClient.completeObjectSync(...)`
- which may auto-close the parent run if all objects are done

On error, it marks the object-run as failed:
- `postgresClient.failObjectSync(...)`

### Special cases inside `fetchOnePage()`

Within `StripeSync.fetchOnePage()` there are non-obvious branches:

- `payment_method` uses a custom handler (`fetchOnePagePaymentMethods`) because it requires customer context.
- `tax_id` is immediately completed without syncing, due to permission limitations in some account contexts.
- `_event_catchup` has its own paging/processing strategy (next section).
- Sigma-backed objects go through `fetchOneSigmaPage()` (Sigma section).

---

## Event catch-up (`_event_catchup`)

`_event_catchup` exists to reduce the “missed webhook” surface area by periodically reconciling recent Stripe Events.

Key characteristics:
- Uses Stripe Events API (`stripe.events.list`)
- Works within Stripe’s retention window (clamps to 30 days)
- Deduplicates events to **latest per entity**
- For non-hard-deletes, it may skip refetch if local `_last_synced_at` is already newer than the event

Implementation:
- `StripeSync.fetchOnePageEventCatchup(...)` in `packages/sync-engine/src/stripeSync.ts`

Hard delete logic:
- Only certain event types are treated as “true hard deletes” in the DB (e.g. `product.deleted`, `price.deleted`, etc.)
- Other “*.deleted” events that represent a state change are handled by re-fetch + upsert.

This mechanism is why `_event_catchup` is placed late in object ordering: it’s meant to reconcile after primary entities are present.

---

## Observability: `_sync_runs`, `_sync_obj_runs`, and `stripe.sync_runs` view

### Tables

Core tables:
- `stripe._sync_runs` (one “run” per account + triggered_by, open while `closed_at IS NULL`)
- `stripe._sync_obj_runs` (one row per object per run, status pending/running/complete/error)

Key migrations:
- `0053_sync_observability.sql` introduces the system (initial shape)
- `0056_sync_run_closed_at.sql` switches to `closed_at` and derived status
- `0057_rename_sync_tables.sql` pluralizes table names and creates `stripe.sync_runs` view
- `0058_improve_sync_runs_status.sql` improves status derivation logic in the view
- `0061_add_page_cursor.sql` adds `page_cursor`
- `0062_sigma_query_runs.sql` updates run uniqueness to allow parallel runs by `triggered_by`

### One active run per account **per triggered_by**

Current constraint (after `0062`) allows multiple simultaneous runs as long as `triggered_by` differs (e.g. sigma vs worker):
- Exclusion constraint is on `(_account_id, coalesce(triggered_by,'default'))` where `closed_at IS NULL`.

### Auto-close behavior

When an object-run becomes terminal (`complete` or `error`), `completeObjectSync()` / `failObjectSync()` checks whether all object-runs are terminal and if so sets:
- `stripe._sync_runs.closed_at = now()`

### Stale detection and auto-cancellation

Before creating/returning a run in `PostgresClient.getOrCreateSyncRun()`, the engine calls:
- `cancelStaleRuns(accountId)`

This marks running object-runs as errored if they have not updated recently and may close runs that are fully terminal afterward.

This is meant to recover from crashed/abandoned runs.

---

## Managed webhooks (creation, uniqueness, secret storage)

`StripeSync.findOrCreateManagedWebhook(url)` is responsible for:
- Ensuring a Stripe webhook endpoint exists and is enabled
- Cleaning up old/orphaned managed webhooks
- Persisting the webhook (including the signing secret) in Postgres

Important correctness mechanisms:
- Uses a Postgres advisory lock to prevent concurrent creation races.
- Also enforces DB-level uniqueness of `(url, account_id)` via migration:
  - `0052_webhook_url_uniqueness.sql`

Webhook secret is later retrieved by `processWebhook()` to verify signatures without additional configuration.

---

## Sigma sync (separate worker loop)

Sigma is optional and controlled by `ENABLE_SIGMA` (installer sets it as a secret env var for Edge Functions).

There are two Sigma aspects:

1. **Schema + table reconciliation** (migrations)
   - `runMigrations({ enableSigma: true })` triggers dynamic creation/reconciliation of Sigma destination tables.
   - Implementation lives in `packages/sync-engine/src/database/migrate.ts` (Sigma schema reconciliation logic).

2. **Sigma worker execution**
   - Installer sets up:
     - `stripe.trigger_sigma_worker()` (a DB function that calls the Edge Function via `net.http_post`)
     - a pg_cron job `stripe-sigma-worker` scheduled at `0 */12 * * *`
     - a vault secret `stripe_sigma_worker_secret`
   - All in `SupabaseSetupClient.setupSigmaPgCronJob()` (`packages/sync-engine/src/supabase/supabase.ts`)

### Sigma Edge Function behavior: continuation via self-trigger

File: `packages/sync-engine/src/supabase/edge-functions/sigma-data-worker.ts`

High-level loop:
- Authenticate via `stripe_sigma_worker_secret`
- Ensure/claim a sigma run (`triggered_by='sigma-worker'`)
- Create object-runs for sigma objects
- Process a small batch (configured by `BATCH_SIZE`, currently 1)
- If work remains, call `SELECT stripe.trigger_sigma_worker()` to invoke itself again
- Stop self-triggering if run age exceeds `MAX_RUN_AGE_MS`

### Important note about current Sigma code

As of the current repo state, `sigma-data-worker.ts` imports `StripeSync` from `npm:stripe-experiment-sync` rather than the same package import used by the other edge functions.

If this is unintentional, it can cause real-world divergence (different engine version/behavior for sigma worker vs core).

---

## CLI triggers (local/dev)

The CLI has two main roles:

1. **One-off backfill**
   - `backfillCommand()` runs migrations, creates a `StripeSync`, and calls `processUntilDone()` / `processUntilDoneParallel()`.

2. **Live sync in local mode**
   - `syncCommand()` supports:
     - **WebSocket mode** (default if ngrok token is absent): receives Stripe events via a Stripe websocket client and calls `stripeSync.processEvent(payload)`
     - **Webhook mode** (ngrok + express): sets up a public webhook URL, creates a managed webhook endpoint, receives webhook requests locally, and calls `stripeSync.processWebhook(rawBody, sig)`
   - After setup, it typically runs:
     - a “historical backfill sweep” via `processUntilDoneParallel()`
     - then an “incremental backfill” via `processUntilDone()`
     - then streams live changes

This CLI path is separate from Supabase Edge Functions; it’s primarily for development/testing or non-Supabase deployments.

---

## Failure modes and “why it keeps working”

### Worker crashes / duplicate processing

If a worker invocation crashes mid-batch:
- Messages not deleted reappear after the pgmq visibility timeout (60s).
- `processNext()` is designed to be safe to call repeatedly because progress is persisted in `_sync_obj_runs` (cursor + page cursor + status).

### Stripe returns inconsistent pagination

The engine defensively fails an object-run if Stripe ever returns `has_more=true` with an empty page, to avoid infinite loops.

### Stale run recovery

If an object-run is marked running but stops updating for a while, `cancelStaleRuns()` may mark it errored and close the run so new work can proceed.

---

## Where to look when debugging a specific symptom

- **Worker not running at all**
  - Check `cron.job` for `stripe-sync-worker`
  - Check `vault.secrets` for `stripe_sync_worker_secret`
  - Check Edge Function logs for `stripe-worker`
  - Installer logic: `packages/sync-engine/src/supabase/supabase.ts` (`setupPgCronJob`)

- **Queue is always empty / never enqueues**
  - Edge worker enqueue branch: `packages/sync-engine/src/supabase/edge-functions/stripe-worker.ts` (messages.length === 0)
  - Check pgmq queue existence: created in `setupPgCronJob()`

- **Runs show “pending” but nothing progresses**
  - Check the `triggered_by` mismatch described above (enqueue uses `'worker'`; processing uses `'processNext'` by default).
  - Inspect `stripe.sync_runs` view grouped by `triggered_by`.

- **Missing webhook updates**
  - Ensure managed webhook exists/enabled in Stripe (managed webhook logic in `StripeSync.findOrCreateManagedWebhook`)
  - Confirm `stripe-webhook` can verify signatures (secret is stored in `stripe._managed_webhooks`)
  - `_event_catchup` is designed to backstop missed webhooks; verify it’s running and cursor advances.

- **Sigma not syncing**
  - Confirm `ENABLE_SIGMA` was set during install
  - Confirm cron job `stripe-sigma-worker` exists and vault secret `stripe_sigma_worker_secret` exists
  - Confirm `sigma-data-worker` import/package is correct for your deployment expectations

