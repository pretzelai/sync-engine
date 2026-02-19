/**
 * Stripe Sync Worker
 *
 * Triggered by pg_cron at a configurable interval (default: 60 seconds). Uses pgmq for durable work queue.
 *
 * Flow:
 * 1. Read batch of messages from pgmq (qty=10, vt=60s)
 * 2. If queue empty: enqueue all objects (continuous sync)
 * 3. Process messages in parallel (Promise.all):
 *    - processNext(object)
 *    - Delete message on success
 *    - Re-enqueue if hasMore
 * 4. Return results summary
 *
 * Concurrency:
 * - Multiple workers can run concurrently via overlapping pg_cron triggers.
 * - Each worker processes its batch of messages in parallel (Promise.all).
 * - pgmq visibility timeout prevents duplicate message reads across workers.
 * - processNext() is idempotent (uses internal cursor tracking), so duplicate
 *   processing on timeout/crash is safe.
 */

import { StripeSync, VERSION } from 'npm:@paymentsdb/sync-engine'
import postgres from 'npm:postgres'

const QUEUE_NAME = 'stripe_sync_work'
const VISIBILITY_TIMEOUT = 60 // seconds
const BATCH_SIZE = 10

Deno.serve(async (req) => {
  console.log(`[stripe-worker] Starting invocation, sync-engine version: ${VERSION}`)
  const authHeader = req.headers.get('Authorization')
  if (!authHeader?.startsWith('Bearer ')) {
    return new Response('Unauthorized', { status: 401 })
  }

  const token = authHeader.substring(7) // Remove 'Bearer '

  const rawDbUrl = Deno.env.get('SUPABASE_DB_URL')
  if (!rawDbUrl) {
    return new Response(JSON.stringify({ error: 'SUPABASE_DB_URL not set' }), { status: 500 })
  }
  const dbUrl = rawDbUrl.replace(/[?&]sslmode=[^&]*/g, '').replace(/[?&]$/, '')

  let sql
  let stripeSync

  try {
    sql = postgres(dbUrl, { max: 1, prepare: false })
  } catch (error) {
    return new Response(
      JSON.stringify({
        error: 'Failed to create postgres connection',
        details: error.message,
        stack: error.stack,
      }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }

  try {
    // Validate that the token matches the unique worker secret stored in vault
    const vaultResult = await sql`
      SELECT decrypted_secret
      FROM vault.decrypted_secrets
      WHERE name = 'stripe_sync_worker_secret'
    `

    if (vaultResult.length === 0) {
      await sql.end()
      return new Response('Worker secret not configured in vault', { status: 500 })
    }

    const storedSecret = vaultResult[0].decrypted_secret
    if (token !== storedSecret) {
      await sql.end()
      return new Response('Forbidden: Invalid worker secret', { status: 403 })
    }

    stripeSync = new StripeSync({
      poolConfig: { connectionString: dbUrl, max: 1 },
      stripeSecretKey: Deno.env.get('STRIPE_SECRET_KEY')!,
      enableSigma: (Deno.env.get('ENABLE_SIGMA') ?? 'false') === 'true',
      appName: Deno.env.get('STRIPE_APP_NAME') || 'PaymentsDB',
    })
  } catch (error) {
    await sql.end()
    return new Response(
      JSON.stringify({
        error: 'Failed to create StripeSync',
        details: error.message,
        stack: error.stack,
      }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }

  try {
    // Read batch of messages from queue
    const messages = await sql`
      SELECT * FROM pgmq.read(${QUEUE_NAME}::text, ${VISIBILITY_TIMEOUT}::int, ${BATCH_SIZE}::int)
    `

    // If no visible messages, check whether messages are still in-flight
    // (invisible due to VT) before treating the queue as truly empty.
    if (messages.length === 0) {
      const [{ queue_length }] =
        await sql`SELECT queue_length FROM pgmq.metrics(${QUEUE_NAME}::text)`
      if (queue_length > 0) {
        return new Response(JSON.stringify({ version: VERSION, skipped: true, reason: 'messages still in flight' }), {
          status: 200,
          headers: { 'Content-Type': 'application/json' },
        })
      }

      // Queue is genuinely empty. If cron is in fast mode (sub-minute) and
      // the initial sync has completed (at least one closed run), downgrade
      // to steady-state interval (once per minute).
      const [{ schedule }] =
        await sql`SELECT schedule FROM cron.job WHERE jobname = 'stripe-sync-worker'`
      if (schedule !== '*/1 * * * *') {
        const [{ n }] =
          await sql`SELECT count(*)::int as n FROM stripe._sync_runs WHERE closed_at IS NOT NULL`
        if (n > 0) {
          await sql`
            SELECT cron.alter_job(
              (SELECT jobid FROM cron.job WHERE jobname = 'stripe-sync-worker'),
              schedule := '*/1 * * * *'
            )
          `
        }
      }

      // Enqueue all objects for the next sync cycle
      const { objects } = await stripeSync.joinOrCreateSyncRun('worker')
      const msgs = objects.map((object) => JSON.stringify({ object }))

      await sql`
        SELECT pgmq.send_batch(
          ${QUEUE_NAME}::text,
          ${sql.array(msgs)}::jsonb[]
        )
      `

      return new Response(JSON.stringify({ version: VERSION, enqueued: objects.length, objects }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    }

    // Process messages in parallel
    const results = await Promise.all(
      messages.map(async (msg) => {
        const { object } = msg.message as { object: string }

        try {
          const result = await stripeSync.processNext(object)

          // Delete message on success (cast to bigint to disambiguate overloaded function)
          await sql`SELECT pgmq.delete(${QUEUE_NAME}::text, ${msg.msg_id}::bigint)`

          // Re-enqueue if more pages
          if (result.hasMore) {
            await sql`SELECT pgmq.send(${QUEUE_NAME}::text, ${sql.json({ object })}::jsonb)`
          }

          return { object, ...result }
        } catch (error) {
          // Log error but continue to next message
          // Message will become visible again after visibility timeout
          console.error(`Error processing ${object}:`, error)
          return {
            object,
            processed: 0,
            hasMore: false,
            error: error.message,
            stack: error.stack,
          }
        }
      })
    )

    return new Response(JSON.stringify({ version: VERSION, results }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    })
  } catch (error) {
    console.error('Worker error:', error)
    return new Response(JSON.stringify({ version: VERSION, error: error.message, stack: error.stack }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  } finally {
    if (sql) await sql.end()
    if (stripeSync) await stripeSync.postgresClient.pool.end()
  }
})
