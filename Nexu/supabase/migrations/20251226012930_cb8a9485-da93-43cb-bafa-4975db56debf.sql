-- =============================================
-- SISTEMA SaaS MULTITENANT DE RRHH
-- Migración inicial: Estructura core
-- =============================================

-- 1. ENUM TYPES
CREATE TYPE public.app_role AS ENUM ('super_admin', 'tenant_admin', 'user');
CREATE TYPE public.permission_action AS ENUM ('ver', 'crear', 'editar', 'eliminar', 'firmar', 'aprobar');
CREATE TYPE public.exam_status AS ENUM ('pendiente', 'vigente', 'vencido', 'proximo_vencer');
CREATE TYPE public.course_status AS ENUM ('pendiente', 'en_progreso', 'completado', 'vencido');
CREATE TYPE public.vigilancia_status AS ENUM ('activa', 'inactiva', 'vencida');
CREATE TYPE public.evaluation_status AS ENUM ('pendiente', 'en_proceso', 'completada', 'cancelada');
CREATE TYPE public.communication_type AS ENUM ('circular', 'memorando', 'notificacion', 'alerta');
CREATE TYPE public.communication_status AS ENUM ('borrador', 'enviado', 'leido');

-- 2. TENANTS (Empresas)
CREATE TABLE public.tenants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    logo_url TEXT,
    settings JSONB DEFAULT '{}',
    active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- 3. PROFILES (Usuarios del sistema)
CREATE TABLE public.profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    tenant_id UUID REFERENCES public.tenants(id) ON DELETE CASCADE,
    first_name TEXT,
    last_name TEXT,
    email TEXT NOT NULL,
    phone TEXT,
    avatar_url TEXT,
    is_super_admin BOOLEAN DEFAULT false,
    active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(user_id)
);

-- 4. MODULES (Módulos del sistema)
CREATE TABLE public.modules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    description TEXT,
    icon TEXT,
    active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- Insert default modules
INSERT INTO public.modules (code, name, description, icon) VALUES
    ('empleados', 'Empleados', 'Gestión de empleados', 'Users'),
    ('examenes', 'Exámenes Médicos', 'Control de exámenes ocupacionales', 'Stethoscope'),
    ('cursos', 'Cursos y Capacitaciones', 'Gestión de formación', 'GraduationCap'),
    ('vigilancias', 'Vigilancias Epidemiológicas', 'Seguimiento epidemiológico', 'Activity'),
    ('dotacion', 'Dotación EPP', 'Elementos de protección personal', 'HardHat'),
    ('comites', 'Comités', 'Gestión de comités SST', 'Users2'),
    ('evaluaciones_desempeno', 'Evaluaciones de Desempeño', 'Evaluaciones de rendimiento', 'ClipboardCheck'),
    ('evaluaciones_competencias', 'Evaluaciones de Competencias', 'Evaluación de habilidades', 'Target'),
    ('comunicaciones', 'Comunicaciones', 'Circulares y memorandos', 'Mail');

-- 5. PERMISSIONS (Permisos base)
CREATE TABLE public.permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    module_id UUID NOT NULL REFERENCES public.modules(id) ON DELETE CASCADE,
    action permission_action NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(module_id, action)
);

-- Insert default permissions for each module
INSERT INTO public.permissions (module_id, action, description)
SELECT m.id, a.action, m.name || ' - ' || a.action::text
FROM public.modules m
CROSS JOIN (
    SELECT unnest(enum_range(NULL::permission_action)) as action
) a;

-- 6. ROLES (Roles por tenant)
CREATE TABLE public.roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    is_system BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(tenant_id, name)
);

-- 7. ROLE_PERMISSIONS (Permisos asignados a roles)
CREATE TABLE public.role_permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
    permission_id UUID NOT NULL REFERENCES public.permissions(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(role_id, permission_id)
);

-- 8. USER_ROLES (Roles asignados a usuarios)
CREATE TABLE public.user_roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(user_id, role_id)
);

-- 9. USER_PERMISSIONS (Permisos individuales adicionales)
CREATE TABLE public.user_permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    permission_id UUID NOT NULL REFERENCES public.permissions(id) ON DELETE CASCADE,
    granted BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(user_id, permission_id)
);

-- 10. EMPLOYEES (Empleados)
CREATE TABLE public.employees (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    document_type TEXT NOT NULL DEFAULT 'CC',
    document_number TEXT NOT NULL,
    first_name TEXT NOT NULL,
    last_name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    position TEXT,
    department TEXT,
    hire_date DATE,
    birth_date DATE,
    address TEXT,
    city TEXT,
    emergency_contact TEXT,
    emergency_phone TEXT,
    photo_url TEXT,
    active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(tenant_id, document_number)
);

