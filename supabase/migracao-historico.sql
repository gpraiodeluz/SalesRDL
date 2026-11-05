-- Rode UMA vez no SQL Editor do Supabase (depois do migracao-taxa-cartao.sql)

-- 1. Tabela de histórico (só o admin lê; ninguém escreve direto, só as funções abaixo)
create table if not exists order_history (
  id bigserial primary key,
  order_id uuid not null references orders(id) on delete cascade,
  created_at timestamptz not null default now(),
  actor text not null,
  kind text not null check (kind in ('criado','status','edicao','pagamento')),
  summary text not null,
  before jsonb,
  after jsonb
);
create index if not exists order_history_order_idx on order_history(order_id, created_at desc);
alter table order_history enable row level security;
drop policy if exists "admin le historico" on order_history;
create policy "admin le historico" on order_history for select using (is_admin());

-- 2. Texto dos itens e quem fez a ação
create or replace function items_text(p jsonb) returns text language sql immutable as $$
  select coalesce(string_agg((i->>'qtd') || 'x ' || (i->>'produto') ||
    case when coalesce(i->>'tamanho','') in ('','Único') then '' else ' (' || (i->>'tamanho') || ')' end, ', '), '-')
  from jsonb_array_elements(coalesce(p,'[]'::jsonb)) i
$$;
create or replace function current_actor() returns text language plpgsql stable as $$
declare cl jsonb;
begin
  begin cl := nullif(current_setting('request.jwt.claims', true), '')::jsonb; exception when others then cl := null; end;
  if cl is null then return 'sistema'; end if;
  if cl->>'role' = 'service_role' then return 'Mercado Pago (automático)'; end if;
  if cl->>'role' = 'anon' then return 'cliente'; end if;
  return coalesce(cl->>'email', 'sistema');
end $$;

-- 3. Registro automático: criação, mudança de status e de pagamento
create or replace function log_order_insert() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into order_history(order_id, actor, kind, summary, after)
  values (new.id, 'cliente', 'criado',
    'Pedido criado: ' || items_text(new.items) || ' · total R$ ' || to_char(new.total,'FM999990.00') || ' · pagamento: ' || coalesce(new.payment_method,'pix'),
    jsonb_build_object('items', new.items, 'total', new.total));
  return new;
end $$;
drop trigger if exists orders_log_insert on orders;
create trigger orders_log_insert after insert on orders for each row execute function log_order_insert();

create or replace function log_order_update() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if old.status is distinct from new.status then
    insert into order_history(order_id, actor, kind, summary, before, after)
    values (new.id, current_actor(), 'status', 'Status: ' || old.status || ' → ' || new.status,
      jsonb_build_object('status', old.status), jsonb_build_object('status', new.status));
  end if;
  if old.mp_status is distinct from new.mp_status then
    insert into order_history(order_id, actor, kind, summary, before, after)
    values (new.id, current_actor(), 'pagamento',
      'Mercado Pago: ' || coalesce(new.mp_status,'-') || coalesce(' · ' || new.mp_installments || 'x', ''),
      jsonb_build_object('mp_status', old.mp_status), jsonb_build_object('mp_status', new.mp_status));
  end if;
  return new;
end $$;
drop trigger if exists orders_log_update on orders;
create trigger orders_log_update after update on orders for each row execute function log_order_update();

-- 4. Pedidos que já existiam ganham a linha "criado"
insert into order_history(order_id, actor, kind, summary, after, created_at)
select o.id, 'cliente', 'criado', 'Pedido criado (anterior ao histórico): ' || items_text(o.items) || ' · total R$ ' || to_char(o.total,'FM999990.00'),
       jsonb_build_object('items', o.items, 'total', o.total), o.created_at
from orders o where not exists (select 1 from order_history h where h.order_id = o.id);

-- 5. Editar pedido (só o admin): dados do cliente e/ou itens. Estoque é devolvido e baixado de novo na mesma operação.
create or replace function admin_edit_order(p_id uuid, p_nome text, p_whats text, p_email text, p_obs text, p_items jsonb default null)
returns void language plpgsql security definer set search_path=public as $$
declare o orders%rowtype; it jsonb; oi jsonb; pr products%rowtype; q int; tot numeric; norm jsonb := '[]'; digits text;
        price numeric; summ text := ''; newitems jsonb; changed_items boolean := false;
