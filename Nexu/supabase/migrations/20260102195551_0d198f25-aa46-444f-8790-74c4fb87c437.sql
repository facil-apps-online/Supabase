-- Create trigger function to sync is_super_admin when Administrador role is assigned/removed
CREATE OR REPLACE FUNCTION public.sync_super_admin_on_role_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    role_is_admin BOOLEAN;
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Check if the assigned role is the system "Administrador" role
        SELECT is_system INTO role_is_admin FROM public.roles WHERE id = NEW.role_id;
        
        IF role_is_admin = true THEN
            UPDATE public.profiles SET is_super_admin = true WHERE user_id = NEW.user_id;
        END IF;
        RETURN NEW;
        
    ELSIF TG_OP = 'DELETE' THEN
        -- Check if the removed role is the system "Administrador" role
        SELECT is_system INTO role_is_admin FROM public.roles WHERE id = OLD.role_id;
        
        IF role_is_admin = true THEN
            -- Only set to false if user has no other admin roles
            IF NOT EXISTS (
                SELECT 1 FROM public.user_roles ur
                JOIN public.roles r ON ur.role_id = r.id
                WHERE ur.user_id = OLD.user_id AND r.is_system = true AND ur.id != OLD.id
            ) THEN
                UPDATE public.profiles SET is_super_admin = false WHERE user_id = OLD.user_id;
            END IF;
        END IF;
        RETURN OLD;
    END IF;
    
    RETURN NULL;
END;
$$;

-- Create trigger on user_roles table
DROP TRIGGER IF EXISTS sync_super_admin_trigger ON public.user_roles;
CREATE TRIGGER sync_super_admin_trigger
    AFTER INSERT OR DELETE ON public.user_roles
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_super_admin_on_role_change();