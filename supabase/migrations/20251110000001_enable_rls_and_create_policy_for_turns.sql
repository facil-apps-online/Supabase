-- Primero, nos aseguramos de que RLS esté activado en la tabla 'turns'
ALTER TABLE public.turns ENABLE ROW LEVEL SECURITY;

-- Creamos la política para que los turnos públicos sean visibles por todos
CREATE POLICY "Public turns are viewable by everyone"
ON public.turns FOR SELECT
USING ( status IN ('waiting', 'called') );