-- 11. EXAMS (Exámenes médicos)
CREATE TABLE public.exams (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
    exam_type TEXT NOT NULL,
    exam_date DATE NOT NULL,
    expiry_date DATE,
    result TEXT,
    observations TEXT,
    document_url TEXT,
    status exam_status DEFAULT 'pendiente',
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- 12. COURSES (Cursos y capacitaciones)
CREATE TABLE public.courses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
    course_name TEXT NOT NULL,
    provider TEXT,
    start_date DATE NOT NULL,
    end_date DATE,
    duration_hours INTEGER,
    expiry_date DATE,
    certificate_url TEXT,
    status course_status DEFAULT 'pendiente',
    grade NUMERIC(5,2),
    observations TEXT,
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- 13. VIGILANCIAS (Vigilancias epidemiológicas)
CREATE TABLE public.vigilancias (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
    vigilancia_type TEXT NOT NULL,
    diagnosis TEXT,
    start_date DATE NOT NULL,
    end_date DATE,
    follow_up_date DATE,
    recommendations TEXT,
    restrictions TEXT,
    status vigilancia_status DEFAULT 'activa',
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- 14. DOTACION (Elementos de protección)
CREATE TABLE public.dotacion (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
    item_name TEXT NOT NULL,
    item_type TEXT,
    quantity INTEGER DEFAULT 1,
    delivery_date DATE NOT NULL,
    expiry_date DATE,
    size TEXT,
    signature_url TEXT,
    observations TEXT,
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- 15. COMMITTEES (Comités SST)
CREATE TABLE public.committees (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    start_date DATE NOT NULL,
    end_date DATE,
    active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- 16. COMMITTEE_MEMBERS (Miembros de comités)
CREATE TABLE public.committee_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    committee_id UUID NOT NULL REFERENCES public.committees(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    start_date DATE,
    end_date DATE,
    active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(committee_id, employee_id)
);

-- 17. COMMITTEE_MEETINGS (Reuniones de comités)
CREATE TABLE public.committee_meetings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    committee_id UUID NOT NULL REFERENCES public.committees(id) ON DELETE CASCADE,
    meeting_date TIMESTAMPTZ NOT NULL,
    location TEXT,
    agenda TEXT,
    minutes TEXT,
    attendees UUID[],
    document_url TEXT,
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- 18. PERFORMANCE_EVALUATIONS (Evaluaciones de desempeño)
CREATE TABLE public.performance_evaluations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
    evaluator_id UUID REFERENCES public.employees(id),
    period TEXT NOT NULL,
    evaluation_date DATE NOT NULL,
    overall_score NUMERIC(5,2),
    strengths TEXT,
    areas_improvement TEXT,
    goals TEXT,
    comments TEXT,
    status evaluation_status DEFAULT 'pendiente',
    employee_signature_url TEXT,
    evaluator_signature_url TEXT,
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- 19. COMPETENCY_EVALUATIONS (Evaluaciones de competencias)
CREATE TABLE public.competency_evaluations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
    evaluator_id UUID REFERENCES public.employees(id),
    competency_name TEXT NOT NULL,
    evaluation_date DATE NOT NULL,
    expected_level INTEGER NOT NULL,
    actual_level INTEGER NOT NULL,
    gap INTEGER GENERATED ALWAYS AS (expected_level - actual_level) STORED,
    action_plan TEXT,
    status evaluation_status DEFAULT 'pendiente',
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- 20. COMMUNICATIONS (Comunicaciones internas)
CREATE TABLE public.communications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    communication_type communication_type NOT NULL,
    subject TEXT NOT NULL,
    content TEXT NOT NULL,
    priority TEXT DEFAULT 'normal',
    recipients UUID[],
    attachment_urls TEXT[],
    status communication_status DEFAULT 'borrador',
    sent_at TIMESTAMPTZ,
    created_by UUID REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- 21. COMMUNICATION_READS (Lecturas de comunicaciones)
CREATE TABLE public.communication_reads (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    communication_id UUID NOT NULL REFERENCES public.communications(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    read_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(communication_id, user_id)
);

-- 22. NOTIFICATIONS (Notificaciones del sistema)
CREATE TABLE public.notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES public.tenants(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    message TEXT NOT NULL,
    type TEXT DEFAULT 'info',
    link TEXT,
    read BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- 23. AUDIT_LOG (Registro de auditoría)
CREATE TABLE public.audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID REFERENCES public.tenants(id) ON DELETE SET NULL,
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    table_name TEXT NOT NULL,
    record_id UUID,
    old_data JSONB,
    new_data JSONB,
    ip_address TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- =============================================
-- FUNCTIONS
-- =============================================

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Function to check if user has a specific role
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE user_id = _user_id
        AND (
            (_role = 'super_admin' AND is_super_admin = true)
            OR EXISTS (
                SELECT 1 FROM public.user_roles ur
                JOIN public.roles r ON ur.role_id = r.id
                WHERE ur.user_id = _user_id
            )
        )
    )
$$;

-- Function to check if user is super admin
CREATE OR REPLACE FUNCTION public.is_super_admin(_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE user_id = _user_id AND is_super_admin = true
    )
$$;

-- Function to get user's tenant_id
CREATE OR REPLACE FUNCTION public.get_user_tenant_id(_user_id UUID)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT tenant_id FROM public.profiles WHERE user_id = _user_id LIMIT 1
$$;

-- Function to check user permission
CREATE OR REPLACE FUNCTION public.has_permission(_user_id UUID, _module_code TEXT, _action permission_action)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        -- Super admin has all permissions
        SELECT 1 FROM public.profiles WHERE user_id = _user_id AND is_super_admin = true
        UNION ALL
        -- Check role permissions
        SELECT 1 FROM public.user_roles ur
        JOIN public.role_permissions rp ON ur.role_id = rp.role_id
        JOIN public.permissions p ON rp.permission_id = p.id
        JOIN public.modules m ON p.module_id = m.id
        WHERE ur.user_id = _user_id AND m.code = _module_code AND p.action = _action
        UNION ALL
        -- Check individual permissions (granted)
        SELECT 1 FROM public.user_permissions up
        JOIN public.permissions p ON up.permission_id = p.id
        JOIN public.modules m ON p.module_id = m.id
        WHERE up.user_id = _user_id AND m.code = _module_code AND p.action = _action AND up.granted = true
    )
    AND NOT EXISTS (
        -- Check individual permissions (revoked)
        SELECT 1 FROM public.user_permissions up
        JOIN public.permissions p ON up.permission_id = p.id
        JOIN public.modules m ON p.module_id = m.id
        WHERE up.user_id = _user_id AND m.code = _module_code AND p.action = _action AND up.granted = false
    )
$$;

-- Function to handle new user signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.profiles (user_id, email, first_name, last_name)
    VALUES (
        NEW.id,
        NEW.email,
        NEW.raw_user_meta_data ->> 'first_name',
        NEW.raw_user_meta_data ->> 'last_name'
    );
    RETURN NEW;
END;
$$;

-- Trigger for new user signup
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- =============================================
-- TRIGGERS FOR updated_at
-- =============================================

CREATE TRIGGER update_tenants_updated_at BEFORE UPDATE ON public.tenants FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_roles_updated_at BEFORE UPDATE ON public.roles FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_employees_updated_at BEFORE UPDATE ON public.employees FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_exams_updated_at BEFORE UPDATE ON public.exams FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_courses_updated_at BEFORE UPDATE ON public.courses FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_vigilancias_updated_at BEFORE UPDATE ON public.vigilancias FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_dotacion_updated_at BEFORE UPDATE ON public.dotacion FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_committees_updated_at BEFORE UPDATE ON public.committees FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_committee_meetings_updated_at BEFORE UPDATE ON public.committee_meetings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_performance_evaluations_updated_at BEFORE UPDATE ON public.performance_evaluations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_competency_evaluations_updated_at BEFORE UPDATE ON public.competency_evaluations FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_communications_updated_at BEFORE UPDATE ON public.communications FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

-- =============================================
-- ROW LEVEL SECURITY
-- =============================================

-- Enable RLS on all tables
ALTER TABLE public.tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.modules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exams ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.courses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vigilancias ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dotacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.committees ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.committee_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.committee_meetings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.performance_evaluations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.competency_evaluations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.communications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.communication_reads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

-- TENANTS policies
CREATE POLICY "Super admins can manage all tenants" ON public.tenants
    FOR ALL USING (public.is_super_admin(auth.uid()));

CREATE POLICY "Users can view their own tenant" ON public.tenants
    FOR SELECT USING (id = public.get_user_tenant_id(auth.uid()));

-- PROFILES policies
CREATE POLICY "Users can view own profile" ON public.profiles
    FOR SELECT USING (user_id = auth.uid());

CREATE POLICY "Users can update own profile" ON public.profiles
    FOR UPDATE USING (user_id = auth.uid());

CREATE POLICY "Super admins can manage all profiles" ON public.profiles
    FOR ALL USING (public.is_super_admin(auth.uid()));

CREATE POLICY "Tenant admins can view tenant profiles" ON public.profiles
    FOR SELECT USING (tenant_id = public.get_user_tenant_id(auth.uid()));

-- MODULES policies (read-only for all authenticated users)
CREATE POLICY "Authenticated users can view modules" ON public.modules
    FOR SELECT TO authenticated USING (true);

-- PERMISSIONS policies (read-only for all authenticated users)
CREATE POLICY "Authenticated users can view permissions" ON public.permissions
    FOR SELECT TO authenticated USING (true);

-- ROLES policies
CREATE POLICY "Super admins can manage all roles" ON public.roles
    FOR ALL USING (public.is_super_admin(auth.uid()));

CREATE POLICY "Tenant admins can manage their roles" ON public.roles
    FOR ALL USING (tenant_id = public.get_user_tenant_id(auth.uid()));

-- ROLE_PERMISSIONS policies
CREATE POLICY "Super admins can manage all role permissions" ON public.role_permissions
    FOR ALL USING (public.is_super_admin(auth.uid()));

CREATE POLICY "Users can view role permissions for their tenant" ON public.role_permissions
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.roles r
            WHERE r.id = role_id AND r.tenant_id = public.get_user_tenant_id(auth.uid())
        )
    );

-- USER_ROLES policies
CREATE POLICY "Super admins can manage all user roles" ON public.user_roles
    FOR ALL USING (public.is_super_admin(auth.uid()));

CREATE POLICY "Users can view their own roles" ON public.user_roles
    FOR SELECT USING (user_id = auth.uid());

-- USER_PERMISSIONS policies
CREATE POLICY "Super admins can manage all user permissions" ON public.user_permissions
    FOR ALL USING (public.is_super_admin(auth.uid()));

CREATE POLICY "Users can view their own permissions" ON public.user_permissions
    FOR SELECT USING (user_id = auth.uid());

-- EMPLOYEES policies
CREATE POLICY "Users can view employees in their tenant" ON public.employees
    FOR SELECT USING (tenant_id = public.get_user_tenant_id(auth.uid()));

CREATE POLICY "Users with permission can manage employees" ON public.employees
    FOR ALL USING (
        tenant_id = public.get_user_tenant_id(auth.uid())
        AND (
            public.is_super_admin(auth.uid())
            OR public.has_permission(auth.uid(), 'empleados', 'crear')
            OR public.has_permission(auth.uid(), 'empleados', 'editar')
            OR public.has_permission(auth.uid(), 'empleados', 'eliminar')
        )
    );

-- Generic tenant-based policies for operational tables
CREATE POLICY "Tenant isolation for exams" ON public.exams
    FOR ALL USING (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()));

CREATE POLICY "Tenant isolation for courses" ON public.courses
    FOR ALL USING (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()));

