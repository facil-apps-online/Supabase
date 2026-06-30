DROP FUNCTION IF EXISTS get_tenant_storage_usage_by_table(uuid);
CREATE OR REPLACE FUNCTION get_tenant_storage_usage_by_table(p_tenant_id UUID)
RETURNS TABLE(category TEXT, table_name TEXT, "size" BIGINT, branch_id UUID) AS $$
DECLARE
  main_branch_id UUID;
BEGIN
  -- Find the main branch for the tenant
  SELECT id INTO main_branch_id FROM public.branches WHERE tenant_id = p_tenant_id AND is_main_branch = TRUE LIMIT 1;
  
  RETURN QUERY
    WITH storage_data AS (
      -- Tenant-wide assets attributed to the main branch
      SELECT 
        'Productos y Servicios' AS category,
        'Productos' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT AS "size",
        main_branch_id AS branch_id
      FROM product_images 
      WHERE tenant_id = p_tenant_id
      
      UNION ALL
      
      SELECT 
        'Productos y Servicios' AS category,
        'Servicios' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT,
        main_branch_id AS branch_id
      FROM service_images 
      WHERE tenant_id = p_tenant_id
      
      UNION ALL
      
      SELECT 
        'Productos y Servicios' AS category,
        'Combos' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT,
        main_branch_id AS branch_id
      FROM combo_images 
      WHERE tenant_id = p_tenant_id
      
      UNION ALL
      
      SELECT 
        'Productos y Servicios' AS category,
        'Tratamientos' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT,
        main_branch_id AS branch_id
      FROM treatment_images 
      WHERE tenant_id = p_tenant_id
      
      -- Branch-specific assets
      UNION ALL
      
      SELECT 
        'Otros' AS category,
        'Sucursales' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT,
        bp.branch_id
      FROM branch_photos bp
      WHERE bp.tenant_id = p_tenant_id
      GROUP BY bp.branch_id
      
      UNION ALL
      
      SELECT 
        'Evidencias' AS category,
        'Evidencias de Servicios' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT,
        ase.branch_id
      FROM attention_service_evidences ase
      WHERE ase.tenant_id = p_tenant_id
      GROUP BY ase.branch_id
      
      UNION ALL
      
      SELECT 
        'Evidencias' AS category,
        'Evidencias de Pagos' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT,
        ape.branch_id
      FROM attention_payment_evidences ape
      WHERE ape.tenant_id = p_tenant_id
      GROUP BY ape.branch_id
      
      UNION ALL
      
      SELECT 
        'Firmas' AS category,
        'Consentimientos' AS table_name, 
        coalesce(sum(cs.file_size), 0)::BIGINT,
        cs.branch_id
      FROM consent_signatures cs
      WHERE cs.tenant_id = p_tenant_id
      GROUP BY cs.branch_id

      UNION ALL
      
      SELECT 
        'Firmas' AS category,
        'Comisiones' AS table_name, 
        coalesce(sum(file_size), 0)::BIGINT,
        cpe.branch_id
      FROM commission_payment_evidences cpe
      WHERE cpe.tenant_id = p_tenant_id
      GROUP BY cpe.branch_id
    )
    SELECT category, table_name, "size", branch_id FROM storage_data WHERE "size" > 0;
END;
$$ LANGUAGE plpgsql;
