-- Rode UMA vez no SQL Editor do Supabase (depois do schema.sql e do migracao-estoque.sql)

-- 1. Tipos de produto: corrige o erro do chaveiro ("products_kind_check")
alter table products drop constraint if exists products_kind_check;
alter table products add constraint products_kind_check
  check (kind in ('tee','long','sticker','mug','bag','keychain','other'));

-- 2. Campos novos nos produtos
alter table products add column if not exists active boolean not null default true;
alter table products add column if not exists image_url text;
alter table products add column if not exists description text check (length(description) <= 300);

-- Clientes só enxergam produtos ativos; o admin enxerga todos
drop policy if exists "todos veem" on products;
create policy "publico ve ativos" on products for select to anon, authenticated
  using (active or is_admin());

-- 3. Configurações da loja (PIX, aviso, loja aberta/fechada...)
create table if not exists settings(
  key text primary key,
  value text not null default ''
);
alter table settings enable row level security;
create policy "todos leem config" on settings for select to anon, authenticated using (true);
create policy "admin cria config" on settings for insert to authenticated with check (is_admin());
create policy "admin altera config" on settings for update to authenticated
  using (is_admin()) with check (is_admin());

insert into settings(key,value) values
  ('store_open','true'),
  ('notice',''),
  ('delivery_info','A entrega é feita pessoalmente, durante os horários de encontro do grupo.'),
  ('contact_whats','43999162034'),
  ('pix_type','phone'),
  ('pix_key','43999162034'),
  ('pix_name','Grupo Raio de Luz'),
  ('pix_city','Brasil')
on conflict (key) do nothing;

-- 4. Criar pedido: agora respeita loja fechada, produto oculto e limite anti-spam
create or replace function create_order(p_nome text,p_whats text,p_email text,p_obs text,p_items jsonb)
returns bigint language plpgsql security definer set search_path=public as $$
declare n bigint; it jsonb; pr products%rowtype; q int; tot numeric := 0; norm jsonb := '[]'; digits text;
begin
  if coalesce((select value from settings where key='store_open'),'true') <> 'true' then
    raise exception 'A loja está fechada para novos pedidos no momento';
  end if;
  if length(trim(coalesce(p_nome,''))) < 2 then raise exception 'Nome inválido'; end if;
  digits := regexp_replace(coalesce(p_whats,''),'\D','','g');
  if length(digits) < 10 or length(digits) > 13 then raise exception 'WhatsApp inválido'; end if;
  if (select count(*) from orders
        where regexp_replace(whatsapp,'\D','','g') = digits
          and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Muitos pedidos em pouco tempo. Aguarde um pouco e tente de novo';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Pedido vazio'; end if;

  for it in select * from jsonb_array_elements(p_items) loop
    q := (it->>'qtd')::int;
    if q < 1 or q > 50 then raise exception 'Quantidade inválida'; end if;
    select * into pr from products where id = (it->>'id')::bigint and active for update;
    if not found then raise exception 'Produto indisponível'; end if;
    if coalesce((pr.stock->>(it->>'tamanho'))::int,0) < q then
      raise exception 'Sem estoque de % (%)', pr.name, it->>'tamanho';
    end if;
    update products
       set stock = jsonb_set(stock, array[it->>'tamanho'], to_jsonb((stock->>(it->>'tamanho'))::int - q))
     where id = pr.id;
    tot := tot + pr.price * q;
    norm := norm || jsonb_build_object('id',pr.id,'produto',pr.name,'tamanho',it->>'tamanho','qtd',q,'preco',pr.price);
  end loop;

  insert into orders(customer_name,whatsapp,email,notes,items,total)
  values(trim(p_nome),trim(p_whats),nullif(trim(p_email),''),nullif(trim(p_obs),''),norm,tot)
  returning number into n;
  return n;
end $$;
revoke all on function create_order from public;
grant execute on function create_order to anon, authenticated;

-- 5. Acompanhar pedido: o cliente precisa do número E do WhatsApp usado no pedido
create or replace function track_order(p_number bigint, p_whats text)
returns table(number bigint, status text, total numeric, items jsonb, created_at timestamptz)
language sql security definer set search_path=public stable as $$
  select o.number, o.status, o.total, o.items, o.created_at
  from orders o
  where o.number = p_number
    and length(regexp_replace(coalesce(p_whats,''),'\D','','g')) >= 10
    and right(regexp_replace(o.whatsapp,'\D','','g'),11)
        = right(regexp_replace(p_whats,'\D','','g'),11)
  limit 1
$$;
revoke all on function track_order from public;
grant execute on function track_order to anon, authenticated;

-- 6. Fotos dos produtos (bucket público para leitura; só o admin envia)
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('product-images','product-images',true,2097152,array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

create policy "fotos publicas" on storage.objects for select
  using (bucket_id = 'product-images');
create policy "admin envia fotos" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and is_admin());
create policy "admin altera fotos" on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and is_admin());
create policy "admin apaga fotos" on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and is_admin());
