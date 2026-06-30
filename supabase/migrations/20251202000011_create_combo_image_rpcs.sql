-- RPC to get images for a specific combo
CREATE OR REPLACE FUNCTION public.get_combo_images(p_combo_id uuid)
RETURNS SETOF public.combo_images
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT *
    FROM public.combo_images
    WHERE combo_id = p_combo_id
    ORDER BY is_primary DESC, sort_order ASC;
END;
$$;

-- RPC to delete an image from a combo
CREATE OR REPLACE FUNCTION public.delete_combo_image(p_image_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM public.combo_images WHERE id = p_image_id;
END;
$$;

-- RPC to set an image as the primary one for a combo
CREATE OR REPLACE FUNCTION public.set_primary_combo_image(
    p_combo_id uuid,
    p_image_id uuid
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- First, set all other images for this combo to not be primary
    UPDATE public.combo_images
    SET is_primary = false
    WHERE combo_id = p_combo_id AND is_primary = true;

    -- Then, set the specified image as primary
    UPDATE public.combo_images
    SET is_primary = true
    WHERE id = p_image_id AND combo_id = p_combo_id;
END;
$$;
