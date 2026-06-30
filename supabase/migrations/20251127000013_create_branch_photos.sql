CREATE TABLE public.branch_photos (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    branch_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    google_drive_file_id text NOT NULL,
    file_name text,
    file_size bigint,
    mime_type text,
    is_primary boolean NOT NULL DEFAULT false,
    sort_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT branch_photos_pkey PRIMARY KEY (id),
    CONSTRAINT fk_branch_photos_branch FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE CASCADE,
    CONSTRAINT fk_branch_photos_tenant FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE
);

-- Index for efficient lookup of photos by branch
CREATE INDEX idx_branch_photos_branch_id ON public.branch_photos(branch_id);

-- This unique index ensures that only one photo can be marked as primary for each branch.
-- The "WHERE is_primary" clause makes it a partial index.
CREATE UNIQUE INDEX unique_primary_photo_per_branch
ON public.branch_photos (branch_id)
WHERE (is_primary);

-- Add row-level security
ALTER TABLE public.branch_photos ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Tenant users can manage their own branch photos"
ON public.branch_photos
FOR ALL
USING (auth.uid() IN (SELECT user_id FROM get_tenant_users(tenant_id)));


COMMENT ON TABLE public.branch_photos IS 'Stores photos associated with a tenant branch for public display.';
COMMENT ON COLUMN public.branch_photos.is_primary IS 'Indicates if this is the primary photo for the branch, used as the main image on microsites.';

-- Trigger for updated_at
CREATE TRIGGER handle_updated_at BEFORE UPDATE ON public.branch_photos
  FOR EACH ROW EXECUTE PROCEDURE moddatetime (updated_at);
