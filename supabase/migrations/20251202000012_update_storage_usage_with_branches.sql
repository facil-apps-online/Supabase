create or replace function get_tenant_storage_usage_by_table(p_tenant_id uuid)
returns table(table_name text, "size" bigint) as $$
begin
  return query
    select 'Productos' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from product_images where tenant_id = p_tenant_id
    union all
    select 'Servicios' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from service_images where tenant_id = p_tenant_id
    union all
    select 'Combos' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from combo_images where tenant_id = p_tenant_id
    union all
    select 'Sucursales' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from branch_photos where tenant_id = p_tenant_id
    union all
    select 'Evidencias de Servicios' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from attention_service_evidences where tenant_id = p_tenant_id
    union all
    select 'Evidencias de Pagos' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from attention_payment_evidences where tenant_id = p_tenant_id
    union all
    select 'Evidencias de Liquidaciones' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from commission_payment_evidences where tenant_id = p_tenant_id
    union all
    select 'Consentimientos' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from consent_signatures where tenant_id = p_tenant_id;
end;
$$ language plpgsql;
