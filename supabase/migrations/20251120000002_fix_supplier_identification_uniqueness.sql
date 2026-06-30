-- Drop the old unique constraint
ALTER TABLE "public"."suppliers"
DROP CONSTRAINT "suppliers_identification_number_key";

-- Create the new composite unique constraint
ALTER TABLE "public"."suppliers"
ADD CONSTRAINT "suppliers_identification_number_tenant_id_key" UNIQUE ("identification_number", "tenant_id");
