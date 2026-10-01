@echo off
REM Despliegue de Services en Windows. Ejecutar DENTRO de la carpeta del repo Supabase (donde esta la carpeta "supabase").
REM Requiere: git, supabase CLI, sesion iniciada (supabase login) y el proyecto ya enlazado (supabase link).
REM Si no esta enlazado, descomenta la linea siguiente y pon el ref del proyecto Services:
REM supabase link --project-ref TU_REF_SERVICES

echo === 1. Pull ===
git checkout main || goto :error
git pull origin main || goto :error

echo === 2. Migraciones ===
supabase db push || goto :error

echo === 3. Edge functions ===
supabase functions deploy tenant-actions || goto :error
supabase functions deploy user-actions || goto :error
supabase functions deploy public-actions || goto :error
supabase functions deploy superadmin-actions || goto :error
supabase functions deploy google-drive-upload || goto :error
supabase functions deploy google-drive-delete || goto :error
supabase functions deploy google-oauth-token || goto :error

echo.
echo Listo.
goto :eof

:error
echo.
echo ERROR: el paso anterior fallo. Revisa el mensaje y no continues.
exit /b 1
