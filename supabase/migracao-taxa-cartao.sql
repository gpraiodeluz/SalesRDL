-- Rode UMA vez no SQL Editor do Supabase (depois do migracao-dinheiro.sql)

-- Valor cobrado no cartão (preço + taxa do Mercado Pago repassada). Preenchido pela função mp-checkout.
alter table orders add column if not exists mp_amount numeric(10,2);

-- Taxa por venda do Mercado Pago repassada no cartão (%). Ajuste no painel admin > Configurações.
-- 4.99 = receber na hora ou em 14 dias; 3.99 = receber em 30 dias. Confirme em "Seu negócio > Custos".
insert into settings(key,value) values ('mp_fee_pct','4.99') on conflict (key) do nothing;
