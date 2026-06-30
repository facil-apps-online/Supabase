ALTER TABLE public.system_alerts
ADD CONSTRAINT fk_platform
FOREIGN KEY (platform_id)
REFERENCES public.platforms(id);