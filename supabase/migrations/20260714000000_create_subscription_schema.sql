-- Migración en SERVICIOS: Crear el esquema para la suscripción de platforms

CREATE TABLE IF NOT EXISTS "public"."platforms" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL PRIMARY KEY,
    "name" "text" NOT NULL,
    "description" "text",
    "base_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "default_currency_id" "uuid",
    "default_language_id" "uuid"
);

