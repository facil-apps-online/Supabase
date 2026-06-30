-- Definitive Core Schema Migration - Generated from master schema.sql
-- This script DROPS all core objects before recreating them to ensure a clean state.

-- ========= Drop existing objects in reverse order =========
DROP TABLE IF EXISTS "public"."vendor_tenants" CASCADE;
DROP TABLE IF EXISTS "public"."vendor_platform_commissions" CASCADE;
DROP TABLE IF EXISTS "public"."translations" CASCADE;
DROP TABLE IF EXISTS "public"."tenant_template_settings" CASCADE;
DROP TABLE IF EXISTS "public"."tenant_subscriptions" CASCADE;
DROP TABLE IF EXISTS "public"."tenant_settings" CASCADE;
DROP TABLE IF EXISTS "public"."tenant_integrations" CASCADE;
DROP TABLE IF EXISTS "public"."system_alerts" CASCADE;
DROP TABLE IF EXISTS "public"."subscription_items" CASCADE;
DROP TABLE IF EXISTS "public"."subscription_assets" CASCADE;
DROP TABLE IF EXISTS "public"."roles" CASCADE;
DROP TABLE IF EXISTS "public"."tariff_asset_prices" CASCADE;
DROP TABLE IF EXISTS "public"."price_tariffs" CASCADE;
DROP TABLE IF EXISTS "public"."platform_countries" CASCADE;
DROP TABLE IF EXISTS "public"."platform_assignments" CASCADE;
DROP TABLE IF EXISTS "public"."plan_asset_bonuses" CASCADE;
DROP TABLE IF EXISTS "public"."plan_asset_limits" CASCADE;
DROP TABLE IF EXISTS "public"."plan_country_configurations" CASCADE;
DROP TABLE IF EXISTS "public"."plan_assets" CASCADE;
DROP TABLE IF EXISTS "public"."phone_prefixes" CASCADE;
DROP TABLE IF EXISTS "public"."payments" CASCADE;
DROP TABLE IF EXISTS "public"."payment_intents" CASCADE;
DROP TABLE IF EXISTS "public"."monthly_charges" CASCADE;
DROP TABLE IF EXISTS "public"."investor_platform_stakes" CASCADE;
DROP TABLE IF EXISTS "public"."investor_platform_shares" CASCADE;
DROP TABLE IF EXISTS "public"."integrations_config" CASCADE;
DROP TABLE IF EXISTS "public"."integration_record" CASCADE;
DROP TABLE IF EXISTS "public"."integration_providers" CASCADE;
DROP TABLE IF EXISTS "public"."integration_http_methods" CASCADE;
DROP TABLE IF EXISTS "public"."integration_categories" CASCADE;
DROP TABLE IF EXISTS "public"."integration_body_formats" CASCADE;
DROP TABLE IF EXISTS "public"."integration_auth_methods" CASCADE;
DROP TABLE IF EXISTS "public"."global_settings" CASCADE;
DROP TABLE IF EXISTS "public"."generic_taxes" CASCADE;
DROP TABLE IF EXISTS "public"."exchange_rates" CASCADE;
DROP TABLE IF EXISTS "public"."error_logs" CASCADE;
DROP TABLE IF EXISTS "public"."email_templates" CASCADE;
DROP TABLE IF EXISTS "public"."email_queue" CASCADE;
DROP TABLE IF EXISTS "public"."email_logs" CASCADE;
DROP TABLE IF EXISTS "public"."country_timezones" CASCADE;
DROP TABLE IF EXISTS "public"."asset_usage_tracking" CASCADE;
DROP TABLE IF EXISTS "public"."asset_purposes" CASCADE;
-- Base tables that others depend on
DROP TABLE IF EXISTS "public"."tenants" CASCADE;
DROP TABLE IF EXISTS "public"."subscription_plans" CASCADE;
DROP TABLE IF EXISTS "public"."platforms" CASCADE;
DROP TABLE IF EXISTS "public"."countries" CASCADE;
DROP TABLE IF EXISTS "public"."currencies" CASCADE;
DROP TABLE IF EXISTS "public"."languages" CASCADE;
DROP TABLE IF EXISTS "public"."timezones" CASCADE;

-- Drop types
DROP TYPE IF EXISTS "public"."subscription_asset_status";
DROP TYPE IF EXISTS "public"."subscription_asset_type";
DROP TYPE IF EXISTS "public"."tenant_subscription_status";
DROP TYPE IF EXISTS "public"."email_queue_status";


-- ========= Extensions and Initial Setup =========
SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";
CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";
CREATE EXTENSION IF NOT EXISTS "btree_gist" WITH SCHEMA "public";
CREATE EXTENSION IF NOT EXISTS "http" WITH SCHEMA "public";
CREATE EXTENSION IF NOT EXISTS "moddatetime" WITH SCHEMA "public";
CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";
CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "public";
CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "public";
CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";

