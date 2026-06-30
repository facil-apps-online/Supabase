-- 1. Create the combo_images table
CREATE TABLE public.combo_images (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    combo_id uuid NOT NULL,
    google_drive_file_id text NOT NULL,
    image_url text,
    file_name text,
    file_size bigint,
    mime_type text,
    is_primary boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    tenant_id uuid NOT NULL,
    CONSTRAINT combo_images_pkey PRIMARY KEY (id),
    CONSTRAINT fk_combo_images_combo FOREIGN KEY (combo_id) REFERENCES public.combos(id) ON DELETE CASCADE,
    CONSTRAINT fk_combo_images_tenant FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE
);

-- 2. Add comments to the table and columns
COMMENT ON TABLE public.combo_images IS 'Stores images associated with a combo.';
COMMENT ON COLUMN public.combo_images.is_primary IS 'Indicates if this is the primary image for the combo.';
COMMENT ON COLUMN public.combo_images.sort_order IS 'Defines the display order of the images.';

-- 3. Create indexes
CREATE INDEX idx_combo_images_combo_id ON public.combo_images(combo_id);
CREATE UNIQUE INDEX unique_primary_image_per_combo ON public.combo_images (combo_id) WHERE (is_primary);

-- 4. Enable Row Level Security (RLS)
ALTER TABLE public.combo_images ENABLE ROW LEVEL SECURITY;

-- 5. Create RLS policies
CREATE POLICY "Allow tenant members to manage combo images"
ON public.combo_images
FOR ALL
USING (
    EXISTS (
        SELECT 1
        FROM public.user_assignments ua
        WHERE ua.tenant_id = combo_images.tenant_id
          AND ua.user_id = auth.uid()
    )
)
WITH CHECK (
    EXISTS (
        SELECT 1
        FROM public.user_assignments ua
        WHERE ua.tenant_id = combo_images.tenant_id
          AND ua.user_id = auth.uid()
    )
);

-- 6. Add trigger for updated_at timestamp
CREATE TRIGGER handle_updated_at BEFORE UPDATE ON public.combo_images
FOR EACH ROW EXECUTE PROCEDURE moddatetime (updated_at);

-- 7. Add trigger to delete file from Google Drive on row deletion
-- This trigger calls a function that must be created separately.
-- Assuming 'delete_drive_file_on_delete' function exists and is generic enough.
CREATE TRIGGER on_combo_image_deleted
AFTER DELETE ON public.combo_images
FOR EACH ROW EXECUTE FUNCTION public.handle_google_drive_file_delete();
