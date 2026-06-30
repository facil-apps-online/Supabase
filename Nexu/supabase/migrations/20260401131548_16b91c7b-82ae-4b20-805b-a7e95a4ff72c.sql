
CREATE OR REPLACE FUNCTION public.calculate_evaluation_score(_evaluation_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    _template_id uuid;
    _scale_min integer;
    _scale_max integer;
    _total_weight numeric := 0;
    _weighted_score numeric := 0;
    _section record;
    _criterion record;
    _response record;
    _criterion_score numeric;
    _section_score numeric;
    _section_count integer;
    _section_total numeric;
BEGIN
    -- Get template info
    SELECT e.template_id, t.scale_min, t.scale_max
    INTO _template_id, _scale_min, _scale_max
    FROM evaluations e
    JOIN evaluation_templates t ON t.id = e.template_id
    WHERE e.id = _evaluation_id;

    IF _template_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Loop through sections
    FOR _section IN
        SELECT id, weight FROM evaluation_template_sections
        WHERE template_id = _template_id ORDER BY sort_order
    LOOP
        _section_total := 0;
        _section_count := 0;

        FOR _criterion IN
            SELECT c.id, c.response_type, c.correct_answer, c.options
            FROM evaluation_template_criteria c
            WHERE c.section_id = _section.id ORDER BY c.sort_order
        LOOP
            SELECT * INTO _response
            FROM evaluation_responses
            WHERE evaluation_id = _evaluation_id AND criterion_id = _criterion.id;

            IF _response IS NOT NULL THEN
                _criterion_score := NULL;

                IF _criterion.response_type = 'scale' THEN
                    -- Normalize scale score to 0-1
                    IF _response.score IS NOT NULL AND _scale_max > _scale_min THEN
                        _criterion_score := (_response.score - _scale_min)::numeric / (_scale_max - _scale_min)::numeric;
                    END IF;

                ELSIF _criterion.response_type IN ('single_choice', 'yes_no') THEN
                    IF _criterion.correct_answer IS NOT NULL AND _criterion.correct_answer != '' THEN
                        _criterion_score := CASE WHEN _response.response_value = _criterion.correct_answer THEN 1.0 ELSE 0.0 END;
                    ELSIF _response.score IS NOT NULL THEN
                        _criterion_score := (_response.score - _scale_min)::numeric / (_scale_max - _scale_min)::numeric;
                    END IF;

                ELSIF _criterion.response_type = 'multiple_choice' THEN
                    IF _criterion.correct_answer IS NOT NULL AND _criterion.correct_answer != '' THEN
                        _criterion_score := CASE WHEN _response.response_value = _criterion.correct_answer THEN 1.0 ELSE 0.0 END;
                    ELSIF _response.score IS NOT NULL THEN
                        _criterion_score := (_response.score - _scale_min)::numeric / (_scale_max - _scale_min)::numeric;
                    END IF;

                ELSIF _criterion.response_type = 'open_text' THEN
                    IF _response.score IS NOT NULL THEN
                        _criterion_score := (_response.score - _scale_min)::numeric / (_scale_max - _scale_min)::numeric;
                    END IF;
                END IF;

                IF _criterion_score IS NOT NULL THEN
                    _section_total := _section_total + _criterion_score;
                    _section_count := _section_count + 1;
                END IF;
            END IF;
        END LOOP;

        IF _section_count > 0 THEN
            _section_score := _section_total / _section_count;
            _weighted_score := _weighted_score + (_section_score * _section.weight);
            _total_weight := _total_weight + _section.weight;
        END IF;
    END LOOP;

    IF _total_weight > 0 THEN
        -- Return score on the template's scale
        RETURN ROUND(_scale_min + ((_weighted_score / _total_weight) * (_scale_max - _scale_min)), 2);
    END IF;

    RETURN NULL;
END;
$$;
