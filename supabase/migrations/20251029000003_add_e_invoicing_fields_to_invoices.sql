ALTER TABLE public.invoices
ADD COLUMN provider_reference_id TEXT,
ADD COLUMN error_message TEXT;

COMMENT ON COLUMN public.invoices.provider_reference_id IS 'Referencia del documento electrónico en el sistema del proveedor (ej. ID de la DIAN).';
COMMENT ON COLUMN public.invoices.error_message IS 'Mensaje de error si el envío del documento electrónico falló.';
