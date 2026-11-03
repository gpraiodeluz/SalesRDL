// Recebe o aviso "Order (Mercado Pago)", CONFIRMA a order direto na API deles e atualiza o pedido.
// Publicar com "Verify JWT" DESLIGADO (o Mercado Pago não envia JWT do Supabase).
// Segredos necessários: MP_ACCESS_TOKEN e MP_WEBHOOK_SECRET (assinatura secreta do webhook).
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SB_URL = Deno.env.get('SUPABASE_URL')!;
const SB_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const MP_TOKEN = Deno.env.get('MP_ACCESS_TOKEN');
const SECRET = Deno.env.get('MP_WEBHOOK_SECRET');
const sb = createClient(SB_URL, SB_KEY, { auth: { persistSession: false } });

async function hmacHex(secret: string, msg: string) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
const same = (a: string, b: string) => { if (a.length !== b.length) return false; let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i); return d === 0 };
const ok = (m = 'ok') => new Response(m, { status: 200 });

// status da order do MP -> status usado no site (approved, in_process, pending, rejected, cancelled, refunded); null = não mexer
function mapStatus(status: string, detail: string): string | null {
  switch (status) {
    case 'processed': return detail === 'accredited' ? 'approved' : 'in_process';
    case 'action_required': return 'pending';
    case 'failed': return 'rejected';
    case 'canceled': case 'cancelled': case 'expired': return 'cancelled';
    case 'refunded': case 'partially_refunded': return 'refunded';
    default: return null;
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return ok();
  const url = new URL(req.url);
  let body: any = {};
  try { body = await req.json() } catch { /* corpo vazio */ }
  const type = url.searchParams.get('type') ?? body?.type;
  const dataId = String(url.searchParams.get('data.id') ?? body?.data?.id ?? '');
  if (type !== 'order' || !dataId) return ok('ignorado');
  if (!MP_TOKEN || !SECRET) { console.error('MP_ACCESS_TOKEN ou MP_WEBHOOK_SECRET não configurado'); return new Response('não configurado', { status: 503 }); }

  // 1) assinatura: "ts=...,v1=..." sobre o manifesto "id:<data.id>;request-id:<x-request-id>;ts:<ts>;"
  const header = req.headers.get('x-signature') ?? '';
  const parts = Object.fromEntries(header.split(',').map((p) => p.trim().split('=')).filter((a) => a.length === 2));
  const idForSig = /^[a-z0-9]+$/i.test(dataId) ? dataId.toLowerCase() : dataId;
  const manifest = `id:${idForSig};request-id:${req.headers.get('x-request-id') ?? ''};ts:${parts.ts};`;
  if (!parts.ts || !parts.v1 || !same(await hmacHex(SECRET, manifest), String(parts.v1))) {
    console.error('assinatura inválida');
    return new Response('assinatura inválida', { status: 401 });
  }

  // 2) a verdade vem da API do Mercado Pago, não do corpo da notificação
  const r = await fetch(`https://api.mercadopago.com/v1/orders/${encodeURIComponent(dataId)}`, { headers: { Authorization: `Bearer ${MP_TOKEN}` } });
  if (r.status === 404) return ok('order não encontrada');
  if (!r.ok) { console.error('erro ao consultar order', r.status); return new Response('erro Mercado Pago', { status: 502 }); } // o MP tenta de novo
  const m = await r.json();
  if (!m.external_reference) return ok('sem referência');

  const { data: o } = await sb.from('orders').select('id,number,status,total,mp_amount,mp_status,mp_payment_id').eq('id', m.external_reference).maybeSingle();
  if (!o) return ok('pedido não encontrado');

  // 3) o valor da order precisa bater com o que foi cobrado no cartão (preço + taxa repassada; juros do parcelamento ficam fora desse valor)
  const expected = Number(o.mp_amount ?? o.total);
  if (expected < Number(o.total) - 0.01 || Math.abs(Number(m.total_amount) - expected) > 0.01) {
    console.error('valor diferente do pedido', o.number, m.total_amount, expected);
    return ok('valor não confere');
  }
  const mpStatus = mapStatus(String(m.status ?? ''), String(m.status_detail ?? ''));
  if (!mpStatus) return ok('status sem ação');
  // 4) outra tentativa chegando depois de uma aprovada não pode sobrescrever a aprovada
  if (o.mp_status === 'approved' && o.mp_payment_id && String(m.id) !== o.mp_payment_id) {
    console.error('segunda order para pedido já pago: avaliar reembolso', o.number, m.id);
    return ok('pedido já pago');
  }

  const pay = m.transactions?.payments?.find((x: any) => x?.status === 'processed') ?? m.transactions?.payments?.[0];
  const inst = Number(pay?.payment_method?.installments);
  const patch: Record<string, unknown> = { payment_method: 'mercadopago', mp_payment_id: String(m.id), mp_status: mpStatus };
  if (Number.isFinite(inst) && inst > 0) patch.mp_installments = inst;
  if (mpStatus === 'approved') {
    patch.paid_at = pay?.date_approved ?? new Date().toISOString();
    if (o.status === 'pedido_realizado') patch.status = 'pagamento_confirmado'; // nunca volta um pedido que já avançou
  }
  const { error } = await sb.from('orders').update(patch).eq('id', o.id);
  if (error) { console.error('erro ao salvar', error.message); return new Response('erro ao salvar', { status: 500 }); }
  return ok();
});
