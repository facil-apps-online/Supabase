-- Migration: 20260712000016_add_invoices_client_fk.sql
-- Description: Add missing foreign key between invoices and clients.

ALTER TABLE "public"."invoices"
    ADD CONSTRAINT "invoices_billed_to_client_id_fkey" 
    FOREIGN KEY ("billed_to_client_id", "tenant_id", "platform_id") 
    REFERENCES "public"."clients"("id", "tenant_id", "platform_id") 
    ON DELETE SET NULL;
