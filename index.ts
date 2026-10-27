// Dispara por Database Webhook (INSERT na tabela orders) e avisa a equipe por e-mail via Resend.
const PAINEL = 'https://gpraiodeluz.github.io/SalesRDL/admin.html';
const esc = (s: unknown) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
Deno.serve(async (req) => {
  const { record: o } = await req.json();
  const num = `RL-${String(o.number).padStart(4, '0')}`;
  const itens = o.items.map((i: any) => `${esc(i.qtd)}x ${esc(i.produto)} (${esc(i.tamanho)})${i.encomenda ? ' - SOB ENCOMENDA' : ''}`).join('<br>');
  const wa = String(o.whatsapp || '').replace(/\D/g, '');
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${Deno.env.get('RESEND_API_KEY')}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: 'Loja Raio de Luz <onboarding@resend.dev>', to: ['gp.raiodeluz@gmail.com'],
      subject: `Novo pedido ${num} - ${o.customer_name} - R$ ${Number(o.total).toFixed(2)}`,
      html: `<h2>Novo pedido ${num}</h2>
        <p><b>${esc(o.customer_name)}</b><br>WhatsApp: <a href="https://wa.me/${wa.length <= 11 ? '55' + wa : wa}">${esc(o.whatsapp)}</a>${o.email ? '<br>E-mail: ' + esc(o.email) : ''}</p>
        <p>${itens}</p>
        <p><b>Total: R$ ${Number(o.total).toFixed(2)}</b><br>Pagamento: PIX (aguardando comprovante)</p>
        ${o.notes ? `<p>Obs: ${esc(o.notes)}</p>` : ''}
        <p><a href="${PAINEL}">Abrir o painel de pedidos</a></p>`
    })
  });
  return new Response(r.ok ? 'ok' : 'erro', { status: r.ok ? 200 : 500 });
});