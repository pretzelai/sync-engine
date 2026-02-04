-- Add indexes on _account_id for all entity tables
-- This dramatically improves query performance for multi-tenant queries
-- like COUNT(*) and MAX(_last_synced_at) filtered by account
--
-- CRITICAL: Foreign keys do NOT automatically create indexes in PostgreSQL.
-- Without these indexes, queries filtering by _account_id do full table scans.
--
-- NOTE: Using regular CREATE INDEX (not CONCURRENTLY) because:
-- 1. pg-node-migrations runs migrations in transactions
-- 2. CREATE INDEX CONCURRENTLY cannot run inside a transaction
-- 3. For new deployments, tables are empty so this is instant
-- 4. For existing deployments, brief lock is acceptable during maintenance window

-- Products (catalog)
CREATE INDEX IF NOT EXISTS idx_products_account_id
  ON stripe.products (_account_id);
CREATE INDEX IF NOT EXISTS idx_products_account_last_synced
  ON stripe.products (_account_id, _last_synced_at DESC);

-- Prices (catalog)
CREATE INDEX IF NOT EXISTS idx_prices_account_id
  ON stripe.prices (_account_id);
CREATE INDEX IF NOT EXISTS idx_prices_account_last_synced
  ON stripe.prices (_account_id, _last_synced_at DESC);

-- Plans (catalog)
CREATE INDEX IF NOT EXISTS idx_plans_account_id
  ON stripe.plans (_account_id);
CREATE INDEX IF NOT EXISTS idx_plans_account_last_synced
  ON stripe.plans (_account_id, _last_synced_at DESC);

-- Customers
CREATE INDEX IF NOT EXISTS idx_customers_account_id
  ON stripe.customers (_account_id);
CREATE INDEX IF NOT EXISTS idx_customers_account_last_synced
  ON stripe.customers (_account_id, _last_synced_at DESC);

-- Subscriptions
CREATE INDEX IF NOT EXISTS idx_subscriptions_account_id
  ON stripe.subscriptions (_account_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_account_last_synced
  ON stripe.subscriptions (_account_id, _last_synced_at DESC);

-- Subscription Schedules
CREATE INDEX IF NOT EXISTS idx_subscription_schedules_account_id
  ON stripe.subscription_schedules (_account_id);
CREATE INDEX IF NOT EXISTS idx_subscription_schedules_account_last_synced
  ON stripe.subscription_schedules (_account_id, _last_synced_at DESC);

-- Invoices
CREATE INDEX IF NOT EXISTS idx_invoices_account_id
  ON stripe.invoices (_account_id);
CREATE INDEX IF NOT EXISTS idx_invoices_account_last_synced
  ON stripe.invoices (_account_id, _last_synced_at DESC);

-- Credit Notes
CREATE INDEX IF NOT EXISTS idx_credit_notes_account_id
  ON stripe.credit_notes (_account_id);
CREATE INDEX IF NOT EXISTS idx_credit_notes_account_last_synced
  ON stripe.credit_notes (_account_id, _last_synced_at DESC);

-- Balance Transactions
CREATE INDEX IF NOT EXISTS idx_balance_transactions_account_id
  ON stripe.balance_transactions (_account_id);
CREATE INDEX IF NOT EXISTS idx_balance_transactions_account_last_synced
  ON stripe.balance_transactions (_account_id, _last_synced_at DESC);

-- Charges
CREATE INDEX IF NOT EXISTS idx_charges_account_id
  ON stripe.charges (_account_id);
CREATE INDEX IF NOT EXISTS idx_charges_account_last_synced
  ON stripe.charges (_account_id, _last_synced_at DESC);

-- Payment Intents
CREATE INDEX IF NOT EXISTS idx_payment_intents_account_id
  ON stripe.payment_intents (_account_id);
CREATE INDEX IF NOT EXISTS idx_payment_intents_account_last_synced
  ON stripe.payment_intents (_account_id, _last_synced_at DESC);

-- Payment Methods
CREATE INDEX IF NOT EXISTS idx_payment_methods_account_id
  ON stripe.payment_methods (_account_id);
CREATE INDEX IF NOT EXISTS idx_payment_methods_account_last_synced
  ON stripe.payment_methods (_account_id, _last_synced_at DESC);

-- Setup Intents
CREATE INDEX IF NOT EXISTS idx_setup_intents_account_id
  ON stripe.setup_intents (_account_id);
CREATE INDEX IF NOT EXISTS idx_setup_intents_account_last_synced
  ON stripe.setup_intents (_account_id, _last_synced_at DESC);

-- Refunds
CREATE INDEX IF NOT EXISTS idx_refunds_account_id
  ON stripe.refunds (_account_id);
CREATE INDEX IF NOT EXISTS idx_refunds_account_last_synced
  ON stripe.refunds (_account_id, _last_synced_at DESC);

-- Checkout Sessions
CREATE INDEX IF NOT EXISTS idx_checkout_sessions_account_id
  ON stripe.checkout_sessions (_account_id);
CREATE INDEX IF NOT EXISTS idx_checkout_sessions_account_last_synced
  ON stripe.checkout_sessions (_account_id, _last_synced_at DESC);

-- Disputes
CREATE INDEX IF NOT EXISTS idx_disputes_account_id
  ON stripe.disputes (_account_id);
CREATE INDEX IF NOT EXISTS idx_disputes_account_last_synced
  ON stripe.disputes (_account_id, _last_synced_at DESC);

-- Early Fraud Warnings
CREATE INDEX IF NOT EXISTS idx_early_fraud_warnings_account_id
  ON stripe.early_fraud_warnings (_account_id);
CREATE INDEX IF NOT EXISTS idx_early_fraud_warnings_account_last_synced
  ON stripe.early_fraud_warnings (_account_id, _last_synced_at DESC);

-- Tax IDs
CREATE INDEX IF NOT EXISTS idx_tax_ids_account_id
  ON stripe.tax_ids (_account_id);
CREATE INDEX IF NOT EXISTS idx_tax_ids_account_last_synced
  ON stripe.tax_ids (_account_id, _last_synced_at DESC);
