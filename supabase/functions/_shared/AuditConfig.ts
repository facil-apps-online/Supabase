// Definición de tipos para la configuración de auditoría

export interface TableAuditConfig {
  module: string; // Nombre funcional del módulo (ej: 'Clients', 'Inventory')
  labelField?: string; // Campo que identifica al registro (ej: 'full_name', 'name')
  
  // Configuración para entidades hijas
  parentTable?: string; // Nombre de la tabla padre (ej: 'clients')
  parentKey?: string;   // FK hacia el padre (ej: 'client_id')

  // Diccionario para traducir IDs a nombres legibles
  // Key: nombre de la columna FK en esta tabla (ej: 'document_type_id')
  // Value: 'tabla_destino.columna_mostrar' (ej: 'document_types.name')
  resolveKeys?: Record<string, string>;
}

export const AUDIT_CONFIG: Record<string, TableAuditConfig> = {
  // --- MÓDULO CLIENTES (Entidad Raíz) ---
  'clients': {
    module: 'Clients',
    labelField: 'full_name',
    resolveKeys: {
      'document_type_id': 'document_types.name',
      'tenant_id': 'tenants.name', 
    }
  },

  // --- SUB-ENTIDADES CLIENTES ---
  'client_addresses': {
    module: 'Clients',
    parentTable: 'clients',
    parentKey: 'client_id',
    resolveKeys: {
      'country_id': 'countries.name', // Asumiendo que existe en tenant o replicada
      'state_id': 'states.name'
    }
  },
  'client_contacts': {
    module: 'Clients',
    parentTable: 'clients',
    parentKey: 'client_id',
    resolveKeys: {
      'contact_type_id': 'contact_types.name'
    }
  },
  'client_branches': {
    module: 'Clients',
    parentTable: 'clients',
    parentKey: 'client_id',
    resolveKeys: {
      'branch_id': 'branches.name'
    }
  },
  'client_commercials': {
    module: 'Clients',
    parentTable: 'clients',
    parentKey: 'client_id',
    resolveKeys: {
      'user_id': 'users.first_name' // Vendedor asignado
    }
  },
  'client_professionals': {
    module: 'Clients',
    parentTable: 'clients',
    parentKey: 'client_id',
    resolveKeys: {
      'user_id': 'users.first_name' // Profesional preferido
    }
  },
  'client_consent_records': {
    module: 'Clients',
    parentTable: 'clients',
    parentKey: 'client_id',
    resolveKeys: {
      'template_id': 'informed_consent_templates.name'
    }
  },
  'client_document_instances': {
    module: 'Clients',
    parentTable: 'clients',
    parentKey: 'client_id',
    resolveKeys: {
      'template_id': 'client_document_templates.name'
    }
  },

  // --- TRATAMIENTOS DEL CLIENTE (Estructura Anidada) ---
  // Nota: Para logs anidados profundos, AuditService intentará resolver recursivamente si se configura bien.
  // Por ahora, lo mapeamos al módulo Clients.
  'client_treatments': {
    module: 'Clients', 
    parentTable: 'clients',
    parentKey: 'client_id',
    resolveKeys: {
      'prototype_id': 'treatments.name' // Tratamiento base
    }
  },
  'client_treatment_sessions': {
    module: 'Clients',
    parentTable: 'client_treatments', // Padre inmediato
    parentKey: 'client_treatment_id',
    // OJO: Para llegar al root (Client), AuditService necesitará lógica recursiva o un trigger de DB.
    // La versión actual de AuditService soporta 1 nivel de anidación.
    // Para simplificar, podemos asumir que si se modifica una sesión, el contexto ya tiene el client_id.
    resolveKeys: {
        'professional_id': 'users.first_name'
    }
  },

  // --- OTROS MÓDULOS ---
  'products': {
    module: 'Inventory',
    labelField: 'name',
    resolveKeys: {
      'category_id': 'product_categories.name',
      'brand_id': 'product_brands.name'
    }
  }
};