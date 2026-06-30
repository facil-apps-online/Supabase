ALTER TABLE public.platforms
ADD COLUMN default_currency_id UUID NULL REFERENCES public.currencies(id),
ADD COLUMN default_language_id UUID NULL REFERENCES public.languages(id);