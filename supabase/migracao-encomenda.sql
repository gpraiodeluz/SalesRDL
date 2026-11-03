-- Rode UMA vez no SQL Editor do Supabase (depois do migracao-tabela-medidas.sql)

-- 1. Produto sob encomenda: sem controle de estoque
alter table products add column if not exists made_to_order boolean not null default false;
alter table products add column if not exists lead_time text check (length(lead_time) <= 160);

-- 2. Ao cancelar um pedido, só devolve estoque de produtos que têm estoque
create or replace function orders_guard() returns trigger language plpgsql security definer set search_path=public as $$
declare i jsonb;
begin
  if old.status = 'cancelado' then raise exception 'Pedido cancelado não pode ser alterado'; end if;
  if new.status = 'cancelado' then
    for i in select * from jsonb_array_elements(old.items) loop
      update products set stock = jsonb_set(stock, array[i->>'tamanho'],
        to_jsonb(coalesce((stock->>(i->>'tamanho'))::int,0) + (i->>'qtd')::int))
      where id = (i->>'id')::bigint and not made_to_order;
    end loop;
  end if;
  return new;
end $$;

-- 3. Criar pedido: encomenda só confere se a opção (cor/tamanho) existe; não mexe no estoque
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
    if pr.made_to_order then
      if (pr.stock -> (it->>'tamanho')) is null then
        raise exception 'Opção indisponível de % (%)', pr.name, it->>'tamanho';
      end if;
    else
      if coalesce((pr.stock->>(it->>'tamanho'))::int,0) < q then
        raise exception 'Sem estoque de % (%)', pr.name, it->>'tamanho';
      end if;
      update products
         set stock = jsonb_set(stock, array[it->>'tamanho'], to_jsonb((stock->>(it->>'tamanho'))::int - q))
       where id = pr.id;
    end if;
    tot := tot + pr.price * q;
    norm := norm || jsonb_build_object('id',pr.id,'produto',pr.name,'tamanho',it->>'tamanho','qtd',q,'preco',pr.price,'encomenda',pr.made_to_order);
  end loop;

  insert into orders(customer_name,whatsapp,email,notes,items,total)
  values(trim(p_nome),trim(p_whats),nullif(trim(p_email),''),nullif(trim(p_obs),''),norm,tot)
  returning number into n;
  return n;
end $$;
revoke all on function create_order from public;
grant execute on function create_order to anon, authenticated;
