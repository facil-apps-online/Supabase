ALTER TABLE public.countries ADD COLUMN field_placeholders jsonb;

COMMENT ON COLUMN "public"."countries"."field_placeholders" IS 'JSONB object to store example texts for different fields, e.g., {"phone": [{"label": "Mobile", "value": "+123456789"}]}';