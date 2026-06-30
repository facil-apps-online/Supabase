create or replace function get_tenant_storage_usage_by_table(p_tenant_id uuid)
returns table(table_name text, "size" bigint) as $$
begin
  return query
    select 'product_images' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from product_images where tenant_id = p_tenant_id
    union all
    select 'service_images' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from service_images where tenant_id = p_tenant_id
    union all
    select 'combo_images' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from combo_images where tenant_id = p_tenant_id
    union all
    select 'attention_service_evidences' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from attention_service_evidences where tenant_id = p_tenant_id
    union all
    select 'attention_payment_evidences' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from attention_payment_evidences where tenant_id = p_tenant_id
    union all
    select 'commission_payment_evidences' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from commission_payment_evidences where tenant_id = p_tenant_id
    union all
    select 'consent_signatures' as table_name, coalesce(sum(file_size), 0)::bigint as "size" from consent_signatures where tenant_id = p_tenant_id;
end;
$$ language plpgsql;