CREATE POLICY "Tenant isolation for vigilancias" ON public.vigilancias
    FOR ALL USING (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()));

CREATE POLICY "Tenant isolation for dotacion" ON public.dotacion
    FOR ALL USING (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()));

CREATE POLICY "Tenant isolation for committees" ON public.committees
    FOR ALL USING (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()));

CREATE POLICY "Tenant isolation for committee_members" ON public.committee_members
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.committees c
            WHERE c.id = committee_id AND (c.tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()))
        )
    );

CREATE POLICY "Tenant isolation for committee_meetings" ON public.committee_meetings
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.committees c
            WHERE c.id = committee_id AND (c.tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()))
        )
    );

CREATE POLICY "Tenant isolation for performance_evaluations" ON public.performance_evaluations
    FOR ALL USING (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()));

CREATE POLICY "Tenant isolation for competency_evaluations" ON public.competency_evaluations
    FOR ALL USING (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()));

CREATE POLICY "Tenant isolation for communications" ON public.communications
    FOR ALL USING (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()));

CREATE POLICY "Users can manage own communication reads" ON public.communication_reads
    FOR ALL USING (user_id = auth.uid());

CREATE POLICY "Tenant isolation for notifications" ON public.notifications
    FOR ALL USING (user_id = auth.uid() OR public.is_super_admin(auth.uid()));

CREATE POLICY "Super admins can view all audit logs" ON public.audit_log
    FOR SELECT USING (public.is_super_admin(auth.uid()));

CREATE POLICY "Users can view their tenant audit logs" ON public.audit_log
    FOR SELECT USING (tenant_id = public.get_user_tenant_id(auth.uid()));