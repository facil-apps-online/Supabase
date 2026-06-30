-- Migration to unify payments and payment_intents into a single transactions table
-- Timestamp: 20260119000001

-- 1. Create the new transactions table
CREATE TABLE IF NOT EXISTS "public"."transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'PENDING'::"text" NOT NULL,
    "amount_in_cents" bigint NOT NULL,
    "currency" character varying(3) NOT NULL,
    "reference" "text" NOT NULL,
    "provider" "text", -- e.g., 'wompi-co'
    "provider_transaction_id" "text",
    "payment_method_type" "text",
    "environment" "text" DEFAULT 'production'::"text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "line_items" "jsonb" DEFAULT '[]'::"jsonb", -- Detailed breakdown of what is being paid
    "actions_snapshot" "jsonb" DEFAULT '[]'::"jsonb", -- Snapshot of actions to execute on success
    "full_response" "jsonb", -- Stores the raw response from the provider
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "processed_at" timestamp with time zone,
    CONSTRAINT "transactions_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "transactions_reference_key" UNIQUE ("reference"),
    CONSTRAINT "transactions_environment_check" CHECK (("environment" = ANY (ARRAY['test'::"text", 'production'::"text"]))),
    CONSTRAINT "transactions_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE SET NULL,
    CONSTRAINT "transactions_platform_id_fkey" FOREIGN KEY ("platform_id") REFERENCES "public"."platforms"("id") ON DELETE SET NULL
);

-- 2. Migrate existing data from 'payments' (completed/historical transactions)
-- We assume 'payments' data is more valuable as history.
INSERT INTO "public"."transactions" (
    "id", "tenant_id", "platform_id", "status", "amount_in_cents", "currency", 
    "reference", "provider", "provider_transaction_id", "environment", 
    "full_response", "created_at", "updated_at", "processed_at"
)
SELECT 
    p."id", p."tenant_id", p."platform_id", p."status", p."amount_in_cents", p."currency",
    p."reference", p."provider", p."provider_payment_id", p."environment",
    p."full_response", p."created_at", p."updated_at", p."payment_date"
FROM "public"."payments" p;

-- 3. Migrate pending intents from 'payment_intents' that don't have a corresponding payment yet
-- This assumes intents are 'PENDING' transactions.
INSERT INTO "public"."transactions" (
    "id", "tenant_id", "platform_id", "status", "amount_in_cents", "currency", 
    "reference", "environment", "metadata", "actions_snapshot", 
    "created_at", "updated_at"
)
SELECT 
    pi."id", pi."tenant_id", pi."platform_id", pi."status", pi."amount_in_cents", pi."currency",
    pi."reference", pi."environment", pi."metadata", pi."actions_on_success",
    pi."created_at", pi."updated_at"
FROM "public"."payment_intents" pi
WHERE NOT EXISTS (SELECT 1 FROM "public"."payments" p WHERE p.reference = pi.reference)
ON CONFLICT ("reference") DO NOTHING; -- Avoid duplicates if reference was reused

-- 4. Drop old tables
DROP TABLE IF EXISTS "public"."payments" CASCADE;
DROP TABLE IF EXISTS "public"."payment_intents" CASCADE;

-- 5. Create indexes for performance
CREATE INDEX "idx_transactions_tenant_id" ON "public"."transactions" ("tenant_id");
CREATE INDEX "idx_transactions_platform_id" ON "public"."transactions" ("platform_id");
CREATE INDEX "idx_transactions_reference" ON "public"."transactions" ("reference");
CREATE INDEX "idx_transactions_status" ON "public"."transactions" ("status");
CREATE INDEX "idx_transactions_created_at" ON "public"."transactions" ("created_at" DESC);

-- 6. Trigger for updating updated_at
CREATE OR REPLACE TRIGGER "update_transactions_moddatetime"
BEFORE UPDATE ON "public"."transactions"
FOR EACH ROW
EXECUTE FUNCTION "moddatetime"('updated_at');
