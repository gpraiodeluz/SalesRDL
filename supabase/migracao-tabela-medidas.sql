-- Rode UMA vez no SQL Editor do Supabase (depois do migracao-detalhes-avaliacoes.sql)
alter table products add column if not exists size_chart text check (length(size_chart) <= 3000);
