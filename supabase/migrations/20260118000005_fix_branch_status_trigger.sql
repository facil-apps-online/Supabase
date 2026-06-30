-- Drop the problematic trigger
DROP TRIGGER IF EXISTS trg_branch_status_change ON public.branches;

-- Create the fixed trigger function
CREATE OR REPLACE FUNCTION public.log_branch_status_change_v2()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    IF (TG_OP = 'INSERT') OR (TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status) THEN
        INSERT INTO public.branch_status_history (
            branch_id,
            status,
            changed_at,
            changed_by,
            tenant_id,
            platform_id
        ) VALUES (
            NEW.id,
            NEW.status,
            now(),
            auth.uid(), -- Will be null if invoked by system without auth context, which is fine as it is nullable
            NEW.tenant_id,
            NEW.platform_id
        );
    END IF;
    RETURN NEW;
END;
$function$
;

ALTER FUNCTION public.log_branch_status_change_v2() OWNER TO postgres;

-- Recreate the trigger
CREATE TRIGGER trg_branch_status_change
AFTER INSERT OR UPDATE OF status ON public.branches
FOR EACH ROW
EXECUTE FUNCTION public.log_branch_status_change_v2();
