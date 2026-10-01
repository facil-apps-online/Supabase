INSERT INTO public.platforms (id, name, description)
VALUES ('ca9090c3-f6a3-46c3-af1d-6362e2942e5f', 'Glamtica', 'Glamtica Platform')
ON CONFLICT (id) DO NOTHING;
