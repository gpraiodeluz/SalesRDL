-- Rode UMA vez no SQL Editor do Supabase (depois do schema.sql)
create function is_admin() returns boolean language sql stable as
$$ select (auth.jwt()->>'email') = 'gp.raiodeluz@gmail.com' $$;

create table products(
  id bigint generated always as identity primary key,
  name text not null check(length(name) between 2 and 100),
  category text not null default 'Outros',
  price numeric(10,2) not null check(price >= 0),
  kind text not null default 'tee' check(kind in ('tee','long','sticker','mug','bag')),
  color text not null default '#ffe70e',
  stock jsonb not null default '{}',   -- ex.: {"P":5,"M":3}
  created_at timestamptz not null default now()
);
alter table products enable row level security;
create policy "todos veem" on products for select to anon, authenticated using (true);
create policy "admin insere" on products for insert to authenticated with check (is_admin());
create policy "admin altera" on products for update to authenticated using (is_admin()) with check (is_admin());
create policy "admin exclui" on products for delete to authenticated using (is_admin());

-- Pedido cancelado: não pode mais ser alterado; ao cancelar, o estoque volta
create function orders_guard() returns trigger language plpgsql security definer set search_path=public as $$
declare i jsonb;
begin
  if old.status = 'cancelado' then raise exception 'Pedido cancelado não pode ser alterado'; end if;
  if new.status = 'cancelado' then
    for i in select * from jsonb_array_elements(old.items) loop
      update products set stock = jsonb_set(stock, array[i->>'tamanho'],
        to_jsonb(coalesce((stock->>(i->>'tamanho'))::int,0) + (i->>'qtd')::int))
      where id = (i->>'id')::bigint;
    end loop;
  end if;
  return new;
end $$;
create trigger orders_guard before update on orders for each row execute function orders_guard();

-- Só pedidos cancelados podem ser excluídos
create policy "admin exclui cancelado" on orders for delete to authenticated
  using (is_admin() and status = 'cancelado');

-- Novo create_order: preço e estoque conferidos no servidor
drop function create_order(text,text,text,text,jsonb,numeric);
create function create_order(p_nome text,p_whats text,p_email text,p_obs text,p_items jsonb)
returns bigint language plpgsql security definer set search_path=public as $$
declare n bigint; it jsonb; pr products%rowtype; q int; tot numeric := 0; norm jsonb := '[]';
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Pedido vazio'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    q := (it->>'qtd')::int;
    if q < 1 or q > 50 then raise exception 'Quantidade inválida'; end if;
    select * into pr from products where id = (it->>'id')::bigint for update;
    if not found then raise exception 'Produto indisponível'; end if;
    if coalesce((pr.stock->>(it->>'tamanho'))::int,0) < q then
      raise exception 'Sem estoque de % (%)', pr.name, it->>'tamanho'; end if;
    update products set stock = jsonb_set(stock, array[it->>'tamanho'], to_jsonb((stock->>(it->>'tamanho'))::int - q)) where id = pr.id;
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
