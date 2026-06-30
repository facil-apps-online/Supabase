DROP FUNCTION IF EXISTS public.confirm_attention(p_attention_id uuid);

CREATE OR REPLACE FUNCTION public.confirm_attention(p_attention_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
  UPDATE public.attentions
  SET status = 'Confirmada', updated_at = now()
  WHERE id = p_attention_id;
END;
$function$;