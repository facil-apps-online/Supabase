-- Add size columns for storage tracking

ALTER TABLE public.tenants ADD COLUMN IF NOT EXISTS logo_size INTEGER;
ALTER TABLE public.courses ADD COLUMN IF NOT EXISTS certificate_size INTEGER;
ALTER TABLE public.evidences ADD COLUMN IF NOT EXISTS file_size INTEGER;
ALTER TABLE public.regulations ADD COLUMN IF NOT EXISTS document_size INTEGER;
ALTER TABLE public.exams ADD COLUMN IF NOT EXISTS document_size INTEGER;
ALTER TABLE public.incapacidades ADD COLUMN IF NOT EXISTS documento_size INTEGER;