-- ========= Types =========
CREATE TYPE "public"."subscription_asset_status" AS ENUM ('active', 'cancelled');
CREATE TYPE "public"."subscription_asset_type" AS ENUM ('branch', 'user');
CREATE TYPE "public"."tenant_subscription_status" AS ENUM ('trial', 'active', 'inactive', 'cancelled', 'grace_period');
CREATE TYPE "public"."email_queue_status" AS ENUM ('PENDING', 'PROCESSING', 'SENT', 'FAILED');

-- ========= Table Definitions =========

CREATE TABLE IF NOT EXISTS "public"."asset_purposes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "purpose_key" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."asset_usage_tracking" (
    "id" bigint NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "asset_id" "uuid" NOT NULL,
    "usage_period_start" "date" NOT NULL,
    "usage_period_end" "date" NOT NULL,
    "quantity_used" bigint DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);
CREATE SEQUENCE IF NOT EXISTS "public"."asset_usage_tracking_id_seq" START WITH 1 INCREMENT BY 1 NO MINVALUE NO MAXVALUE CACHE 1;
ALTER SEQUENCE "public"."asset_usage_tracking_id_seq" OWNED BY "public"."asset_usage_tracking"."id";
ALTER TABLE ONLY "public"."asset_usage_tracking" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."asset_usage_tracking_id_seq"'::"regclass");

CREATE TABLE IF NOT EXISTS "public"."countries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "iso_code" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "default_language_iso_code" "text",
    "uses_auto_pricing" boolean DEFAULT false NOT NULL,
    "default_currency_id" "uuid",
    "default_localization_id" "uuid",
    "phone_prefix_id" "uuid",
    "default_latitude" double precision,
    "default_longitude" double precision,
    "timezones" "jsonb",
    "field_placeholders" "jsonb"
);

