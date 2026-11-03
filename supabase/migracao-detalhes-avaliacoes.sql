-- Rode UMA vez no SQL Editor do Supabase (depois do migracao-profissional.sql)

-- 1. Várias fotos e detalhes do produto (material, medidas, cuidados...)
alter table products add column if not exists images text[] not null default '{}';
alter table products add column if not exists details text check (length(details) <= 2000);
alter table products drop constraint if exists products_images_max;
alter table products add constraint products_images_max check (cardinality(images) <= 8);
-- a foto antiga vira a primeira (capa) da galeria
update products set images = array[image_url] where image_url is not null and cardinality(images) = 0;

-- 2. Avaliações (o nome só é guardado quando a pessoa NÃO escolhe o anonimato)
create table if not exists reviews(
  id bigint generated always as identity primary key,
  product_id bigint not null references products(id) on delete cascade,
  author text check (length(author) <= 60),
  rating smallint not null check (rating between 1 and 5),
  comment text check (length(comment) <= 500),
  hidden boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists reviews_product_idx on reviews(product_id, created_at desc);
alter table reviews enable row level security;
create policy "ver avaliacoes" on reviews for select to anon, authenticated
  using (not hidden or is_admin());
create policy "admin altera avaliacoes" on reviews for update to authenticated
  using (is_admin()) with check (is_admin());
create policy "admin exclui avaliacoes" on reviews for delete to authenticated
  using (is_admin());
-- não há política de insert: só dá para avaliar pela função abaixo

-- 3. Nota média por produto (só avaliações visíveis)
create or replace view product_ratings as
  select product_id, round(avg(rating)::numeric, 1) as average, count(*)::int as total
  from reviews where not hidden group by product_id;
grant select on product_ratings to anon, authenticated;

-- 4. Enviar avaliação
create or replace function add_review(p_product bigint, p_name text, p_anonymous boolean, p_rating int, p_comment text)
returns void language plpgsql security definer set search_path=public as $$
declare nm text;
begin
  if p_rating is null or p_rating < 1 or p_rating > 5 then raise exception 'Escolha uma nota de 1 a 5'; end if;
  if not exists (select 1 from products where id = p_product and active) then raise exception 'Produto indisponível'; end if;
  nm := case when coalesce(p_anonymous,false) then null else nullif(trim(coalesce(p_name,'')),'') end;
  if not coalesce(p_anonymous,false) and (nm is null or length(nm) < 2) then
    raise exception 'Informe seu nome ou escolha avaliar de forma anônima';
  end if;
  if length(coalesce(p_comment,'')) > 500 then raise exception 'Comentário muito longo'; end if;
  -- proteção contra spam
  if (select count(*) from reviews where product_id = p_product and created_at > now() - interval '1 hour') >= 10
     or (select count(*) from reviews where created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Muitas avaliações em pouco tempo. Tente de novo mais tarde';
  end if;
  insert into reviews(product_id, author, rating, comment)
  values(p_product, left(nm, 60), p_rating, nullif(trim(coalesce(p_comment,'')),''));
end $$;
revoke all on function add_review from public;
grant execute on function add_review to anon, authenticated;
