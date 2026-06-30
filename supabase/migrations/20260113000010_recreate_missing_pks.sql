ALTER TABLE public.attention_combos ADD PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.payment_methods ADD PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.product_brands ADD PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.purchase_item_receptions ADD PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.service_categories ADD PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.service_sessions ADD PRIMARY KEY (id, tenant_id, platform_id);
ALTER TABLE public.supplier_products ADD PRIMARY KEY (id, tenant_id, platform_id);
