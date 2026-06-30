-- Migration to add RLS helper functions and policies for the core schema.

-- ========= RLS Helper Functions =========

CREATE OR REPLACE FUNCTION "public"."get_current_tenant_id"() RETURNS "uuid"
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
    tenant_id uuid;
BEGIN
    SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' -> 'assignments' -> 0 ->> 'tenant_id', '')::uuid INTO tenant_id;
    RETURN tenant_id;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."get_current_role_name"() RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$
  SELECT NULLIF(current_setting('app.current_assignment.role_name', TRUE), '');
$$;

CREATE OR REPLACE FUNCTION "public"."is_super_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  SELECT get_current_role_name() = 'super_admin';
$$;

-- ========= RLS Policies =========

-- Enable RLS on all core tables
ALTER TABLE "public"."asset_purposes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."asset_usage_tracking" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."countries" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."country_timezones" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."currencies" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."email_logs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."email_queue" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."email_templates" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."error_logs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."exchange_rates" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."generic_taxes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."global_settings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."integration_auth_methods" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."integration_body_formats" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."integration_categories" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."integration_http_methods" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."integration_providers" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."integration_record" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."integrations_config" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."investor_platform_shares" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."investor_platform_stakes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."languages" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."monthly_charges" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."payment_intents" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."phone_prefixes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."plan_asset_bonuses" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."plan_asset_limits" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."plan_assets" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."plan_country_configurations" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."platform_assignments" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."platform_countries" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."platforms" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."price_tariffs" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."subscription_assets" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."subscription_items" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."subscription_plans" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."system_alerts" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."tariff_asset_prices" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."tenant_integrations" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."tenant_settings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."tenant_subscriptions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."tenant_template_settings" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."tenants" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."timezones" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."translations" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."vendor_platform_commissions" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."vendor_tenants" ENABLE ROW LEVEL SECURITY;

-- Create Policies
-- Note: A baseline of 'super_admin' access is provided.
CREATE POLICY "Allow ALL for super_admin" ON "public"."asset_purposes" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."asset_usage_tracking" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."countries" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."country_timezones" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."currencies" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."email_logs" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."email_queue" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."email_templates" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."error_logs" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."exchange_rates" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."generic_taxes" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."global_settings" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."integration_auth_methods" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."integration_body_formats" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."integration_categories" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."integration_http_methods" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."integration_providers" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."integrations_config" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."investor_platform_shares" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."investor_platform_stakes" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."languages" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."monthly_charges" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."payment_intents" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."payments" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."phone_prefixes" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."plan_asset_bonuses" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."plan_asset_limits" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."plan_assets" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."plan_country_configurations" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."platform_assignments" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."platform_countries" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."platforms" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."price_tariffs" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."roles" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."subscription_assets" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."subscription_items" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."subscription_plans" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."system_alerts" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."tariff_asset_prices" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."tenant_integrations" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."tenant_settings" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."tenant_subscriptions" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."tenant_template_settings" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."tenants" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."timezones" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."translations" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."vendor_platform_commissions" USING (is_super_admin()) WITH CHECK (is_super_admin());
CREATE POLICY "Allow ALL for super_admin" ON "public"."vendor_tenants" USING (is_super_admin()) WITH CHECK (is_super_admin());

-- Public read access for some tables
CREATE POLICY "Allow public read access" ON "public"."countries" FOR SELECT USING (true);
CREATE POLICY "Allow public read access" ON "public"."currencies" FOR SELECT USING (true);
CREATE POLICY "Allow public read access" ON "public"."languages" FOR SELECT USING (true);
CREATE POLICY "Allow public read access" ON "public"."platforms" FOR SELECT USING (true);
CREATE POLICY "Allow public read access" ON "public"."phone_prefixes" FOR SELECT USING (true);

-- Allow tenant members to read their own tenant's data
CREATE POLICY "Allow tenant members read access" ON "public"."tenants" FOR SELECT USING ((id = get_current_tenant_id()));
CREATE POLICY "Allow tenant members read access" ON "public"."tenant_subscriptions" FOR SELECT USING ((tenant_id = get_current_tenant_id()));
