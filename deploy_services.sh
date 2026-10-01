#!/usr/bin/env bash
# Despliegue del backend Services (carpeta ./supabase) tras los fixes de AUDIT_PAYLOADS.md.
#
# Uso:
#   SERVICES_PROJECT_REF=<ref-del-proyecto-services> ./deploy_services.sh            # simulación (dry-run)
#   SERVICES_PROJECT_REF=<ref-del-proyecto-services> ./deploy_services.sh --apply    # aplica migración y despliega
#
# Requisitos: git, supabase CLI (>= 1.200) con sesión iniciada (`supabase login`) y la contraseña de la BD
# (SUPABASE_DB_PASSWORD) si el CLI la pide para `db push`.
set -euo pipefail

: "${SERVICES_PROJECT_REF:?Define SERVICES_PROJECT_REF con el ref del proyecto Supabase de Services (NO el de Core)}"
APPLY=0; [[ "${1:-}" == "--apply" ]] && APPLY=1
BRANCH="${BRANCH:-main}"

# Funciones modificadas en esta tanda
FUNCTIONS=(tenant-actions user-actions public-actions superadmin-actions google-drive-upload google-drive-delete google-oauth-token)

cd "$(dirname "$0")"

echo ">> 1/5 Actualizando código ($BRANCH)"
git fetch origin "$BRANCH"
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"

echo ">> 2/5 Enlazando proyecto Services: $SERVICES_PROJECT_REF"
supabase link --project-ref "$SERVICES_PROJECT_REF"

echo ">> 3/5 Migraciones pendientes (dry-run)"
supabase db push --dry-run
# Debe listar SOLO 20260930000001_create_archive_branch.sql. Si lista muchas más, el historial remoto
# no está sincronizado: detente y revísalo antes de continuar.

if [[ $APPLY -ne 1 ]]; then
  echo
  echo "Dry-run terminado. Revisa la salida y vuelve a ejecutar con --apply para aplicar migración y desplegar."
  exit 0
fi

read -r -p "¿La lista de migraciones es la esperada? Escribe 'si' para continuar: " OK
[[ "$OK" == "si" ]] || { echo "Cancelado."; exit 1; }

echo ">> 4/5 Aplicando migraciones"
supabase db push

echo ">> 5/5 Desplegando edge functions"
for f in "${FUNCTIONS[@]}"; do
  echo "   - $f"
  supabase functions deploy "$f" --project-ref "$SERVICES_PROJECT_REF"
done

echo
echo "Listo. Verifica en Services que existan los secretos CORE_SUPABASE_URL y CORE_SUPABASE_SERVICE_ROLE_KEY:"
echo "   supabase secrets list --project-ref $SERVICES_PROJECT_REF | grep CORE_"
echo "Y que en el proyecto CORE estén desplegadas google-drive-upload y google-drive-delete."