CREATE TABLE IF NOT EXISTS "public"."country_timezones" (
    "country_id" "uuid" NOT NULL,
    "timezone_id" "uuid" NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."currencies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "code" "text" NOT NULL,
    "symbol" "text" NOT NULL,
    "format" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "symbol_position" character varying(10) DEFAULT 'before'::character varying NOT NULL,
    "decimal_separator" character(1) DEFAULT '.'::"bpchar" NOT NULL,
    "thousands_separator" character(1) DEFAULT ','::"bpchar" NOT NULL,
    "decimal_places" integer DEFAULT 2 NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."email_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "recipient_email" "text" NOT NULL,
    "template_id" "uuid",
    "status" "text" NOT NULL,
    "error_message" "text",
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."email_queue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recipient_user_id" "uuid" NOT NULL,
    "template_type" "text" NOT NULL,
    "template_data" "jsonb" NOT NULL,
    "status" "public"."email_queue_status" DEFAULT 'PENDING'::"public"."email_queue_status" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "last_attempt_at" timestamp with time zone,
    "error_message" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."email_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "template_type" "text" NOT NULL,
    "name" "text" NOT NULL,
    "subject" "text" NOT NULL,
    "body_html" "text" NOT NULL,
    "language_id" "uuid" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "propagate_to_new_tenants" boolean DEFAULT false NOT NULL,
    "platform_id" "uuid",
    "is_customizable" boolean DEFAULT true NOT NULL,
    "is_disableable" boolean DEFAULT true NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."error_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid",
    "user_id" "uuid",
    "error_message" "text" NOT NULL,
    "stack_trace" "text",
    "error_code" "text",
    "severity" "text" DEFAULT 'error'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "error_logs_severity_check" CHECK (("severity" = ANY (ARRAY['info'::"text", 'warning'::"text", 'error'::"text", 'critical'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."exchange_rates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "base_currency_code" "text" NOT NULL,
    "target_currency_code" "text" NOT NULL,
    "rate" numeric(12,6) NOT NULL,
    "last_updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."generic_taxes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "rate" numeric(5,2) NOT NULL,
    "country_id" "uuid" NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."global_settings" (
    "id" integer NOT NULL,
    "base_currency_id" "uuid",
    "default_tax_rate" numeric(5,2) DEFAULT 0.00,
    "default_tax_name" "text" DEFAULT 'IVA'::"text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "company_name" "text",
    "contact_email" "text",
    "address" "text",
    "trial_duration_days" integer DEFAULT 14 NOT NULL,
    "trial_grace_period_days" integer DEFAULT 3 NOT NULL,
    CONSTRAINT "global_settings_id_check" CHECK (("id" = 1))
);

CREATE TABLE IF NOT EXISTS "public"."integration_auth_methods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "method" "text" NOT NULL,
    "description" "text",
    "config_schema" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."integration_body_formats" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "format" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."integration_categories" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."integration_http_methods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "method" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."integration_providers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "logo_url" "text",
    "country_id" "uuid" NOT NULL,
    "category_id" "uuid" NOT NULL,
    "status" "text" NOT NULL,
    "endpoints" "jsonb" NOT NULL,
    "config_schema" "jsonb" NOT NULL,
    "api_schema" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "slug" "text" NOT NULL,
    "http_method_id" "uuid",
    "body_format_id" "uuid",
    "auth_method_id" "uuid",
    "http_headers" "jsonb",
    "authentication_config" "jsonb",
    "body_template" "text",
    "response_mapping" "jsonb"
);

CREATE TABLE IF NOT EXISTS "public"."integration_record" (
    "id" "uuid",
    "tenant_id" "uuid",
    "provider" "text",
    "access_token" "text",
    "encrypted_refresh_token" "bytea",
    "encryption_nonce" "bytea",
    "account_email" "text",
    "created_at" timestamp with time zone,
    "updated_at" timestamp with time zone
);

CREATE TABLE IF NOT EXISTS "public"."integrations_config" (
    "key" "text" NOT NULL,
    "value" "text" NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."investor_platform_shares" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "investment_share" numeric(5,4) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "investor_platform_shares_investment_share_check" CHECK ((("investment_share" > (0)::numeric) AND ("investment_share" <= (1)::numeric)))
);

CREATE TABLE IF NOT EXISTS "public"."investor_platform_stakes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "investor_user_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "stake_percentage" numeric(5,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "investor_platform_stakes_stake_percentage_check" CHECK ((("stake_percentage" > (0)::numeric) AND ("stake_percentage" <= (100)::numeric)))
);

CREATE TABLE IF NOT EXISTS "public"."languages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "iso_code" character varying(10) NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."monthly_charges" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "billing_period_start" "date" NOT NULL,
    "billing_period_end" "date" NOT NULL,
    "base_plan_charge" numeric(10,2) DEFAULT 0.00 NOT NULL,
    "total_overage_charge" numeric(10,2) DEFAULT 0.00 NOT NULL,
    "total_charge" numeric(10,2) DEFAULT 0.00 NOT NULL,
    "currency_code" "text" NOT NULL,
    "currency_symbol" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."payment_intents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'PENDING'::"text" NOT NULL,
    "amount_in_cents" bigint NOT NULL,
    "currency" character varying(3) NOT NULL,
    "reference" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "environment" "text" NOT NULL,
    "actions_on_success" "jsonb",
    CONSTRAINT "payment_intents_environment_check" CHECK (("environment" = ANY (ARRAY['test'::"text", 'production'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "provider" "text" NOT NULL,
    "provider_payment_id" "text" NOT NULL,
    "amount_in_cents" bigint NOT NULL,
    "currency" character varying(3) NOT NULL,
    "status" "text" NOT NULL,
    "reference" "text" NOT NULL,
    "environment" "text" NOT NULL,
    "full_response" "jsonb",
    "payment_date" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."phone_prefixes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "country_name" "text" NOT NULL,
    "iso_code" character varying(2) NOT NULL,
    "prefix" character varying(10) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."plan_asset_bonuses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_asset_limit_id" "uuid" NOT NULL,
    "bonus_asset_id" "uuid" NOT NULL,
    "quantity" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "quantity_must_be_positive" CHECK (("quantity" > 0))
);

CREATE TABLE IF NOT EXISTS "public"."plan_asset_limits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plan_country_config_id" "uuid" NOT NULL,
    "asset_id" "uuid" NOT NULL,
    "value" "text" NOT NULL,
    "extra_unit_price" numeric(10,4) DEFAULT 0 NOT NULL,
    "overage_unit_price" numeric(10,4) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."plan_assets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "asset_key" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "data_type" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "asset_purpose_id" "uuid" NOT NULL,
    CONSTRAINT "plan_assets_data_type_check" CHECK (("data_type" = ANY (ARRAY['boolean'::"text", 'numeric'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."plan_country_configurations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plan_id" "uuid" NOT NULL,
    "country_id" "uuid" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "features" "text"[] DEFAULT ARRAY[]::"text"[],
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."platform_assignments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "role_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."platform_countries" (
    "platform_id" "uuid" NOT NULL,
    "country_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."platforms" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "base_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "default_currency_id" "uuid",
    "default_language_id" "uuid",
    "default_timezone" "text"
);

CREATE TABLE IF NOT EXISTS "public"."price_tariffs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "subscription_plan_id" "uuid" NOT NULL,
    "effective_date" timestamp with time zone NOT NULL,
    "base_price" numeric(10,2) DEFAULT 0 NOT NULL,
    "currency_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "promotional_price" numeric(10,2)
);

CREATE TABLE IF NOT EXISTS "public"."roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."subscription_assets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_subscription_id" "uuid" NOT NULL,
    "asset_type" "public"."subscription_asset_type" NOT NULL,
    "asset_reference_id" "uuid" NOT NULL,
    "status" "public"."subscription_asset_status" DEFAULT 'active'::"public"."subscription_asset_status" NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cancelled_at" timestamp with time zone,
    "price_at_addition" numeric(10,2) NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."subscription_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "subscription_id" "uuid" NOT NULL,
    "item_type" "text" NOT NULL,
    "item_id" "uuid",
    "quantity" integer DEFAULT 1 NOT NULL,
    "unit_price_at_addition" numeric(10,2) NOT NULL,
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "check_item_type" CHECK (("item_type" = ANY (ARRAY['extra_branch'::"text", 'extra_user'::"text", 'advanced_reports'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."subscription_plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "duration_days" integer DEFAULT 30 NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "billing_frequency_months" integer DEFAULT 1 NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "grace_period_days" integer DEFAULT 7 NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "is_default_trial" boolean DEFAULT false NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."system_alerts" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "type" "text" NOT NULL,
    "message" "text" NOT NULL,
    "details" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_resolved" boolean DEFAULT false,
    "resolved_at" timestamp with time zone,
    "resolved_by" "uuid",
    "platform_id" "uuid" NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."tariff_asset_prices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tariff_id" "uuid" NOT NULL,
    "asset_id" "uuid" NOT NULL,
    "extra_unit_price" numeric(10,2) DEFAULT 0 NOT NULL,
    "overage_unit_price" numeric(10,4) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."tenant_integrations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "provider" "text" NOT NULL,
    "access_token" "text",
    "account_email" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone,
    "encrypted_credentials" "text",
    "nonce" "text",
    "environment" "text" DEFAULT 'production'::"text" NOT NULL,
    "is_active" boolean DEFAULT false NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."tenant_settings" (
    "tenant_id" "uuid" NOT NULL,
    "settings_data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."tenant_subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "plan_country_configuration_id" "uuid",
    "start_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "end_date" timestamp with time zone,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "is_trial" boolean DEFAULT false NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."tenant_template_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "template_type" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "template_id" "uuid"
);

CREATE TABLE IF NOT EXISTS "public"."tenants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "subscription_status" "text" DEFAULT 'trial'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "default_language_code" "text",
    "default_currency_id" "uuid",
    "default_timezone" "text",
    "contact_person" "text",
    "contact_email" "text",
    "contact_phone" "text",
    "country_id" "uuid",
    "is_active" boolean DEFAULT true,
    "logo_url" "text",
    "notes" "text",
    "legal_name" "text",
    "tax_id" "text",
    "billing_address" "text",
    "website" "text",
    "whatsapp_phone" "text",
    "einvoicing_email" "text",
    "physical_address_line1" "text",
    "physical_address_line2" "text",
    "physical_city" "text",
    "physical_state" "text",
    "physical_postal_code" "text",
    "latitude" numeric(10,7),
    "longitude" numeric(10,7),
    "commercial_email" "text",
    "integrations_mode" "text" DEFAULT 'production'::"text" NOT NULL,
    "is_system_owner" boolean DEFAULT false NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "primary_color" "text",
    "secondary_color" "text",
    "slug" "text",
    "description" "text",
    CONSTRAINT "tenants_subscription_status_check" CHECK (("subscription_status" = ANY (ARRAY['trial'::"text", 'active'::"text", 'inactive'::"text", 'expired'::"text", 'canceled'::"text", 'grace_period'::"text"]))),
    CONSTRAINT "valid_slug_format" CHECK ((("slug" IS NULL) OR (("slug" ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'::"text") AND ("length"("slug") > 2))))
);

CREATE TABLE IF NOT EXISTS "public"."timezones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "offset_str" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "original_countries" "text"[]
);

CREATE TABLE IF NOT EXISTS "public"."translations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "language_id" "uuid" NOT NULL,
    "key" "text" NOT NULL,
    "value" "text" NOT NULL,
    "context" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."vendor_platform_commissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "first_payment_commission_rate" numeric(5,4) DEFAULT 0.50 NOT NULL,
    "recurring_payment_commission_rate" numeric(5,4) DEFAULT 0.10 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."vendor_tenants" (
    "user_id" "uuid" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

-- ========= Constraints and Indexes =========

-- Primary Keys
ALTER TABLE ONLY "public"."asset_purposes" ADD CONSTRAINT "asset_purposes_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."asset_usage_tracking" ADD CONSTRAINT "asset_usage_tracking_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."countries" ADD CONSTRAINT "countries_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."country_timezones" ADD CONSTRAINT "country_timezones_pkey" PRIMARY KEY ("country_id", "timezone_id");
ALTER TABLE ONLY "public"."currencies" ADD CONSTRAINT "currencies_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."email_logs" ADD CONSTRAINT "email_logs_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."email_queue" ADD CONSTRAINT "email_queue_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."email_templates" ADD CONSTRAINT "email_templates_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."error_logs" ADD CONSTRAINT "error_logs_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."exchange_rates" ADD CONSTRAINT "exchange_rates_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."generic_taxes" ADD CONSTRAINT "generic_taxes_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."global_settings" ADD CONSTRAINT "global_settings_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."integration_auth_methods" ADD CONSTRAINT "integration_auth_methods_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."integration_body_formats" ADD CONSTRAINT "integration_body_formats_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."integration_categories" ADD CONSTRAINT "integration_categories_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."integration_http_methods" ADD CONSTRAINT "integration_http_methods_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."integration_providers" ADD CONSTRAINT "integration_providers_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."integrations_config" ADD CONSTRAINT "integrations_config_pkey" PRIMARY KEY ("key");
ALTER TABLE ONLY "public"."investor_platform_shares" ADD CONSTRAINT "investor_platform_shares_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."investor_platform_stakes" ADD CONSTRAINT "investor_platform_stakes_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."languages" ADD CONSTRAINT "languages_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."monthly_charges" ADD CONSTRAINT "monthly_charges_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."payment_intents" ADD CONSTRAINT "payment_intents_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."payments" ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."phone_prefixes" ADD CONSTRAINT "phone_prefixes_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."plan_asset_bonuses" ADD CONSTRAINT "plan_asset_bonuses_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."plan_asset_limits" ADD CONSTRAINT "plan_asset_limits_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."plan_assets" ADD CONSTRAINT "plan_assets_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."plan_country_configurations" ADD CONSTRAINT "plan_country_configurations_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."platform_assignments" ADD CONSTRAINT "platform_assignments_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."platform_countries" ADD CONSTRAINT "platform_countries_pkey" PRIMARY KEY ("platform_id", "country_id");
ALTER TABLE ONLY "public"."platforms" ADD CONSTRAINT "platforms_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."price_tariffs" ADD CONSTRAINT "price_tariffs_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."roles" ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."subscription_assets" ADD CONSTRAINT "subscription_assets_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."subscription_items" ADD CONSTRAINT "subscription_items_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."subscription_plans" ADD CONSTRAINT "subscription_plans_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."system_alerts" ADD CONSTRAINT "system_alerts_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."tariff_asset_prices" ADD CONSTRAINT "tariff_asset_prices_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."tenant_integrations" ADD CONSTRAINT "tenant_integrations_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."tenant_settings" ADD CONSTRAINT "tenant_settings_pkey" PRIMARY KEY ("tenant_id");
ALTER TABLE ONLY "public"."tenant_subscriptions" ADD CONSTRAINT "tenant_subscriptions_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."tenant_template_settings" ADD CONSTRAINT "tenant_template_settings_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."tenants" ADD CONSTRAINT "tenants_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."timezones" ADD CONSTRAINT "timezones_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."translations" ADD CONSTRAINT "translations_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."vendor_platform_commissions" ADD CONSTRAINT "vendor_platform_commissions_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."vendor_tenants" ADD CONSTRAINT "vendor_tenants_pkey" PRIMARY KEY ("user_id", "tenant_id");

-- Unique Constraints
ALTER TABLE ONLY "public"."asset_purposes" ADD CONSTRAINT "asset_purposes_purpose_key_unique" UNIQUE ("purpose_key");
ALTER TABLE ONLY "public"."asset_usage_tracking" ADD CONSTRAINT "asset_usage_tracking_tenant_asset_period_unique" UNIQUE ("tenant_id", "asset_id", "usage_period_start");
ALTER TABLE ONLY "public"."countries" ADD CONSTRAINT "countries_iso_code_key" UNIQUE ("iso_code");
ALTER TABLE ONLY "public"."countries" ADD CONSTRAINT "countries_name_key" UNIQUE ("name");
ALTER TABLE ONLY "public"."currencies" ADD CONSTRAINT "currencies_code_key" UNIQUE ("code");
ALTER TABLE ONLY "public"."currencies" ADD CONSTRAINT "currencies_name_key" UNIQUE ("name");
ALTER TABLE ONLY "public"."exchange_rates" ADD CONSTRAINT "exchange_rates_base_currency_code_target_currency_code_key" UNIQUE ("base_currency_code", "target_currency_code");
ALTER TABLE ONLY "public"."generic_taxes" ADD CONSTRAINT "unique_tax_per_country" UNIQUE ("name", "country_id");
ALTER TABLE ONLY "public"."integration_auth_methods" ADD CONSTRAINT "integration_auth_methods_method_key" UNIQUE ("method");
ALTER TABLE ONLY "public"."integration_body_formats" ADD CONSTRAINT "integration_body_formats_format_key" UNIQUE ("format");
ALTER TABLE ONLY "public"."integration_categories" ADD CONSTRAINT "integration_categories_slug_key" UNIQUE ("slug");
ALTER TABLE ONLY "public"."integration_http_methods" ADD CONSTRAINT "integration_http_methods_method_key" UNIQUE ("method");
ALTER TABLE ONLY "public"."integration_providers" ADD CONSTRAINT "integration_providers_slug_key" UNIQUE ("slug");
ALTER TABLE ONLY "public"."investor_platform_shares" ADD CONSTRAINT "unique_user_platform_share" UNIQUE ("user_id", "platform_id");
ALTER TABLE ONLY "public"."investor_platform_stakes" ADD CONSTRAINT "investor_platform_stakes_investor_user_id_platform_id_key" UNIQUE ("investor_user_id", "platform_id");
ALTER TABLE ONLY "public"."languages" ADD CONSTRAINT "languages_iso_code_key" UNIQUE ("iso_code");
ALTER TABLE ONLY "public"."languages" ADD CONSTRAINT "languages_name_key" UNIQUE ("name");
ALTER TABLE ONLY "public"."monthly_charges" ADD CONSTRAINT "monthly_charges_billing_period_unique" UNIQUE ("tenant_id", "billing_period_start");
ALTER TABLE ONLY "public"."payment_intents" ADD CONSTRAINT "payment_intents_reference_key" UNIQUE ("reference");
ALTER TABLE ONLY "public"."payments" ADD CONSTRAINT "unique_provider_payment" UNIQUE ("provider", "provider_payment_id");
ALTER TABLE ONLY "public"."phone_prefixes" ADD CONSTRAINT "phone_prefixes_iso_code_key" UNIQUE ("iso_code");
ALTER TABLE ONLY "public"."plan_asset_limits" ADD CONSTRAINT "plan_asset_limits_unique_asset_per_config" UNIQUE ("plan_country_config_id", "asset_id");
ALTER TABLE ONLY "public"."plan_assets" ADD CONSTRAINT "unique_asset_key_for_platform" UNIQUE ("platform_id", "asset_key");
ALTER TABLE ONLY "public"."plan_country_configurations" ADD CONSTRAINT "plan_country_configurations_unique" UNIQUE ("plan_id", "country_id");
ALTER TABLE ONLY "public"."platform_assignments" ADD CONSTRAINT "platform_assignments_user_id_platform_id_role_id_key" UNIQUE ("user_id", "platform_id", "role_id");
ALTER TABLE ONLY "public"."platforms" ADD CONSTRAINT "platforms_name_key" UNIQUE ("name");
ALTER TABLE ONLY "public"."price_tariffs" ADD CONSTRAINT "unique_effective_date_for_plan" UNIQUE ("subscription_plan_id", "effective_date");
ALTER TABLE ONLY "public"."roles" ADD CONSTRAINT "roles_name_key" UNIQUE ("name");
ALTER TABLE ONLY "public"."subscription_assets" ADD CONSTRAINT "uq_active_asset" UNIQUE ("tenant_subscription_id", "asset_type", "asset_reference_id", "status");
CREATE UNIQUE INDEX "one_default_trial_per_platform_idx" ON "public"."subscription_plans" USING "btree" ("platform_id") WHERE ("is_default_trial" = true);
ALTER TABLE ONLY "public"."tariff_asset_prices" ADD CONSTRAINT "unique_asset_for_tariff" UNIQUE ("tariff_id", "asset_id");
CREATE UNIQUE INDEX "unique_active_integration_per_provider" ON "public"."tenant_integrations" USING "btree" ("tenant_id", "provider") WHERE ("is_active" = true);
ALTER TABLE ONLY "public"."tenant_integrations" ADD CONSTRAINT "unique_tenant_provider_environment" UNIQUE ("tenant_id", "provider", "environment");
ALTER TABLE ONLY "public"."tenant_subscriptions" ADD CONSTRAINT "tenant_subscriptions_tenant_id_pcc_id_start_date_key" UNIQUE ("tenant_id", "plan_country_configuration_id", "start_date");
ALTER TABLE ONLY "public"."tenant_template_settings" ADD CONSTRAINT "unique_template_per_tenant" UNIQUE ("tenant_id", "template_type");
CREATE UNIQUE INDEX "unique_owner_per_platform" ON "public"."tenants" USING "btree" ("platform_id") WHERE ("is_system_owner" = true);
ALTER TABLE ONLY "public"."tenants" ADD CONSTRAINT "unique_platform_country_slug" UNIQUE ("platform_id", "country_id", "slug");
ALTER TABLE ONLY "public"."timezones" ADD CONSTRAINT "timezones_name_key" UNIQUE ("name");
ALTER TABLE ONLY "public"."translations" ADD CONSTRAINT "translations_language_id_key_key" UNIQUE ("language_id", "key");
ALTER TABLE ONLY "public"."vendor_platform_commissions" ADD CONSTRAINT "vendor_platform_commissions_user_platform_unique" UNIQUE ("user_id", "platform_id");

-- Foreign Keys
ALTER TABLE ONLY "public"."asset_usage_tracking" ADD CONSTRAINT "asset_usage_tracking_asset_id_fkey" FOREIGN KEY (asset_id) REFERENCES public.plan_assets(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."asset_usage_tracking" ADD CONSTRAINT "asset_usage_tracking_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."countries" ADD CONSTRAINT "countries_default_currency_id_fkey" FOREIGN KEY (default_currency_id) REFERENCES public.currencies(id) ON DELETE SET NULL;
ALTER TABLE ONLY "public"."countries" ADD CONSTRAINT "countries_default_language_iso_code_fkey" FOREIGN KEY (default_language_iso_code) REFERENCES public.languages(iso_code) ON UPDATE CASCADE ON DELETE SET NULL;
ALTER TABLE ONLY "public"."countries" ADD CONSTRAINT "countries_default_localization_id_fkey" FOREIGN KEY (default_localization_id) REFERENCES public.languages(id) ON DELETE SET NULL;
ALTER TABLE ONLY "public"."countries" ADD CONSTRAINT "countries_phone_prefix_id_fkey" FOREIGN KEY (phone_prefix_id) REFERENCES public.phone_prefixes(id) ON DELETE SET NULL;
ALTER TABLE ONLY "public"."country_timezones" ADD CONSTRAINT "country_timezones_country_id_fkey" FOREIGN KEY (country_id) REFERENCES public.countries(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."country_timezones" ADD CONSTRAINT "country_timezones_timezone_id_fkey" FOREIGN KEY (timezone_id) REFERENCES public.timezones(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."email_logs" ADD CONSTRAINT "email_logs_template_id_fkey" FOREIGN KEY (template_id) REFERENCES public.email_templates(id) ON DELETE SET NULL;
ALTER TABLE ONLY "public"."email_logs" ADD CONSTRAINT "email_logs_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."email_templates" ADD CONSTRAINT "email_templates_language_id_fkey" FOREIGN KEY (language_id) REFERENCES public.languages(id) ON DELETE RESTRICT;
ALTER TABLE ONLY "public"."email_templates" ADD CONSTRAINT "email_templates_platform_id_fkey" FOREIGN KEY (platform_id) REFERENCES public.platforms(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."email_templates" ADD CONSTRAINT "email_templates_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."error_logs" ADD CONSTRAINT "error_logs_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."generic_taxes" ADD CONSTRAINT "generic_taxes_country_id_fkey" FOREIGN KEY (country_id) REFERENCES public.countries(id);
ALTER TABLE ONLY "public"."global_settings" ADD CONSTRAINT "global_settings_base_currency_id_fkey" FOREIGN KEY (base_currency_id) REFERENCES public.currencies(id) ON DELETE SET NULL;
ALTER TABLE ONLY "public"."integration_providers" ADD CONSTRAINT "fk_auth_method" FOREIGN KEY (auth_method_id) REFERENCES public.integration_auth_methods(id) ON DELETE SET NULL;
ALTER TABLE ONLY "public"."integration_providers" ADD CONSTRAINT "fk_body_format" FOREIGN KEY (body_format_id) REFERENCES public.integration_body_formats(id) ON DELETE SET NULL;
ALTER TABLE ONLY "public"."integration_providers" ADD CONSTRAINT "fk_category" FOREIGN KEY (category_id) REFERENCES public.integration_categories(id);
ALTER TABLE ONLY "public"."integration_providers" ADD CONSTRAINT "fk_country" FOREIGN KEY (country_id) REFERENCES public.countries(id);
ALTER TABLE ONLY "public"."integration_providers" ADD CONSTRAINT "fk_http_method" FOREIGN KEY (http_method_id) REFERENCES public.integration_http_methods(id) ON DELETE SET NULL;
ALTER TABLE ONLY "public"."investor_platform_shares" ADD CONSTRAINT "investor_platform_shares_platform_id_fkey" FOREIGN KEY (platform_id) REFERENCES public.platforms(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."investor_platform_shares" ADD CONSTRAINT "investor_platform_shares_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."investor_platform_stakes" ADD CONSTRAINT "investor_platform_stakes_investor_user_id_fkey" FOREIGN KEY (investor_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."investor_platform_stakes" ADD CONSTRAINT "investor_platform_stakes_platform_id_fkey" FOREIGN KEY (platform_id) REFERENCES public.platforms(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."monthly_charges" ADD CONSTRAINT "monthly_charges_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."payment_intents" ADD CONSTRAINT "payment_intents_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."payments" ADD CONSTRAINT "payments_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE SET NULL;
ALTER TABLE ONLY "public"."plan_asset_bonuses" ADD CONSTRAINT "plan_asset_bonuses_bonus_asset_fkey" FOREIGN KEY (bonus_asset_id) REFERENCES public.plan_assets(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."plan_asset_bonuses" ADD CONSTRAINT "plan_asset_bonuses_source_limit_fkey" FOREIGN KEY (source_asset_limit_id) REFERENCES public.plan_asset_limits(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."plan_asset_limits" ADD CONSTRAINT "plan_asset_limits_asset_id_fkey" FOREIGN KEY (asset_id) REFERENCES public.plan_assets(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."plan_asset_limits" ADD CONSTRAINT "plan_asset_limits_config_id_fkey" FOREIGN KEY (plan_country_config_id) REFERENCES public.plan_country_configurations(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."plan_assets" ADD CONSTRAINT "fk_asset_purpose" FOREIGN KEY (asset_purpose_id) REFERENCES public.asset_purposes(id);
ALTER TABLE ONLY "public"."plan_assets" ADD CONSTRAINT "plan_assets_platform_id_fkey" FOREIGN KEY (platform_id) REFERENCES public.platforms(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."plan_country_configurations" ADD CONSTRAINT "plan_country_configurations_country_id_fkey" FOREIGN KEY (country_id) REFERENCES public.countries(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."plan_country_configurations" ADD CONSTRAINT "plan_country_configurations_plan_id_fkey" FOREIGN KEY (plan_id) REFERENCES public.subscription_plans(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."platform_assignments" ADD CONSTRAINT "platform_assignments_platform_id_fkey" FOREIGN KEY (platform_id) REFERENCES public.platforms(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."platform_assignments" ADD CONSTRAINT "platform_assignments_role_id_fkey" FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."platform_assignments" ADD CONSTRAINT "platform_assignments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."platform_countries" ADD CONSTRAINT "platform_countries_country_id_fkey" FOREIGN KEY (country_id) REFERENCES public.countries(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."platform_countries" ADD CONSTRAINT "platform_countries_platform_id_fkey" FOREIGN KEY (platform_id) REFERENCES public.platforms(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."platforms" ADD CONSTRAINT "platforms_default_currency_id_fkey" FOREIGN KEY (default_currency_id) REFERENCES public.currencies(id);
ALTER TABLE ONLY "public"."platforms" ADD CONSTRAINT "platforms_default_language_id_fkey" FOREIGN KEY (default_language_id) REFERENCES public.languages(id);
ALTER TABLE ONLY "public"."price_tariffs" ADD CONSTRAINT "price_tariffs_currency_id_fkey" FOREIGN KEY (currency_id) REFERENCES public.currencies(id);
ALTER TABLE ONLY "public"."price_tariffs" ADD CONSTRAINT "price_tariffs_subscription_plan_id_fkey" FOREIGN KEY (subscription_plan_id) REFERENCES public.subscription_plans(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."subscription_assets" ADD CONSTRAINT "subscription_assets_tenant_subscription_id_fkey" FOREIGN KEY (tenant_subscription_id) REFERENCES public.tenant_subscriptions(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."subscription_items" ADD CONSTRAINT "subscription_items_subscription_id_fkey" FOREIGN KEY (subscription_id) REFERENCES public.tenant_subscriptions(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."subscription_plans" ADD CONSTRAINT "fk_platform" FOREIGN KEY (platform_id) REFERENCES public.platforms(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."system_alerts" ADD CONSTRAINT "fk_platform" FOREIGN KEY (platform_id) REFERENCES public.platforms(id);
ALTER TABLE ONLY "public"."system_alerts" ADD CONSTRAINT "system_alerts_resolved_by_fkey" FOREIGN KEY (resolved_by) REFERENCES auth.users(id);
ALTER TABLE ONLY "public"."tariff_asset_prices" ADD CONSTRAINT "tariff_asset_prices_asset_id_fkey" FOREIGN KEY (asset_id) REFERENCES public.plan_assets(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."tariff_asset_prices" ADD CONSTRAINT "tariff_asset_prices_tariff_id_fkey" FOREIGN KEY (tariff_id) REFERENCES public.price_tariffs(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."tenant_integrations" ADD CONSTRAINT "tenant_integrations_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."tenant_settings" ADD CONSTRAINT "tenant_settings_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."tenant_subscriptions" ADD CONSTRAINT "tenant_subscriptions_plan_country_configuration_id_fkey" FOREIGN KEY (plan_country_configuration_id) REFERENCES public.plan_country_configurations(id) ON DELETE RESTRICT;
ALTER TABLE ONLY "public"."tenant_subscriptions" ADD CONSTRAINT "tenant_subscriptions_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."tenant_template_settings" ADD CONSTRAINT "tenant_template_settings_template_id_fkey" FOREIGN KEY (template_id) REFERENCES public.email_templates(id) ON DELETE SET NULL;
ALTER TABLE ONLY "public"."tenant_template_settings" ADD CONSTRAINT "tenant_template_settings_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."tenants" ADD CONSTRAINT "tenants_country_id_fkey" FOREIGN KEY (country_id) REFERENCES public.countries(id) ON DELETE SET NULL;
ALTER TABLE ONLY "public"."tenants" ADD CONSTRAINT "tenants_default_currency_id_fkey" FOREIGN KEY (default_currency_id) REFERENCES public.currencies(id) ON UPDATE CASCADE ON DELETE SET NULL;
ALTER TABLE ONLY "public"."tenants" ADD CONSTRAINT "tenants_platform_id_fkey" FOREIGN KEY (platform_id) REFERENCES public.platforms(id) ON DELETE SET NULL;
ALTER TABLE ONLY "public"."translations" ADD CONSTRAINT "translations_language_id_fkey" FOREIGN KEY (language_id) REFERENCES public.languages(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."vendor_platform_commissions" ADD CONSTRAINT "vendor_platform_commissions_platform_id_fkey" FOREIGN KEY (platform_id) REFERENCES public.platforms(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."vendor_platform_commissions" ADD CONSTRAINT "vendor_platform_commissions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."vendor_tenants" ADD CONSTRAINT "vendor_tenants_tenant_id_fkey" FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE;
ALTER TABLE ONLY "public"."vendor_tenants" ADD CONSTRAINT "vendor_tenants_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

-- ========= Indexes =========
CREATE INDEX "idx_plan_assets_platform_id" ON "public"."plan_assets" USING "btree" ("platform_id");
CREATE INDEX "idx_price_tariffs_plan_id_effective_date" ON "public"."price_tariffs" USING "btree" ("subscription_plan_id", "effective_date" DESC);
CREATE INDEX "idx_subscription_plans_platform_id" ON "public"."subscription_plans" USING "btree" ("platform_id");
CREATE INDEX "idx_tariff_asset_prices_tariff_id" ON "public"."tariff_asset_prices" USING "btree" ("tariff_id");
CREATE INDEX "idx_tenant_settings_data" ON "public"."tenant_settings" USING "gin" ("settings_data");
CREATE INDEX "idx_tenants_country_id" ON "public"."tenants" USING "btree" ("country_id");
CREATE INDEX "idx_translations_context" ON "public"."translations" USING "btree" ("context");
CREATE INDEX "idx_translations_language_key" ON "public"."translations" USING "btree" ("language_id", "key");