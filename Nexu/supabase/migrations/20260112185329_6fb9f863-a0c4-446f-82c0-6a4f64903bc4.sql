-- Fix storage policies for exam-documents bucket to require proper permissions

-- Drop existing weak policies
DROP POLICY IF EXISTS "Users can upload exam documents in their tenant" ON storage.objects;
DROP POLICY IF EXISTS "Users can update exam documents in their tenant" ON storage.objects;
DROP POLICY IF EXISTS "Users can delete exam documents in their tenant" ON storage.objects;
DROP POLICY IF EXISTS "Users can view exam documents in their tenant" ON storage.objects;

-- Create permission-based INSERT policy
CREATE POLICY "Restricted exam document upload" ON storage.objects
FOR INSERT WITH CHECK (
  bucket_id = 'exam-documents'
  AND auth.uid() IS NOT NULL
  AND public.get_user_tenant_id(auth.uid()) IS NOT NULL
  AND (
    public.is_super_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'examenes', 'crear')
  )
);

-- Create permission-based SELECT policy
CREATE POLICY "Restricted exam document view" ON storage.objects
FOR SELECT USING (
  bucket_id = 'exam-documents'
  AND auth.uid() IS NOT NULL
  AND public.get_user_tenant_id(auth.uid()) IS NOT NULL
  AND (
    public.is_super_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'examenes', 'ver')
  )
);

-- Create permission-based UPDATE policy
CREATE POLICY "Restricted exam document update" ON storage.objects
FOR UPDATE USING (
  bucket_id = 'exam-documents'
  AND auth.uid() IS NOT NULL
  AND public.get_user_tenant_id(auth.uid()) IS NOT NULL
  AND (
    public.is_super_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'examenes', 'editar')
  )
);

-- Create permission-based DELETE policy
CREATE POLICY "Restricted exam document delete" ON storage.objects
FOR DELETE USING (
  bucket_id = 'exam-documents'
  AND auth.uid() IS NOT NULL
  AND public.get_user_tenant_id(auth.uid()) IS NOT NULL
  AND (
    public.is_super_admin(auth.uid())
    OR public.has_permission(auth.uid(), 'examenes', 'eliminar')
  )
);