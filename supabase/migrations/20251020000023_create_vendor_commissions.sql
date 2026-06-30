CREATE TABLE public.vendor_platform_commissions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    platform_id uuid NOT NULL,
    first_payment_commission_rate numeric(5, 4) DEFAULT 0.50 NOT NULL,
    recurring_payment_commission_rate numeric(5, 4) DEFAULT 0.10 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT vendor_platform_commissions_pkey PRIMARY KEY (id),
    CONSTRAINT vendor_platform_commissions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE,
    CONSTRAINT vendor_platform_commissions_platform_id_fkey FOREIGN KEY (platform_id) REFERENCES public.platforms(id) ON DELETE CASCADE,
    CONSTRAINT vendor_platform_commissions_user_platform_unique UNIQUE (user_id, platform_id)
);

COMMENT ON TABLE public.vendor_platform_commissions IS 'Stores commission rates for vendors on specific platforms.';