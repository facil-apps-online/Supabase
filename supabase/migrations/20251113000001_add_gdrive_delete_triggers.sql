-- Function to call the google-drive-delete edge function
CREATE OR REPLACE FUNCTION public.handle_google_drive_file_delete()
RETURNS TRIGGER AS $$
DECLARE
  v_file_id TEXT;
  v_tenant_id UUID;
  v_jwt TEXT;
BEGIN
  -- Use a block to handle potential exceptions when getting the claim, e.g. during migrations
  BEGIN
    v_jwt := current_setting('request.jwt.claim', true);
  EXCEPTION
    WHEN OTHERS THEN
      v_jwt := NULL;
  END;

  -- Check which table the trigger is for and get the correct columns
  IF TG_TABLE_NAME = 'attention_service_evidences' OR TG_TABLE_NAME = 'attention_payment_evidences' THEN
    v_file_id := OLD.google_drive_file_id;
    v_tenant_id := OLD.tenant_id;
  -- Add other tables here in the future if needed
  -- ELSE IF TG_TABLE_NAME = 'some_other_table' THEN
  --   v_file_id := OLD.different_file_id_column;
  --   v_tenant_id := OLD.different_tenant_id_column;
  END IF;

  -- If there's no file ID, there's nothing to do
  IF v_file_id IS NULL THEN
    RETURN OLD;
  END IF;

  -- Asynchronously invoke the edge function to delete the file
  -- We don't want to block the transaction or roll it back if the delete fails.
  PERFORM net.http_post(
    url := 'https://zvzmnqcbmhpddrpfjrzr.supabase.co/functions/v1/google-drive-delete',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_jwt
    ),
    body := jsonb_build_object(
      'fileId', v_file_id,
      'tenantId', v_tenant_id
    )
  );

  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- Trigger for service evidences
CREATE TRIGGER on_service_evidence_deleted
AFTER DELETE ON public.attention_service_evidences
FOR EACH ROW
EXECUTE FUNCTION public.handle_google_drive_file_delete();

-- Trigger for payment evidences
CREATE TRIGGER on_payment_evidence_deleted
AFTER DELETE ON public.attention_payment_evidences
FOR EACH ROW
EXECUTE FUNCTION public.handle_google_drive_file_delete();
