-- Rode UMA vez no SQL Editor do Supabase (depois do migracao-encomenda.sql)

-- 1. Dados do pagamento no pedido (preenchidos pela função mp-webhook)
alter table orders add column if not exists payment_method text not null default 'pix'
  check (payment_method in ('pix','mercadopago'));
alter table orders add column if not exists mp_payment_id text;
alter table orders add column if not exists mp_status text;
alter table orders add column if not exists mp_installments int;
alter table orders add column if not exists paid_at timestamptz;
create unique index if not exists orders_mp_payment_idx on orders(mp_payment_id) where mp_payment_id is not null;

-- 2. Configurações (o cartão começa DESLIGADO; você liga no painel quando tudo estiver testado)
insert into settings(key,value) values ('mp_enabled','false'),('mp_max_installments','12')
on conflict (key) do nothing;

-- 3. Pedido cancelado não muda de status, mas o webhook ainda pode registrar um pagamento (para você reembolsar).
--    O estoque só volta no momento em que o pedido passa a cancelado.
create or replace function orders_guard() returns trigger language plpgsql security definer set search_path=public as $$
declare i jsonb;
begin
  if old.status = 'cancelado' and new.status <> 'cancelado' then
    raise exception 'Pedido cancelado não pode ser alterado';
  end if;
  if new.status = 'cancelado' and old.status <> 'cancelado' then
    for i in select * from jsonb_array_elements(old.items) loop
      update products set stock = jsonb_set(stock, array[i->>'tamanho'],
        to_jsonb(coalesce((stock->>(i->>'tamanho'))::int,0) + (i->>'qtd')::int))
      where id = (i->>'id')::bigint and not made_to_order;
    end loop;
  end if;
  return new;
end $$;

-- 4. Acompanhar pedido agora também informa se há pagamento em análise no cartão
drop function if exists track_order(bigint, text);
create function track_order(p_number bigint, p_whats text)
returns table(number bigint, status text, total numeric, items jsonb, created_at timestamptz, mp_status text)
language sql security definer set search_path=public stable as $$
  select o.number, o.status, o.total, o.items, o.created_at, o.mp_status
  from orders o
  where o.number = p_number
    and length(regexp_replace(coalesce(p_whats,''),'\D','','g')) >= 10
    and right(regexp_replace(o.whatsapp,'\D','','g'),11)
        = right(regexp_replace(p_whats,'\D','','g'),11)
  limit 1
$$;
revoke all on function track_order from public;
grant execute on function track_order to anon, authenticated;
