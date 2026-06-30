-- Migration #15: Adjust Roles Schema and Seed Data (Corrected)

BEGIN;

-- ========= Step 1: Drop the old, incorrect unique constraint on 'name' =========
-- The original constraint 'roles_name_key' prevents us from having roles
-- with the same name on different platforms.
ALTER TABLE "public"."roles" DROP CONSTRAINT IF EXISTS "roles_name_key";


-- ========= Step 2: Create new partial unique indexes for robust role namespacing =========
-- For global roles (platform and tenant are NULL)
CREATE UNIQUE INDEX IF NOT EXISTS "roles_name_global_unique_idx" ON "public"."roles" ("name")
    WHERE "platform_id" IS NULL AND "tenant_id" IS NULL;

-- For platform-specific roles (tenant is NULL)
CREATE UNIQUE INDEX IF NOT EXISTS "roles_name_platform_unique_idx" ON "public"."roles" ("name", "platform_id")
    WHERE "tenant_id" IS NULL;

-- For tenant-specific roles (platform_id should be present for namespacing)
CREATE UNIQUE INDEX IF NOT EXISTS "roles_name_tenant_unique_idx" ON "public"."roles" ("name", "tenant_id")
    WHERE "tenant_id" IS NOT NULL;


-- ========= Step 3: Seed Roles Data =========

-- Insert Global Roles (platform_id IS NULL, tenant_id IS NULL)
INSERT INTO "public"."roles" ("id", "name", "display_name", "description", "created_at", "tenant_id", "platform_id") VALUES
('0aa1aa22-9055-49ae-9cc6-69418b02f854', 'vendor', 'Vendedor', 'Puede ver sus comisiones de ventas', '2025-10-20 20:19:54.515862+00', NULL, NULL),
('208853b5-994f-4720-97d4-8b0fd3fec476', 'app_super_admin', 'Administrador de Aplicación', 'Puede gestionar la app que tenga asignada.', '2025-07-25 17:06:42.743352+00', NULL, NULL),
('2a3d6276-d044-482b-b3e5-f2c81e68084e', 'super_admin', 'Super Administrador', 'Puede gestionar todas las aplicaciones del universo.', '2025-07-25 17:06:42.743352+00', NULL, NULL),
('89402189-44ad-4f35-8d66-e84f13604a16', 'investor', 'Inversionista', 'Puede acceder a la plataforma de administración para ver el estado de su inversión.', '2025-07-25 17:06:42.743352+00', NULL, NULL)
ON CONFLICT (id) DO NOTHING;


-- Insert Platform-Specific Tenant Roles for Glamtica (platform_id: ca9090c3-f6a3-46c3-af1d-6362e2942e5f)
INSERT INTO "public"."roles" ("id", "name", "display_name", "description", "created_at", "tenant_id", "platform_id") VALUES
('3b534c99-8d6b-4270-b5a5-6c7ad27662f7', 'tenant_admin', 'Administrador de Sucursal', 'Puede administrar una sucursal.', '2025-07-25 17:06:42.743352+00', NULL, 'ca9090c3-f6a3-46c3-af1d-6362e2942e5f'),
('682e28b9-06a9-4a7e-b9f8-3afd765ada5f', 'tenant_user', 'Staff', 'Puede prestar servicios y vender productos.', '2025-07-25 17:06:42.743352+00', NULL, 'ca9090c3-f6a3-46c3-af1d-6362e2942e5f'),
('9715f44a-5c74-4809-be56-2180da166f4e', 'tenant_vendor', 'Vendedor', 'Puede vender para un tenant', '2025-12-07 23:34:18.04442+00', NULL, 'ca9090c3-f6a3-46c3-af1d-6362e2942e5f'),
('af44466d-526a-44c3-b68f-c064dc76f955', 'tenant_super_admin', 'Super Administrador', 'Puede parametrizar todo el tenant.', '2025-07-25 17:06:42.743352+00', NULL, 'ca9090c3-f6a3-46c3-af1d-6362e2942e5f')
ON CONFLICT (id) DO NOTHING;


-- Insert Platform-Specific Tenant Roles for Tattoo Suite (platform_id: 6a6f73c8-2224-4eaf-b40d-da41bd75958a)
-- Using new UUIDs for these platform-specific roles.
INSERT INTO "public"."roles" ("id", "name", "display_name", "description", "created_at", "tenant_id", "platform_id") VALUES
(gen_random_uuid(), 'tenant_admin', 'Administrador de Sucursal', 'Puede administrar una sucursal.', '2025-07-25 17:06:42.743352+00', NULL, '6a6f73c8-2224-4eaf-b40d-da41bd75958a'),
(gen_random_uuid(), 'tenant_user', 'Staff', 'Puede prestar servicios y vender productos.', '2025-07-25 17:06:42.743352+00', NULL, '6a6f73c8-2224-4eaf-b40d-da41bd75958a'),
(gen_random_uuid(), 'tenant_vendor', 'Vendedor', 'Puede vender para un tenant', '2025-12-07 23:34:18.04442+00', NULL, '6a6f73c8-2224-4eaf-b40d-da41bd75958a'),
(gen_random_uuid(), 'tenant_super_admin', 'Super Administrador', 'Puede parametrizar todo el tenant.', '2025-07-25 17:06:42.743352+00', NULL, '6a6f73c8-2224-4eaf-b40d-da41bd75958a')
ON CONFLICT (name, platform_id) WHERE "platform_id" IS NOT NULL AND "tenant_id" IS NULL DO NOTHING;

COMMIT;