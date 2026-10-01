-- clients tenia dos FK identicas hacia document_types (document_type_id, tenant_id, platform_id):
--   clients_document_type_id_fkey (20260712000017) y fk_clients_document_type (20260712000007).
-- PostgREST no puede resolver el embed `document_types(...)` (PGRST201) y get_client_details,
-- get_clients_by_branch, etc. fallaban. Se conserva clients_document_type_id_fkey.
ALTER TABLE "public"."clients" DROP CONSTRAINT IF EXISTS "fk_clients_document_type";
