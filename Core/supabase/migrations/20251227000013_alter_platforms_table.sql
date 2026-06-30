-- Migration #13: Alter Platforms table to remove default columns

ALTER TABLE "public"."platforms"
DROP COLUMN IF EXISTS "default_currency_id",
DROP COLUMN IF EXISTS "default_language_id",
DROP COLUMN IF EXISTS "default_timezone";
