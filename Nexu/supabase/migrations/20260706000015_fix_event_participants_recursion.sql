-- ==============================================================
-- Fix infinite recursion in event_participants policy
-- ==============================================================

-- Create a security definer function to safely check the event's tenant
-- without triggering RLS loops.
CREATE OR REPLACE FUNCTION public.check_event_tenant(p_event_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.events
    WHERE id = p_event_id
      AND (tenant_id = public.get_user_tenant_id(auth.uid()) OR public.is_super_admin(auth.uid()))
  );
$$;

-- Replace the problematic policy on event_participants
DROP POLICY IF EXISTS "Tenant isolation for event_participants" ON public.event_participants;

CREATE POLICY "Tenant isolation for event_participants" 
ON public.event_participants
FOR ALL
USING (public.check_event_tenant(event_id));
