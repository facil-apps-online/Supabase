-- Migration #14: Seed Platforms Data

BEGIN;

INSERT INTO "public"."platforms" ("id", "name", "description", "base_url", "created_at") VALUES
('04bd5c89-6f17-44c3-a243-134ed4c6022a', 'Vete Zooft', 'ERP para gestión de Veterinarias y Clínicas.', 'https://vetezooft.app', '2025-07-30 14:23:20.406447+00'),
('68a5f367-314b-42b7-8e34-1669f6e30286', 'Autopartia.app', 'ERP para el sector autopartista', 'https://autopartia.app', '2025-07-30 14:21:28.760705+00'),
('6a6f73c8-2224-4eaf-b40d-da41bd75958a', 'Tattoo Suite', 'ERP diseñado para estudios de tatuajes.', 'https://tatoosuite.app', '2025-10-20 13:33:28.238328+00'),
('bedb44f8-3308-4451-a073-7687c70fef88', 'Report Labs', 'Sistema de Reportes con Dataset dinámicos, definidos por el usuario.', 'https://reportlabs.app', '2025-10-17 20:48:23.961287+00'),
('ca9090c3-f6a3-46c3-af1d-6362e2942e5f', 'Glamtica', 'ERP diseñado para salones de belleza, SPAS y barberías.', 'https://glamtica.app', '2025-07-25 14:52:54.064367+00'),
('f8805a86-5cbb-44ba-a348-af7034792c74', 'Documenta', 'Sistema de Gestión Documental', 'https://document.app', '2025-10-17 20:51:00.035364+00')
ON CONFLICT (id) DO NOTHING;

COMMIT;
