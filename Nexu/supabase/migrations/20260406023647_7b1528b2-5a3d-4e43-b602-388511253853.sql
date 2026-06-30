
INSERT INTO storage.buckets (id, name, public)
VALUES ('company-logos', 'company-logos', true)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "Anyone can view company logos"
ON storage.objects FOR SELECT
USING (bucket_id = 'company-logos');

CREATE POLICY "Authenticated users can upload company logos"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'company-logos');

CREATE POLICY "Authenticated users can update company logos"
ON storage.objects FOR UPDATE
TO authenticated
USING (bucket_id = 'company-logos');

CREATE POLICY "Authenticated users can delete company logos"
ON storage.objects FOR DELETE
TO authenticated
USING (bucket_id = 'company-logos');
