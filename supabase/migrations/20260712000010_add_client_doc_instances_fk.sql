-- Migration: 20260712000010_add_client_doc_instances_fk.sql
-- Description: Adds missing foreign key from client_document_instances.template_id to client_document_templates

ALTER TABLE "public"."client_document_instances"
    ADD CONSTRAINT "fk_client_document_instances_template" 
    FOREIGN KEY ("template_id", "tenant_id", "platform_id") 
    REFERENCES "public"."client_document_templates"("id", "tenant_id", "platform_id") 
    ON DELETE CASCADE;
