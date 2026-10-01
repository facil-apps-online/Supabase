-- Migration: 20260712000007_add_clients_document_type_fk.sql
-- Description: Adds missing foreign key from clients.document_type_id to document_types

ALTER TABLE "public"."clients"
    ADD CONSTRAINT "fk_clients_document_type" 
    FOREIGN KEY ("document_type_id", "tenant_id", "platform_id") 
    REFERENCES "public"."document_types"("id", "tenant_id", "platform_id") 
    ON DELETE SET NULL;
