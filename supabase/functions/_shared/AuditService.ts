import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { AUDIT_CONFIG } from './AuditConfig.ts';

export class AuditService {
  
  /**
   * Registra un cambio en el sistema de auditoría centralizado (Core).
   * Maneja automáticamente la resolución de nombres, agrupación por módulos y usuarios.
   */
  static async logChange(
    tenantSupabase: SupabaseClient,
    coreSupabase: SupabaseClient,
    params: {
      tenantId: string;
      userId: string;
      branchId?: string; // Opcional
      action: 'INSERT' | 'UPDATE' | 'DELETE';
      table: string;
      recordId: string;
      oldRecord?: any;
      newRecord?: any;
      ipAddress?: string;
      userAgent?: string;
    }
  ) {
    try {
      const { tenantId, userId, branchId, action, table, recordId, oldRecord, newRecord } = params;
      const config = AUDIT_CONFIG[table];

      // 1. Resolver Datos del Usuario (Nombre)
      const userName = await this.resolveUserName(tenantSupabase, userId);

      // 2. Determinar Entidad Raíz (Padre)
      // Si no hay configuración o no tiene padre, la entidad raíz es ella misma.
      let rootEntityType = table;
      let rootEntityId = recordId;

      if (config && config.parentTable && config.parentKey) {
        rootEntityType = config.parentTable;
        // Si es INSERT/UPDATE, el ID del padre viene en el newRecord
        // Si es DELETE, viene en el oldRecord
        const sourceRecord = newRecord || oldRecord;
        if (sourceRecord && sourceRecord[config.parentKey]) {
          rootEntityId = sourceRecord[config.parentKey];
        }
      }

      // 3. Preparar Diff "Amigable" (Resolver FKs)
      const { friendlyOld, friendlyNew } = await this.resolveFriendlyValues(
        tenantSupabase, 
        table, 
        oldRecord, 
        newRecord
      );

      // 4. Enviar a Core RPC
      const { error } = await coreSupabase.rpc('log_audit_action_core', {
        p_tenant_id: tenantId,
        p_user_id: userId,
        p_user_name: userName,
        p_branch_id: branchId,
        p_action: action,
        p_module: config?.module || 'General', // Default module
        p_entity_type: table,
        p_entity_id: recordId,
        p_root_entity_type: rootEntityType,
        p_root_entity_id: rootEntityId,
        p_old_value: friendlyOld,
        p_new_value: friendlyNew,
        p_metadata: null, // Podríamos pasar extra data si fuera necesario
        p_ip_address: params.ipAddress || null,
        p_user_agent: params.userAgent || null
      });

      if (error) {
        console.error(`[Audit] Failed to log to Core: ${error.message}`);
      }

    } catch (e) {
      console.error(`[Audit] Exception: ${e.message}`);
      // No re-lanzamos el error para no bloquear la transacción principal
    }
  }

  // --- Helpers Privados ---

  private static async resolveUserName(client: SupabaseClient, userId: string): Promise<string> {
    if (!userId) return 'System';
    
    // Intentamos buscar en tabla 'users' (si existe en el tenant, usualmente es un view o tabla sincronizada)
    // OJO: Si usas auth.users directo no podrás consultarlo con el cliente público. 
    // Asumimos que hay una tabla 'users' o 'user_profiles' pública en el Tenant.
    // Si no, tendremos que usar un RPC 'get_user_name' en el tenant.
    
    try {
        // Opción A: Tabla pública 'users' (común en tu arquitectura)
        const { data, error } = await client
            .from('users')
            .select('first_name, last_name')
            .eq('id', userId)
            .single();
            
        if (!error && data) {
            return `${data.first_name || ''} ${data.last_name || ''}`.trim() || 'Unknown User';
        }
    } catch (e) { /* ignore */ }

    return 'Unknown User'; 
  }

  private static async resolveFriendlyValues(
    client: SupabaseClient,
    table: string,
    oldRec: any,
    newRec: any
  ): Promise<{ friendlyOld: any, friendlyNew: any }> {
    const config = AUDIT_CONFIG[table];
    if (!config || !config.resolveKeys) {
        return { friendlyOld: oldRec, friendlyNew: newRec };
    }

    const friendlyOld = oldRec ? { ...oldRec } : null;
    const friendlyNew = newRec ? { ...newRec } : null;
    
    const keysToResolve = Object.keys(config.resolveKeys);

    for (const key of keysToResolve) {
        const targetDef = config.resolveKeys[key]; // "table.column"
        const [targetTable, targetCol] = targetDef.split('.');

        // Optimización: Solo resolver si el valor cambió o si es un INSERT
        const valOld = oldRec ? oldRec[key] : undefined;
        const valNew = newRec ? newRec[key] : undefined;

        if (valOld !== valNew) {
            // Resolver Old
            if (valOld) {
                const label = await this.fetchLabel(client, targetTable, targetCol, valOld);
                if (friendlyOld) friendlyOld[`${key}_label`] = label;
            }
            // Resolver New
            if (valNew) {
                const label = await this.fetchLabel(client, targetTable, targetCol, valNew);
                if (friendlyNew) friendlyNew[`${key}_label`] = label;
            }
        }
    }

    return { friendlyOld, friendlyNew };
  }

  private static async fetchLabel(
    client: SupabaseClient, 
    table: string, 
    col: string, 
    id: string
  ): Promise<string | null> {
      try {
          const { data } = await client
            .from(table)
            .select(col)
            .eq('id', id)
            .single();
          return data ? data[col] : null;
      } catch {
          return null;
      }
  }
}
