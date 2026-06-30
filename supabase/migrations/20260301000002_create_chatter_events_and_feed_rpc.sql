-- Migration: create_chatter_events_and_feed_rpc
-- Created at: 2026-03-01 00:00:02

-- 1. Create chatter_events table
CREATE TABLE IF NOT EXISTS public.chatter_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL,
    platform_id UUID NOT NULL,
    user_id UUID NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id UUID NOT NULL,
    event_type TEXT NOT NULL, -- e.g., 'field_update'
    payload JSONB NOT NULL,    -- Stores {field: 'name', old_value: 'A', new_value: 'B'}
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indices for performance
CREATE INDEX IF NOT EXISTS idx_chatter_events_resource ON public.chatter_events(resource_id, resource_type);
CREATE INDEX IF NOT EXISTS idx_chatter_events_tenant_platform ON public.chatter_events(tenant_id, platform_id);

-- 2. Create get_unified_chatter_feed RPC
-- This function joins comments and field update events
DROP FUNCTION IF EXISTS public.get_unified_chatter_feed(uuid, text);
CREATE OR REPLACE FUNCTION public.get_unified_chatter_feed(p_resource_id uuid, p_resource_type text)
 RETURNS TABLE(
    id uuid,
    event_type text,
    user_id uuid,
    content text,
    payload jsonb,
    created_at timestamp with time zone
 )
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
    RETURN QUERY
    (
        -- Comments
        SELECT 
            c.id, 
            'comment'::text as event_type, 
            c.user_id, 
            c.comment_text as content,
            NULL::jsonb as payload,
            c.created_at
        FROM public.chatter_comments c
        WHERE c.resource_id = p_resource_id AND c.resource_type = p_resource_type
        
        UNION ALL
        
        -- Field Update Events
        SELECT 
            e.id, 
            e.event_type, 
            e.user_id, 
            NULL::text as content,
            e.payload,
            e.created_at
        FROM public.chatter_events e
        WHERE e.resource_id = p_resource_id AND e.resource_type = p_resource_type
    )
    ORDER BY created_at DESC;
END;
$function$;
