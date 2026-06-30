CREATE OR REPLACE FUNCTION get_payslip_details(p_payslip_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_tenant_id uuid;
  v_payslip_user_id uuid;
  v_tenant_info jsonb;
  v_payslip_info jsonb;
  v_professional_info jsonb;
  v_commissions jsonb;
  v_signature_info jsonb;
  v_result jsonb;
BEGIN
  -- Get tenant_id and user_id from the payslip
  SELECT tenant_id, user_id INTO v_tenant_id, v_payslip_user_id FROM public.payslips WHERE id = p_payslip_id;

  -- Get tenant info (logo)
  SELECT jsonb_build_object('logo_url', logo_url) INTO v_tenant_info FROM public.tenants WHERE id = v_tenant_id;

  -- Get payslip info
  SELECT to_jsonb(p.*) INTO v_payslip_info FROM public.payslips p WHERE id = p_payslip_id;

  -- Get professional info
  SELECT jsonb_build_object(
    'first_name', u.raw_user_meta_data->>'first_name',
    'last_name', u.raw_user_meta_data->>'last_name',
    'email', u.email
  )
  INTO v_professional_info
  FROM auth.users u
  WHERE u.id = v_payslip_user_id;

  -- Get signature info
  SELECT jsonb_build_object('google_drive_file_id', cpe.google_drive_file_id)
  INTO v_signature_info
  FROM public.commission_payment_evidences cpe
  WHERE cpe.payslip_id = p_payslip_id
  ORDER BY cpe.created_at DESC
  LIMIT 1;

  -- Get commission details
  WITH commissions_base AS (
    SELECT 
      ec.id,
      ec.created_at AS attention_date,
      ec.item_name,
      ec.item_price AS attention_value,
      ec.commission_amount,
      ec.attention_service_id,
      ec.attention_product_id
    FROM public.payslip_commissions pc
    JOIN public.earned_commissions ec ON pc.commission_id = ec.id
    WHERE pc.payslip_id = p_payslip_id
  )
  SELECT jsonb_agg(jsonb_build_object(
    'attention_date', cb.attention_date,
    'client_name', COALESCE(cl_serv.name, cl_prod.name),
    'attention_value', cb.attention_value,
    'commission_amount', cb.commission_amount
  ))
  INTO v_commissions
  FROM commissions_base cb
  LEFT JOIN public.attention_services aserv ON cb.attention_service_id = aserv.id
  LEFT JOIN public.attentions a_serv ON aserv.attention_id = a_serv.id
  LEFT JOIN public.clients cl_serv ON a_serv.client_id = cl_serv.id
  LEFT JOIN public.attention_products aprod ON cb.attention_product_id = aprod.id
  LEFT JOIN public.attentions a_prod ON aprod.attention_id = a_prod.id
  LEFT JOIN public.clients cl_prod ON a_prod.client_id = cl_prod.id;

  -- Combine all information
  v_result := jsonb_build_object(
    'tenant', v_tenant_info,
    'payslip', v_payslip_info,
    'professional', v_professional_info,
    'signature', v_signature_info,
    'commissions', v_commissions
  );

  RETURN v_result;
END;
$$;