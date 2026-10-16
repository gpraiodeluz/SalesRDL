// Dispara por Database Webhook (INSERT na tabela orders) e avisa a equipe por e-mail via Resend.
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
Deno.serve(async (req) => {
  const { record: o } = await req.json();
  const itens = o.items.map((i: any) => `${esc(i.qtd)}x ${esc(i.produto)} (${esc(i.tamanho)})`).join('<br>');
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${Deno.env.get('RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: 'Loja Raio de Luz <onboarding@resend.dev>', to: ['gp.raiodeluz@gmail.com'],
      subject: `Novo pedido RL-${String(o.number).padStart(4, '0')} - ${o.customer_name}`,
      html: `<p><b>${esc(o.customer_name)}</b> - WhatsApp ${esc(o.whatsapp)}</p><p>${itens}</p><p>Total: R$ ${Number(o.total).toFixed(2)}</p><p>${esc(o.notes)}</p>`
    })
  });
  return new Response(r.ok ? 'ok' : 'erro', { status: r.ok ? 200 : 500 });
});
