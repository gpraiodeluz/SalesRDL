-- Rode no Supabase: SQL Editor > New query > Run
create table orders(
  id uuid primary key default gen_random_uuid(),
  number bigint generated always as identity,
  customer_name text not null check(length(customer_name) between 2 and 100),
  whatsapp text not null check(length(whatsapp) <= 30),
  email text check(length(email) <= 120),
  notes text check(length(notes) <= 500),
  items jsonb not null,
  total numeric(10,2) not null check(total >= 0),
  status text not null default 'pedido_realizado' check(status in
    ('pedido_realizado','pagamento_confirmado','preparando','pronto_para_entrega','entregue','cancelado')),
  created_at timestamptz not null default now()
);
alter table orders enable row level security;

-- Só o e-mail do grupo lê e atualiza pedidos. Clientes não leem nada.
create policy "admin le" on orders for select to authenticated
  using ((auth.jwt()->>'email') = 'gp.raiodeluz@gmail.com');
create policy "admin atualiza" on orders for update to authenticated
  using ((auth.jwt()->>'email') = 'gp.raiodeluz@gmail.com')
  with check ((auth.jwt()->>'email') = 'gp.raiodeluz@gmail.com');

-- Único jeito de o cliente criar pedido (não consegue ler nem alterar nada)
create function create_order(p_nome text,p_whats text,p_email text,p_obs text,p_items jsonb,p_total numeric)
returns bigint language plpgsql security definer set search_path=public as $$
declare n bigint;
begin
  insert into orders(customer_name,whatsapp,email,notes,items,total)
  values(trim(p_nome),trim(p_whats),nullif(trim(p_email),''),nullif(trim(p_obs),''),p_items,p_total)
  returning number into n;
  return n;
end $$;
revoke all on function create_order from public;
grant execute on function create_order to anon, authenticated;
