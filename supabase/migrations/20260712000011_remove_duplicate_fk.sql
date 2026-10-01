-- Migration: 20260712000011_remove_duplicate_fk.sql
-- Description: Removes the duplicate foreign key created in 20260712000010

ALTER TABLE "public"."client_document_instances"
    DROP CONSTRAINT IF EXISTS "fk_client_document_instances_template";
