-- Migration: 20260712000017_add_document_type_fks.sql
-- Description: Add missing foreign keys to document_types for suppliers and clients.

ALTER TABLE "public"."suppliers"
    ADD CONSTRAINT "suppliers_document_type_id_fkey" 
    FOREIGN KEY ("document_type_id", "tenant_id", "platform_id") 
    REFERENCES "public"."document_types"("id", "tenant_id", "platform_id") 
    ON DELETE SET NULL;

ALTER TABLE "public"."clients"
    ADD CONSTRAINT "clients_document_type_id_fkey" 
    FOREIGN KEY ("document_type_id", "tenant_id", "platform_id") 
    REFERENCES "public"."document_types"("id", "tenant_id", "platform_id") 
    ON DELETE SET NULL;
