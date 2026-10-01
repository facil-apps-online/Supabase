-- Migration: 20260712000018_add_purchases_fks.sql
-- Description: Add missing foreign keys for purchases and purchase_items.

ALTER TABLE "public"."purchases"
    ADD CONSTRAINT "purchases_branch_id_fkey" 
    FOREIGN KEY ("branch_id", "tenant_id", "platform_id") 
    REFERENCES "public"."branches"("id", "tenant_id", "platform_id") 
    ON DELETE CASCADE;

ALTER TABLE "public"."purchases"
    ADD CONSTRAINT "purchases_supplier_id_fkey" 
    FOREIGN KEY ("supplier_id", "tenant_id", "platform_id") 
    REFERENCES "public"."suppliers"("id", "tenant_id", "platform_id") 
    ON DELETE SET NULL;

ALTER TABLE "public"."purchase_items"
    ADD CONSTRAINT "purchase_items_product_id_fkey" 
    FOREIGN KEY ("product_id", "tenant_id", "platform_id") 
    REFERENCES "public"."products"("id", "tenant_id", "platform_id") 
    ON DELETE CASCADE;
