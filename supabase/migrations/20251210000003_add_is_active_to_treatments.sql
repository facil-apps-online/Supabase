ALTER TABLE public.treatments
ADD COLUMN is_active BOOLEAN NOT NULL DEFAULT true;