begin
  if not is_admin() then raise exception 'Acesso negado'; end if;
  select * into o from orders where id = p_id for update;
  if not found then raise exception 'Pedido não encontrado'; end if;
  if o.status = 'cancelado' then raise exception 'Pedido cancelado não pode ser alterado'; end if;
  if length(trim(coalesce(p_nome,''))) < 2 then raise exception 'Nome inválido'; end if;
  digits := regexp_replace(coalesce(p_whats,''),'\D','','g');
  if length(digits) < 10 or length(digits) > 13 then raise exception 'WhatsApp inválido'; end if;

  newitems := o.items; tot := o.total;
  if p_items is not null then
    if coalesce(o.mp_status,'') in ('approved','in_process','pending') then
      raise exception 'Pedido com pagamento no cartão iniciado: os itens não podem ser alterados';
    end if;
    if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Pedido vazio'; end if;
    -- devolve o estoque dos itens antigos
    for oi in select * from jsonb_array_elements(o.items) loop
      update products set stock = jsonb_set(stock, array[oi->>'tamanho'],
        to_jsonb(coalesce((stock->>(oi->>'tamanho'))::int,0) + (oi->>'qtd')::int))
      where id = (oi->>'id')::bigint and not made_to_order;
    end loop;
    tot := 0;
    for it in select * from jsonb_array_elements(p_items) loop
      q := (it->>'qtd')::int;
      if q < 1 or q > 50 then raise exception 'Quantidade inválida'; end if;
      select * into pr from products where id = (it->>'id')::bigint for update;
      if not found then raise exception 'Produto indisponível'; end if;
      if pr.made_to_order then
        if (pr.stock -> (it->>'tamanho')) is null then raise exception 'Opção indisponível de % (%)', pr.name, it->>'tamanho'; end if;
      else
        if coalesce((pr.stock->>(it->>'tamanho'))::int,0) < q then raise exception 'Sem estoque de % (%)', pr.name, it->>'tamanho'; end if;
        update products set stock = jsonb_set(stock, array[it->>'tamanho'], to_jsonb((stock->>(it->>'tamanho'))::int - q)) where id = pr.id;
      end if;
      -- produto que já estava no pedido mantém o preço combinado; produto novo usa o preço atual
      select (x->>'preco')::numeric into price from jsonb_array_elements(o.items) x where (x->>'id')::bigint = pr.id limit 1;
      price := coalesce(price, pr.price);
      tot := tot + price * q;
      norm := norm || jsonb_build_object('id',pr.id,'produto',pr.name,'tamanho',it->>'tamanho','qtd',q,'preco',price,'encomenda',pr.made_to_order);
    end loop;
    newitems := norm;
    changed_items := newitems is distinct from o.items;
  end if;

  if trim(p_nome) is distinct from o.customer_name then summ := summ || 'Nome: ' || o.customer_name || ' → ' || trim(p_nome) || '. '; end if;
  if trim(p_whats) is distinct from o.whatsapp then summ := summ || 'WhatsApp: ' || o.whatsapp || ' → ' || trim(p_whats) || '. '; end if;
  if nullif(trim(coalesce(p_email,'')),'') is distinct from o.email then summ := summ || 'E-mail: ' || coalesce(o.email,'-') || ' → ' || coalesce(nullif(trim(p_email),''),'-') || '. '; end if;
  if nullif(trim(coalesce(p_obs,'')),'') is distinct from o.notes then summ := summ || 'Observações alteradas. '; end if;
  if changed_items then
    summ := summ || 'Itens: ' || items_text(o.items) || ' → ' || items_text(newitems) || '. Total: R$ ' || to_char(o.total,'FM999990.00') || ' → R$ ' || to_char(tot,'FM999990.00') || '. ';
  end if;
  if summ = '' then return; end if;

  update orders set customer_name = trim(p_nome), whatsapp = trim(p_whats), email = nullif(trim(coalesce(p_email,'')),''), notes = nullif(trim(coalesce(p_obs,'')),''),
         items = newitems, total = tot, mp_amount = case when changed_items then null else mp_amount end
   where id = p_id;
  insert into order_history(order_id, actor, kind, summary, before, after)
  values (p_id, current_actor(), 'edicao', trim(summ),
    jsonb_build_object('nome',o.customer_name,'whatsapp',o.whatsapp,'email',o.email,'obs',o.notes,'items',o.items,'total',o.total),
    jsonb_build_object('nome',trim(p_nome),'whatsapp',trim(p_whats),'email',nullif(trim(coalesce(p_email,'')),''),'obs',nullif(trim(coalesce(p_obs,'')),''),'items',newitems,'total',tot));
end $$;
revoke all on function admin_edit_order from public;
grant execute on function admin_edit_order to authenticated;
