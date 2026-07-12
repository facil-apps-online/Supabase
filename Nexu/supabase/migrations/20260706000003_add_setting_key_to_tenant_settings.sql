-- Add setting_key to support multiple configuration rows per tenant
-- Each setting_key stores a focused JSON, avoiding one giant blob

ALTER TABLE public.tenant_settings 
ADD COLUMN setting_key TEXT NOT NULL DEFAULT 'general';

ALTER TABLE public.tenant_settings 
DROP CONSTRAINT tenant_settings_pkey;

ALTER TABLE public.tenant_settings 
ADD PRIMARY KEY (tenant_id, platform_id, setting_key);
