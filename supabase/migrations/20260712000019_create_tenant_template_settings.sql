-- Migration: 20260712000019_create_tenant_template_settings.sql
-- Description: Create the tenant_template_settings table that was missing from the schema.

CREATE TABLE IF NOT EXISTS "public"."tenant_template_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "platform_id" "uuid" NOT NULL,
    "template_type" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "public"."tenant_template_settings"
    ADD CONSTRAINT "tenant_template_settings_pkey" PRIMARY KEY ("id", "tenant_id", "platform_id");

ALTER TABLE ONLY "public"."tenant_template_settings"
    ADD CONSTRAINT "tenant_template_settings_tenant_id_fkey" FOREIGN KEY ("tenant_id", "platform_id") REFERENCES "public"."tenants"("id", "platform_id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."tenant_template_settings"
    ADD CONSTRAINT "tenant_template_settings_unique" UNIQUE ("tenant_id", "platform_id", "template_type");

ALTER TABLE "public"."tenant_template_settings" ENABLE ROW LEVEL SECURITY;

GRANT ALL ON TABLE "public"."tenant_template_settings" TO "anon";
GRANT ALL ON TABLE "public"."tenant_template_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."tenant_template_settings" TO "service_role";
