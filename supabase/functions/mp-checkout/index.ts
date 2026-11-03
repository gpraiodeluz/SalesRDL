// Cria a cobrança no Mercado Pago (Checkout Pro, API de Orders) para um pedido e devolve o link de pagamento.
// Publicar com "Verify JWT" DESLIGADO (o site usa a chave publishable, que não é um JWT).
// Segredos necessários (Edge Functions > Secrets): MP_ACCESS_TOKEN. Opcional: SITE_URL.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SB_URL = Deno.env.get('SUPABASE_URL')!;
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MP_TOKEN = Deno.env.get('MP_ACCESS_TOKEN');
const SITE = (Deno.env.get('SITE_URL') ?? 'https://gpraiodeluz.github.io/SalesRDL/').replace(/\/?$/, '/');
const sb = createClient(SB_URL, SB_KEY, { auth: { persistSession: false } });

const siteOrigin = new URL(SITE).origin;
const allowed = (o: string | null) => !!o && (o === siteOrigin || /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o));
const cors = (o: string | null) => ({
  'Access-Control-Allow-Origin': allowed(o) ? o! : siteOrigin,
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
});
const json = (b: unknown, status: number, o: string | null) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors(o), 'Content-Type': 'application/json' } });
const digits = (s: unknown) => String(s ?? '').replace(/\D/g, '');

Deno.serve(async (req) => {
  const origin = req.headers.get('origin');
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors(origin) });
  if (req.method !== 'POST') return json({ error: 'Método inválido' }, 405, origin);
  if (!MP_TOKEN) return json({ error: 'Pagamento no cartão não configurado' }, 503, origin);

  let body: any;
  try { body = await req.json() } catch { return json({ error: 'Requisição inválida' }, 400, origin) }
  const number = Number(body?.number), whats = digits(body?.whats);
  if (!Number.isInteger(number) || number < 1 || whats.length < 10) return json({ error: 'Dados inválidos' }, 400, origin);

  const { data: cfg } = await sb.from('settings').select('key,value').in('key', ['mp_enabled', 'mp_max_installments', 'mp_fee_pct']);
  const S = Object.fromEntries((cfg ?? []).map((r: any) => [r.key, r.value]));
  if (S.mp_enabled !== 'true') return json({ error: 'Pagamento no cartão indisponível no momento' }, 403, origin);

  const { data: o } = await sb.from('orders').select('*').eq('number', number).maybeSingle();
  // mesma regra do acompanhamento: precisa do número do pedido E do WhatsApp usado nele
  if (!o || digits(o.whatsapp).slice(-11) !== whats.slice(-11)) return json({ error: 'Pedido não encontrado' }, 404, origin);
  if (o.status !== 'pedido_realizado') return json({ error: 'Este pedido não está aguardando pagamento' }, 409, origin);
  if (['approved', 'in_process', 'pending'].includes(o.mp_status ?? '')) {
    return json({ error: 'Já existe um pagamento em andamento para este pedido' }, 409, origin);
  }

  // preços vêm do pedido salvo no banco (nunca do navegador); valores em centavos para não errar arredondamento
  const base = (o.items as any[]).map((i) => ({
    title: `${i.produto}${i.tamanho && i.tamanho !== 'Único' ? ' (' + i.tamanho + ')' : ''}`.slice(0, 250),
    quantity: Number(i.qtd),
    cents: Math.round(Number(i.preco) * 100),
  }));
  const baseCents = base.reduce((s, i) => s + i.quantity * i.cents, 0);
  if (!base.length || Math.abs(baseCents - Math.round(Number(o.total) * 100)) > 1) {
    console.error('total do pedido não bate com os itens', o.number, baseCents, o.total);
    return json({ error: 'Não foi possível iniciar o pagamento' }, 500, origin);
  }
  // no cartão o preço repassa a taxa do Mercado Pago: preço ÷ (1 − taxa), arredondado para cima por unidade (mesma conta do site)
  const bps = Math.round(Math.min(30, Math.max(0, parseFloat(String(S.mp_fee_pct ?? '0').replace(',', '.')) || 0)) * 100);
  const items = base.map((i) => ({ ...i, cents: Math.ceil((i.cents * 10000) / (10000 - bps)) }));
  const sumCents = items.reduce((s, i) => s + i.quantity * i.cents, 0);
  const money = (c: number) => (c / 100).toFixed(2);

  const maxInst = Math.min(12, Math.max(1, parseInt(S.mp_max_installments) || 12));
  const order: Record<string, unknown> = {
    type: 'online',
    processing_mode: 'manual',
    external_reference: o.id,
    total_amount: money(sumCents),
    items: items.map((i) => ({ title: i.title, quantity: i.quantity, unit_price: money(i.cents) })),
    expiration_time: 'P1D',
    config: {
      online: {
        success_url: `${SITE}?mp=ok&pedido=${o.number}`,
        pending_url: `${SITE}?mp=pendente&pedido=${o.number}`,
        failure_url: `${SITE}?mp=falha&pedido=${o.number}`,
        auto_return: 'approved',
      },
      // PIX continua sendo pago direto na chave do grupo; aqui ficam cartão e saldo Mercado Pago
      payment_method: { not_allowed_types: ['ticket', 'atm', 'bank_transfer'], max_installments: maxInst },
    },
  };
  if (o.email) order.payer = { email: o.email, first_name: String(o.customer_name ?? '').split(' ')[0] };

  // valor exato que o webhook vai conferir
  await sb.from('orders').update({ mp_amount: sumCents / 100 }).eq('id', o.id);

  const r = await fetch('https://api.mercadopago.com/v1/orders', {
    method: 'POST',
    headers: { Authorization: `Bearer ${MP_TOKEN}`, 'Content-Type': 'application/json', 'X-Idempotency-Key': crypto.randomUUID() },
    body: JSON.stringify(order),
  });
  if (!r.ok) {
    console.error('Mercado Pago recusou a order', r.status, await r.text().catch(() => ''));
    return json({ error: 'Não foi possível iniciar o pagamento' }, 502, origin);
  }
  const created = await r.json();
  const url = created.checkout_url;
  if (!url) return json({ error: 'Não foi possível iniciar o pagamento' }, 502, origin);

  await sb.from('orders').update({ payment_method: 'mercadopago' }).eq('id', o.id);
  return json({ url }, 200, origin);
});
