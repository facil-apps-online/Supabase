-- Step 1: Rename tables
ALTER TABLE public.treatment_prototypes RENAME TO treatments;
ALTER TABLE public.prototype_sessions RENAME TO treatment_sessions;
ALTER TABLE public.prototype_session_items RENAME TO treatment_session_items;

-- Step 2: Rename columns and constraints
-- In treatment_sessions table
ALTER TABLE public.treatment_sessions RENAME COLUMN prototype_id TO treatment_id;
ALTER TABLE public.treatment_sessions RENAME CONSTRAINT prototype_sessions_pkey TO treatment_sessions_pkey;
ALTER TABLE public.treatment_sessions RENAME CONSTRAINT prototype_sessions_prototype_id_fkey TO treatment_sessions_treatment_id_fkey;
ALTER TABLE public.treatment_sessions RENAME CONSTRAINT prototype_sessions_prototype_id_session_number_key TO treatment_sessions_treatment_id_session_number_key;

-- In treatment_session_items table
ALTER TABLE public.treatment_session_items RENAME CONSTRAINT prototype_session_items_pkey TO treatment_session_items_pkey;
ALTER TABLE public.treatment_session_items RENAME CONSTRAINT prototype_session_items_session_id_fkey TO treatment_session_items_session_id_fkey;


-- Step 3: Adjust column types and defaults to match the desired schema
ALTER TABLE public.treatments
  ALTER COLUMN upfront_price TYPE numeric(10, 2),
  ALTER COLUMN upfront_price SET DEFAULT 0.00,
  ALTER COLUMN financed_price TYPE numeric(10, 2),
  ALTER COLUMN financed_price SET DEFAULT 0.00;

ALTER TABLE public.treatment_sessions
  ALTER COLUMN payment_percentage TYPE numeric(5, 2),
  ALTER COLUMN fixed_payment_amount TYPE numeric(10, 2);

ALTER TABLE public.treatment_session_items
  ALTER COLUMN quantity SET DEFAULT 1;

-- Step 4: Create the treatment_images table
CREATE TABLE public.treatment_images (
  id uuid NOT NULL DEFAULT extensions.uuid_generate_v4(),
  treatment_id uuid NOT NULL,
  tenant_id uuid NOT NULL,
  image_url text NOT NULL,
  is_primary bool NOT NULL DEFAULT false,
  sort_order int4 NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  google_drive_file_id text NULL,
  file_name text NULL,
  mime_type text NULL,
  file_size int8 NULL,
  CONSTRAINT treatment_images_pkey PRIMARY KEY (id),
  CONSTRAINT treatment_images_treatment_id_fkey FOREIGN KEY (treatment_id) REFERENCES public.treatments(id) ON DELETE CASCADE,
  CONSTRAINT treatment_images_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.tenants(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_treatment_images_treatment_id ON public.treatment_images USING btree (treatment_id);
CREATE INDEX IF NOT EXISTS idx_treatment_images_tenant_id ON public.treatment_images USING btree (tenant_id);

CREATE TRIGGER on_treatment_image_deleted
AFTER DELETE ON public.treatment_images FOR EACH ROW
EXECUTE FUNCTION handle_google_drive_file_delete();