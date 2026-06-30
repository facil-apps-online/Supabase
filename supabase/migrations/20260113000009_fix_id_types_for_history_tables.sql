-- Step 1: Drop the incorrect Primary Keys created in the previous migration.
ALTER TABLE public.rescheduled_attentions DROP CONSTRAINT IF EXISTS rescheduled_attentions_pkey;
ALTER TABLE public.staff_gallery_items DROP CONSTRAINT IF EXISTS staff_gallery_items_pkey;

-- Step 2: Re-engineer the id column for rescheduled_attentions
ALTER TABLE public.rescheduled_attentions ADD COLUMN uuid_id UUID NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE public.rescheduled_attentions DROP COLUMN id CASCADE;
ALTER TABLE public.rescheduled_attentions RENAME COLUMN uuid_id TO id;

-- Step 3: Re-engineer the id column for staff_gallery_items
ALTER TABLE public.staff_gallery_items ADD COLUMN uuid_id UUID NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE public.staff_gallery_items DROP COLUMN id CASCADE;
ALTER TABLE public.staff_gallery_items RENAME COLUMN uuid_id TO id;

-- Step 4: Re-create the Primary Keys with the correct UUID id column.
ALTER TABLE public.rescheduled_attentions ADD PRIMARY KEY (id, attention_id, tenant_id, platform_id);
ALTER TABLE public.staff_gallery_items ADD PRIMARY KEY (id, tenant_id, platform_id);
