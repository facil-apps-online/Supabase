-- Drop the existing trigger and function
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP FUNCTION IF EXISTS public.handle_new_user();

-- Create a new function that creates tenant AND profile
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER 
SET search_path = public
AS $$
DECLARE
    new_tenant_id uuid;
    user_email text;
    tenant_slug text;
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
    
    -- Create a default "Administrador" role for this tenant
    INSERT INTO public.roles (tenant_id, name, description, is_system)
    VALUES (new_tenant_id, 'Administrador', 'Rol de administrador con todos los permisos', true);
    
    RETURN NEW;
END;
$$;

-- Recreate the trigger
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();