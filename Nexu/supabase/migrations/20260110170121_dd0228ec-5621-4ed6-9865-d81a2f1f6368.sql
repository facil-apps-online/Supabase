-- Create storage bucket for exam documents
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('exam-documents', 'exam-documents', false, 10485760, ARRAY['application/pdf', 'image/jpeg', 'image/png', 'image/jpg'])
ON CONFLICT (id) DO NOTHING;

-- Create policies for exam documents bucket
CREATE POLICY "Users can view exam documents in their tenant"
ON storage.objects FOR SELECT
USING (
  bucket_id = 'exam-documents' 
  AND (
    EXISTS (
      SELECT 1 FROM exams e
      WHERE e.document_url LIKE '%' || name
      AND e.tenant_id = get_user_tenant_id(auth.uid())
    )
    OR is_super_admin(auth.uid())
  )
);

CREATE POLICY "Users can upload exam documents in their tenant"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'exam-documents'
  AND get_user_tenant_id(auth.uid()) IS NOT NULL
);

CREATE POLICY "Users can update exam documents in their tenant"
ON storage.objects FOR UPDATE
USING (
  bucket_id = 'exam-documents'
  AND get_user_tenant_id(auth.uid()) IS NOT NULL
);

CREATE POLICY "Users can delete exam documents in their tenant"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'exam-documents'
  AND get_user_tenant_id(auth.uid()) IS NOT NULL
);

-- Add entity column to exams table if it doesn't exist
ALTER TABLE public.exams 
ADD COLUMN IF NOT EXISTS entity TEXT;

-- Add scheduled_date column to exams table for scheduling vs actual exam date
ALTER TABLE public.exams 
ADD COLUMN IF NOT EXISTS scheduled_date DATE;

-- Create index on scheduled_date for better query performance
CREATE INDEX IF NOT EXISTS idx_exams_scheduled_date ON public.exams(scheduled_date);
CREATE INDEX IF NOT EXISTS idx_exams_exam_date ON public.exams(exam_date);
CREATE INDEX IF NOT EXISTS idx_exams_status ON public.exams(status);