DROP FUNCTION IF EXISTS get_tenant_storage_usage_by_table(uuid);
CREATE OR REPLACE FUNCTION get_tenant_storage_usage_by_table(p_tenant_id UUID)
RETURNS TABLE(category TEXT, table_name TEXT, "size" BIGINT) AS $$
BEGIN
  RETURN QUERY
    WITH storage_data AS (
      SELECT 
        'Productos y Servicios' AS category,
        'Productos' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT AS "size" 
      FROM product_images 
      WHERE tenant_id = p_tenant_id
      
      UNION ALL
      
      SELECT 
        'Productos y Servicios' AS category,
        'Servicios' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT 
      FROM service_images 
      WHERE tenant_id = p_tenant_id
      
      UNION ALL
      
      SELECT 
        'Productos y Servicios' AS category,
        'Combos' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT 
      FROM combo_images 
      WHERE tenant_id = p_tenant_id
      
      UNION ALL
      
      SELECT 
        'Productos y Servicios' AS category,
        'Tratamientos' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT 
      FROM treatment_images 
      WHERE tenant_id = p_tenant_id
      
      UNION ALL
      
      SELECT 
        'Otros' AS category,
        'Sucursales' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT 
      FROM branch_photos 
      WHERE tenant_id = p_tenant_id
      
      UNION ALL
      
      SELECT 
        'Evidencias' AS category,
        'Evidencias de Servicios' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT 
      FROM attention_service_evidences 
      WHERE tenant_id = p_tenant_id
      
      UNION ALL
      
      SELECT 
        'Evidencias' AS category,
        'Evidencias de Pagos' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT 
      FROM attention_payment_evidences 
      WHERE tenant_id = p_tenant_id
      
      UNION ALL
      
      SELECT 
        'Firmas' AS category,
        'Consentimientos' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT 
      FROM signed_consents 
      WHERE tenant_id = p_tenant_id

      UNION ALL
      
      SELECT 
        'Firmas' AS category,
        'Pagos' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT 
      FROM commission_payment_evidences 
      WHERE tenant_id = p_tenant_id
    )
    SELECT * FROM storage_data;
END;
$$ LANGUAGE plpgsql;