DROP FUNCTION IF EXISTS public.get_attentions_with_details(uuid, uuid, uuid, text, date, date);

CREATE OR REPLACE FUNCTION public.get_attentions_with_details(p_tenant_id uuid, p_branch_id uuid, p_user_id uuid, p_status_filter text, p_start_date date, p_end_date date)
 RETURNS TABLE(id uuid, created_at timestamp with time zone, tenant_id uuid, branch_id uuid, client_id uuid, attention_datetime timestamp with time zone, status text, notes text, informed_consent_id uuid, clients json, attention_services json, attention_products json, attention_combos json, attention_payments json)
 LANGUAGE plpgsql
AS $function$
BEGIN
  RETURN QUERY
  WITH tenant_users AS (
    SELECT * FROM get_tenant_users(p_tenant_id)
  ),
  attentions_filtered AS (
    SELECT
      a.id, a.created_at, a.tenant_id, a.branch_id, a.client_id, a.attention_datetime, a.status, a.notes, sc.id as informed_consent_id
    FROM public.attentions a
    LEFT JOIN public.signed_consents sc ON a.id = sc.attention_id
    WHERE
      a.tenant_id = p_tenant_id
      AND (p_branch_id IS NULL OR a.branch_id = p_branch_id)
      AND (p_status_filter IS NULL OR a.status = p_status_filter)
      AND (a.attention_datetime::date BETWEEN p_start_date AND p_end_date)
      AND (p_user_id IS NULL OR EXISTS (
        SELECT 1 FROM public.attention_services aserv WHERE aserv.attention_id = a.id AND aserv.user_id = p_user_id
      ))
  )
  SELECT
    af.id, af.created_at, af.tenant_id, af.branch_id, af.client_id, af.attention_datetime, af.status, af.notes, af.informed_consent_id,
    (SELECT json_build_object('id', c.id, 'name', c.name, 'phone', c.phone) FROM public.clients c WHERE c.id = af.client_id LIMIT 1) as clients,
    
    (SELECT json_agg(json_build_object(
        'id', aserv.id, 
        'service_id', aserv.service_id, 
        'user_id', aserv.user_id, 
        'service_price', aserv.service_price, 
        'notes', aserv.notes, 
        'status', aserv.status, 
        'attention_combo_id', aserv.combo_id,
        'is_parallel', aserv.is_parallel,
        'offset_minutes', aserv.offset_minutes,
        'duration_minutes', aserv.duration_minutes,
        'services', (SELECT json_build_object('id', s.id, 'name', s.name) FROM public.services s WHERE s.id = aserv.service_id),
        'users', (SELECT json_build_object('first_name', tu.first_name, 'last_name', tu.last_name) FROM tenant_users tu WHERE tu.user_id = aserv.user_id LIMIT 1),
        'status_history', (SELECT json_agg(h.*) FROM public.attention_service_status_history h WHERE h.attention_service_id = aserv.id),
        'survey_rating', (
          SELECT json_build_object('rating', ssr.rating, 'comments', ssr.comments)
          FROM public.satisfaction_surveys ss
          JOIN public.satisfaction_survey_ratings ssr ON ss.id = ssr.survey_id
          WHERE ss.attention_id = af.id AND ssr.attention_service_id = aserv.id
          LIMIT 1
        )
    )) 
    FROM public.attention_services aserv 
    WHERE aserv.attention_id = af.id) as attention_services,
    
    (SELECT json_agg(json_build_object(
        'id', ap.id, 
        'product_id', ap.product_id, 
        'user_id', ap.user_id, 
        'quantity', ap.quantity, 
        'unit_price', ap.unit_price, 
        'total_price', ap.total_price, 
        'attention_combo_id', ap.combo_id,
        'products', (SELECT json_build_object('id', p.id, 'name', p.name) FROM public.products p WHERE p.id = ap.product_id),
        'users', (SELECT json_build_object('first_name', tu.first_name, 'last_name', tu.last_name) FROM tenant_users tu WHERE tu.user_id = ap.user_id LIMIT 1)
    )) 
    FROM public.attention_products ap WHERE ap.attention_id = af.id) as attention_products,
    
    (SELECT json_agg(json_build_object(
        'id', ac.id, 
        'combo_id', ac.combo_id, 
        'price', ac.price, 
        'quantity', ac.quantity, 
        'status', ac.status,
        'combos', (SELECT json_build_object(
            'id', c.id, 
            'name', c.name,
            'duration_minutes', (SELECT SUM(s.duration_minutes) FROM public.combo_items ci JOIN public.services s ON ci.service_id = s.id WHERE ci.combo_id = c.id),
            'combo_items', (SELECT json_agg(json_build_object(
                'id', ci.id, 
                'product_id', ci.product_id, 
                'service_id', ci.service_id, 
                'quantity', ci.quantity, 
                'product', (SELECT json_build_object('name', p.name) FROM public.products p WHERE p.id = ci.product_id), 
                'service', (SELECT json_build_object('name', s.name, 'duration_minutes', s.duration_minutes) FROM public.services s WHERE s.id = ci.service_id)
            )) 
            FROM public.combo_items ci WHERE ci.combo_id = c.id)
        ) 
        FROM public.combos c WHERE c.id = ac.combo_id AND c.tenant_id = af.tenant_id)
    )) 
    FROM public.attention_combos ac WHERE ac.attention_id = af.id) as attention_combos,

    (SELECT json_agg(DISTINCT ap.*)
    FROM public.attention_payments ap WHERE ap.attention_id = af.id) as attention_payments

  FROM attentions_filtered af;
END;
$function$;
