
alter table public.branch_services
add column is_visible_on_microsite boolean not null default false;

alter table public.branch_combos
add column is_visible_on_microsite boolean not null default false;
