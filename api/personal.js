// Espejo del organigrama: devuelve solo el personal de salón, por local.
// Existe porque bc-organigrama no manda cabeceras CORS y el navegador
// no puede llamarlo directo desde bc1-ops / bc2-ops.
const ORG = 'https://bc-organigrama.vercel.app/api/organigrama';

const norm = (s) => (s || '')
  .normalize('NFKD').replace(/[̀-ͯ]/g, '')
  .toLowerCase().trim().replace(/\s+/g, ' ');

const esSalon = (role) => {
  const r = norm(role);
  return r.includes('garzon') || r.includes('garzona');
};

export default async function handler(req, res) {
  try {
    const r = await fetch(ORG, { headers: { 'accept': 'application/json' } });
    if (!r.ok) throw new Error('organigrama ' + r.status);
    const j = await r.json();

    const people = [];
    for (const sec of (j.data?.sections || [])) {
      for (const g of (sec.groups || [])) {
        const local = g.name;                      // 'BC1' | 'BC2' | null
        if (local !== 'BC1' && local !== 'BC2') continue;
        for (const p of (g.people || [])) {
          if (!esSalon(p.role)) continue;
          people.push({
            name: p.name,
            role: p.role,
            local,
            key: norm(p.name),
            isJefe: norm(p.role).includes('jefe') || norm(p.role).includes('jefa'),
          });
        }
      }
    }

    res.setHeader('Cache-Control', 's-maxage=300, stale-while-revalidate=3600');
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.status(200).json({ ok: true, people, fetchedAt: new Date().toISOString() });
  } catch (e) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.status(200).json({ ok: false, error: String(e), people: [] });
  }
}
