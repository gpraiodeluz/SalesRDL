-- Rode UMA vez no SQL Editor do Supabase (depois do migracao-mercadopago.sql)

-- 1. Nova forma de pagamento: dinheiro em mãos na entrega
alter table orders drop constraint if exists orders_payment_method_check;
alter table orders add constraint orders_payment_method_check check (payment_method in ('pix','mercadopago','dinheiro'));
insert into settings(key,value) values ('cash_enabled','true') on conflict (key) do nothing;

-- 2. create_order passa a receber a forma de pagamento escolhida (pix ou dinheiro)
drop function if exists create_order(text,text,text,text,jsonb);
create function create_order(p_nome text,p_whats text,p_email text,p_obs text,p_items jsonb,p_metodo text default 'pix')
returns bigint language plpgsql security definer set search_path=public as $$
declare n bigint; it jsonb; pr products%rowtype; q int; tot numeric := 0; norm jsonb := '[]'; digits text; pm text := 'pix';
begin
  if coalesce((select value from settings where key='store_open'),'true') <> 'true' then
    raise exception 'A loja está fechada para novos pedidos no momento';
  end if;
  if p_metodo = 'dinheiro' then
    if coalesce((select value from settings where key='cash_enabled'),'false') <> 'true' then
      raise exception 'Pagamento em dinheiro indisponível no momento';
    end if;
    pm := 'dinheiro';
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

  insert into orders(customer_name,whatsapp,email,notes,items,total,payment_method)
  values(trim(p_nome),trim(p_whats),nullif(trim(p_email),''),nullif(trim(p_obs),''),norm,tot,pm)
  returning number into n;
  return n;
end $$;
revoke all on function create_order from public;
grant execute on function create_order to anon, authenticated;

-- 3. Acompanhar pedido também informa a forma de pagamento
drop function if exists track_order(bigint, text);
create function track_order(p_number bigint, p_whats text)
returns table(number bigint, status text, total numeric, items jsonb, created_at timestamptz, mp_status text, payment_method text)
language sql security definer set search_path=public stable as $$
  select o.number, o.status, o.total, o.items, o.created_at, o.mp_status, o.payment_method
  from orders o
  where o.number = p_number
    and length(regexp_replace(coalesce(p_whats,''),'\D','','g')) >= 10
    and right(regexp_replace(o.whatsapp,'\D','','g'),11)
        = right(regexp_replace(p_whats,'\D','','g'),11)
  limit 1
$$;
revoke all on function track_order from public;
grant execute on function track_order to anon, authenticated;
