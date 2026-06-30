-- Update the handle_new_user function to also assign the Administrador role to new users
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
    new_tenant_id uuid;
    user_email text;
    tenant_slug text;
    admin_role_id uuid;
BEGIN
    -- Get user email
    user_email := NEW.email;
    
    -- Generate a unique slug based on email (before @ symbol) + random suffix
    tenant_slug := LOWER(REGEXP_REPLACE(SPLIT_PART(user_email, '@', 1), '[^a-zA-Z0-9]', '', 'g')) || '-' || SUBSTRING(gen_random_uuid()::text, 1, 8);
    
    -- Create a new tenant for this user
    INSERT INTO public.tenants (name, slug)
    VALUES (
        COALESCE(NEW.raw_user_meta_data ->> 'first_name', 'Mi') || ' ' || 
        COALESCE(NEW.raw_user_meta_data ->> 'last_name', 'Empresa'),
        tenant_slug
    )
    RETURNING id INTO new_tenant_id;
    
    -- Create the profile with the tenant_id
    INSERT INTO public.profiles (user_id, email, first_name, last_name, tenant_id, is_super_admin)
    VALUES (
        NEW.id,
        user_email,
        NEW.raw_user_meta_data ->> 'first_name',
        NEW.raw_user_meta_data ->> 'last_name',
        new_tenant_id,
        false
    );
    
    -- Create a default "Administrador" role for this tenant and get its ID
    INSERT INTO public.roles (tenant_id, name, description, is_system)
    VALUES (new_tenant_id, 'Administrador', 'Rol de administrador con todos los permisos', true)
    RETURNING id INTO admin_role_id;
    
    -- Assign the Administrador role to the new user
    INSERT INTO public.user_roles (user_id, role_id)
    VALUES (NEW.id, admin_role_id);
    
    RETURN NEW;
END;
$function$;