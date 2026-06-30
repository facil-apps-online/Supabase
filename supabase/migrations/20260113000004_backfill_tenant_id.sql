-- Set REPLICA IDENTITY to FULL for tables that will be updated to allow UPDATEs without a PK
ALTER TABLE public.invoice_items REPLICA IDENTITY FULL;
ALTER TABLE public.invoice_item_taxes REPLICA IDENTITY FULL;
ALTER TABLE public.branch_status_history REPLICA IDENTITY FULL;
ALTER TABLE public.purchase_items REPLICA IDENTITY FULL;
ALTER TABLE public.combo_items REPLICA IDENTITY FULL;
ALTER TABLE public.playlist_items REPLICA IDENTITY FULL;
ALTER TABLE public.product_transfer_items REPLICA IDENTITY FULL;
ALTER TABLE public.branch_playback_state REPLICA IDENTITY FULL;
ALTER TABLE public.rescheduled_attentions REPLICA IDENTITY FULL;
ALTER TABLE public.branch_social_networks REPLICA IDENTITY FULL;
ALTER TABLE public.sales_items REPLICA IDENTITY FULL;
ALTER TABLE public.payslip_commissions REPLICA IDENTITY FULL;
ALTER TABLE public.treatment_sessions REPLICA IDENTITY FULL;
ALTER TABLE public.treatment_session_items REPLICA IDENTITY FULL;
ALTER TABLE public.client_treatment_sessions REPLICA IDENTITY FULL;
ALTER TABLE public.treatment_category_assignments REPLICA IDENTITY FULL;
ALTER TABLE public.client_treatment_session_items REPLICA IDENTITY FULL;
ALTER TABLE public.product_transfer_reception_items REPLICA IDENTITY FULL;

-- Backfill tenant_id for various tables based on their relationships
-- This script assumes that the parent tables (like invoices, branches, products) already have their tenant_id populated correctly.

-- invoice_items from invoices
UPDATE public.invoice_items
SET tenant_id = i.tenant_id
FROM public.invoices i
WHERE public.invoice_items.invoice_id = i.id AND public.invoice_items.tenant_id IS NULL;

-- invoice_item_taxes from invoice_items
UPDATE public.invoice_item_taxes
SET tenant_id = ii.tenant_id
FROM public.invoice_items ii
WHERE public.invoice_item_taxes.invoice_item_id = ii.id AND public.invoice_item_taxes.tenant_id IS NULL;

-- branch_status_history from branches
UPDATE public.branch_status_history
SET tenant_id = b.tenant_id
FROM public.branches b
WHERE public.branch_status_history.branch_id = b.id AND public.branch_status_history.tenant_id IS NULL;

-- purchase_items from purchases
UPDATE public.purchase_items
SET tenant_id = p.tenant_id
FROM public.purchases p
WHERE public.purchase_items.purchase_id = p.id AND public.purchase_items.tenant_id IS NULL;

-- combo_items from combos
UPDATE public.combo_items
SET tenant_id = c.tenant_id
FROM public.combos c
WHERE public.combo_items.combo_id = c.id AND public.combo_items.tenant_id IS NULL;

-- playlist_items from media_playlists
UPDATE public.playlist_items
SET tenant_id = mp.tenant_id
FROM public.media_playlists mp
WHERE public.playlist_items.playlist_id = mp.id AND public.playlist_items.tenant_id IS NULL;

-- product_transfer_items from product_transfers
UPDATE public.product_transfer_items
SET tenant_id = pt.tenant_id
FROM public.product_transfers pt
WHERE public.product_transfer_items.transfer_id = pt.id AND public.product_transfer_items.tenant_id IS NULL;

-- branch_playback_state from branches
UPDATE public.branch_playback_state
SET tenant_id = b.tenant_id
FROM public.branches b
WHERE public.branch_playback_state.branch_id = b.id AND public.branch_playback_state.tenant_id IS NULL;

-- rescheduled_attentions from attentions
UPDATE public.rescheduled_attentions
SET tenant_id = a.tenant_id
FROM public.attentions a
WHERE public.rescheduled_attentions.attention_id = a.id AND public.rescheduled_attentions.tenant_id IS NULL;

-- branch_social_networks from branches
UPDATE public.branch_social_networks
SET tenant_id = b.tenant_id
FROM public.branches b
WHERE public.branch_social_networks.branch_id = b.id AND public.branch_social_networks.tenant_id IS NULL;

-- sales_items from sales
UPDATE public.sales_items
SET tenant_id = s.tenant_id
FROM public.sales s
WHERE public.sales_items.sale_id = s.id AND public.sales_items.tenant_id IS NULL;

-- payslip_commissions from payslips
UPDATE public.payslip_commissions
SET tenant_id = p.tenant_id
FROM public.payslips p
WHERE public.payslip_commissions.payslip_id = p.id AND public.payslip_commissions.tenant_id IS NULL;

-- treatment_sessions from treatments
UPDATE public.treatment_sessions
SET tenant_id = t.tenant_id
FROM public.treatments t
WHERE public.treatment_sessions.treatment_id = t.id AND public.treatment_sessions.tenant_id IS NULL;

-- treatment_session_items from treatment_sessions
UPDATE public.treatment_session_items
SET tenant_id = ts.tenant_id
FROM public.treatment_sessions ts
WHERE public.treatment_session_items.session_id = ts.id AND public.treatment_session_items.tenant_id IS NULL;

-- client_treatment_sessions from client_treatments
UPDATE public.client_treatment_sessions
SET tenant_id = ct.tenant_id
FROM public.client_treatments ct
WHERE public.client_treatment_sessions.client_treatment_id = ct.id AND public.client_treatment_sessions.tenant_id IS NULL;

-- treatment_category_assignments from treatments
UPDATE public.treatment_category_assignments
SET tenant_id = t.tenant_id
FROM public.treatments t
WHERE public.treatment_category_assignments.treatment_id = t.id AND public.treatment_category_assignments.tenant_id IS NULL;

-- client_treatment_session_items from client_treatment_sessions
UPDATE public.client_treatment_session_items
SET tenant_id = cts.tenant_id
FROM public.client_treatment_sessions cts
WHERE public.client_treatment_session_items.client_treatment_session_id = cts.id AND public.client_treatment_session_items.tenant_id IS NULL;

-- product_transfer_reception_items from product_transfer_receptions
UPDATE public.product_transfer_reception_items
SET tenant_id = ptr.tenant_id
FROM public.product_transfer_receptions ptr
WHERE public.product_transfer_reception_items.reception_id = ptr.id AND public.product_transfer_reception_items.tenant_id IS NULL;

-- Finally, drop the redundant column from tenants
ALTER TABLE public.tenants DROP COLUMN IF EXISTS tenant_id;