
CREATE OR REPLACE FUNCTION "public"."get_user_assigned_equipment"(p_user_id uuid)
RETURNS TABLE(assignment_id uuid, equipment_id uuid, equipment_name text)
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN QUERY
  SELECT
    ea.id as assignment_id,
    e.id as equipment_id,
    e.name as equipment_name
  FROM
    equipment_assignments ea
  JOIN
    equipment e ON ea.equipment_id = e.id
  WHERE
    ea.user_id = p_user_id AND ea.return_date IS NULL;
END;
$$;
