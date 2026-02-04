-- Balance Transactions table - stores full Stripe balance transaction data
-- Balance transactions represent funds moving through your Stripe account

CREATE TABLE IF NOT EXISTS "stripe"."balance_transactions" (
  "_raw_data" jsonb NOT NULL,
  "_last_synced_at" timestamptz,
  "_updated_at" timestamptz DEFAULT now(),
  "_account_id" text NOT NULL,

  -- Generated columns from _raw_data (id must be generated for upsert to work)
  "id" TEXT GENERATED ALWAYS AS ((_raw_data->>'id')::TEXT) STORED PRIMARY KEY,
  "object" text GENERATED ALWAYS AS ((_raw_data->>'object')::text) STORED,
  "amount" bigint GENERATED ALWAYS AS ((_raw_data->>'amount')::bigint) STORED,
  "available_on" integer GENERATED ALWAYS AS ((_raw_data->>'available_on')::integer) STORED,
  "created" integer GENERATED ALWAYS AS ((_raw_data->>'created')::integer) STORED,
  "currency" text GENERATED ALWAYS AS ((_raw_data->>'currency')::text) STORED,
  "description" text GENERATED ALWAYS AS ((_raw_data->>'description')::text) STORED,
  "exchange_rate" numeric GENERATED ALWAYS AS ((_raw_data->>'exchange_rate')::numeric) STORED,
  "fee" bigint GENERATED ALWAYS AS ((_raw_data->>'fee')::bigint) STORED,
  "fee_details" jsonb GENERATED ALWAYS AS (_raw_data->'fee_details') STORED,
  "net" bigint GENERATED ALWAYS AS ((_raw_data->>'net')::bigint) STORED,
  "reporting_category" text GENERATED ALWAYS AS ((_raw_data->>'reporting_category')::text) STORED,
  "source" text GENERATED ALWAYS AS ((_raw_data->>'source')::text) STORED,
  "status" text GENERATED ALWAYS AS ((_raw_data->>'status')::text) STORED,
  "type" text GENERATED ALWAYS AS ((_raw_data->>'type')::text) STORED
);

-- Foreign key to accounts
ALTER TABLE "stripe"."balance_transactions"
  DROP CONSTRAINT IF EXISTS fk_balance_transactions_account;
ALTER TABLE "stripe"."balance_transactions"
  ADD CONSTRAINT fk_balance_transactions_account
  FOREIGN KEY ("_account_id") REFERENCES "stripe"."accounts" (id);

-- Update trigger
DROP TRIGGER IF EXISTS handle_updated_at ON "stripe"."balance_transactions";
CREATE TRIGGER handle_updated_at
  BEFORE UPDATE ON "stripe"."balance_transactions"
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Indexes
CREATE INDEX stripe_balance_transactions_created_idx ON "stripe"."balance_transactions" USING btree (created);
