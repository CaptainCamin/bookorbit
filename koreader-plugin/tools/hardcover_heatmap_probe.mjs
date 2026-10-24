#!/usr/bin/env node
// Throwaway, read-only probe: estimated pages-per-day heatmap from Hardcover reads and progress journal rows.
// Usage: HARDCOVER_DEV_KEY=hc_pat_... node koreader-plugin/tools/hardcover_heatmap_probe.mjs [days=90]
const key = (process.env.HARDCOVER_DEV_KEY || "").replace(/^Bearer\s+/i, "");
if (!key) { console.error("Set HARDCOVER_DEV_KEY"); process.exit(1); }
const DAYS = Number(process.argv[2]) || 90;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let requests = 0;

async function gql(query) {
  for (let attempt = 0; attempt < 4; attempt++) {
    requests++;
    const res = await fetch("https://api.hardcover.app/v1/graphql", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${key}`, "user-agent": "bookorbit-probe" },
      body: JSON.stringify({ query }),
    });
    if (res.status === 429) { await sleep(15000); continue; }
    const json = await res.json();
    if (json.errors) throw new Error(JSON.stringify(json.errors));
    await sleep(1200);
    return json.data;
  }
  throw new Error("rate limited");
}

const DAY = 86400000;
const toDay = (s) => Math.floor(Date.parse(String(s).slice(0, 10) + "T00:00:00Z") / DAY);
const dayStr = (d) => new Date(d * DAY).toISOString().slice(0, 10);
const today = Math.floor(Date.now() / DAY);

const me = (await gql("query { me { id } }")).me[0];

const books = [];
for (let off = 0; ; off += 100) {
  const d = await gql(`query { me { user_books(where: { user_book_reads: {} }, order_by: { id: asc }, limit: 100, offset: ${off}) {
    book_id book { title pages } edition { pages }
    user_book_reads(order_by: { id: asc }) { id started_at finished_at progress_pages edition { pages } } } } }`);
  const rows = d.me[0].user_books;
  books.push(...rows);
  if (rows.length < 100) break;
}

const journal = [];
for (let off = 0; ; off += 100) {
  const d = await gql(`query { reading_journals(where: { user_id: { _eq: ${me.id} }, event: { _eq: "progress_updated" } },
    order_by: [{ action_at: desc }, { id: desc }], offset: ${off}, limit: 100) { book_id action_at metadata } }`);
  journal.push(...d.reading_journals);
  if (d.reading_journals.length < 100) break;
}

const byBook = new Map();
for (const j of journal) {
  const p = Number(j.metadata?.progress_pages);
  if (!Number.isFinite(p)) continue;
  if (!byBook.has(j.book_id)) byBook.set(j.book_id, []);
  byBook.get(j.book_id).push({ day: toDay(j.action_at), pages: p });
}

const pagesPerDay = new Map();
const realDays = new Set();
const stats = { reads: 0, withPoints: 0, spreadOnly: 0, skippedNoPages: 0, skippedBadDates: 0, longSpans: [] };

function spread(from, to, pages, realEnd) {
  if (pages <= 0) return;
  const n = to - from + 1;
  for (let d = from; d <= to; d++) {
    pagesPerDay.set(d, (pagesPerDay.get(d) || 0) + pages / n);
    if (realEnd && d === to) realDays.add(d);
  }
}

for (const ub of books) {
  for (const r of ub.user_book_reads) {
    stats.reads++;
    if (!r.started_at) { stats.skippedBadDates++; continue; }
    const start = toDay(r.started_at);
    const finished = r.finished_at ? toDay(r.finished_at) : null;
    const end = finished ?? today;
    const total = r.edition?.pages || ub.edition?.pages || ub.book?.pages || 0;
    const finalPages = finished !== null ? total || r.progress_pages || 0 : r.progress_pages || 0;
    if (end < start) { stats.skippedBadDates++; continue; }
    if (!finalPages) { stats.skippedNoPages++; continue; }
    if (end - start > 120) stats.longSpans.push(`${ub.book.title} ${dayStr(start)}..${dayStr(end)}`);

    const best = new Map();
    for (const p of byBook.get(ub.book_id) || []) {
      if (p.day < start || p.day > end) continue;
      best.set(p.day, Math.max(best.get(p.day) || 0, Math.min(p.pages, finalPages)));
    }
    const points = [{ day: start - 1, pages: 0, anchor: true }];
    let high = 0;
    for (const day of [...best.keys()].sort((a, b) => a - b)) {
      if (best.get(day) <= high) continue;
      high = best.get(day);
      points.push({ day, pages: high });
    }
    if (finished !== null && high < finalPages) points.push({ day: end, pages: finalPages, anchor: true });
    if (points.length === 1) continue;
    if (points.some((p) => !p.anchor)) stats.withPoints++;
    else stats.spreadOnly++;
    for (let i = 1; i < points.length; i++) {
      const a = points[i - 1];
      const b = points[i];
      spread(Math.max(a.day + 1, start), Math.max(b.day, start), b.pages - a.pages, !b.anchor);
    }
  }
}

const streak = (set) => {
  let n = 0;
  let d = set.has(today) ? today : today - 1;
  while (set.has(d)) { n++; d--; }
  return n;
};
const allDays = new Set([...pagesPerDay.keys()].filter((d) => d <= today));
const estimatedDays = [...allDays].filter((d) => !realDays.has(d));

const first = today - DAYS + 1;
const gridStart = first - ((first + 3) % 7);
const shade = (d) => {
  const p = pagesPerDay.get(d) || 0;
  if (!p) return ".";
  const real = realDays.has(d);
  const level = p >= 100 ? 3 : p >= 40 ? 2 : 1;
  return real ? ["", "#", "##", "###"][level].slice(0, 1) : ["", "-", "=", "+"][level];
};
const rows = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((name, i) => {
  let line = `${name} `;
  for (let d = gridStart + i; d <= today; d += 7) line += d < first ? " " : shade(d);
  return line;
});

console.log(JSON.stringify({
  requests, books: books.length, journalRows: journal.length, ...stats, longSpans: stats.longSpans.slice(0, 8),
  daysWithPages: allDays.size, realDays: [...realDays].filter((d) => d <= today).length, estimatedDays: estimatedDays.length,
  streakRealOnly: streak(realDays), streakWithEstimated: streak(allDays),
  lastNDays: { days: DAYS, real: [...realDays].filter((d) => d >= first && d <= today).length, estimated: estimatedDays.filter((d) => d >= first).length },
  topDays: [...pagesPerDay].filter(([d]) => d <= today).sort((a, b) => b[1] - a[1]).slice(0, 5).map(([d, p]) => `${dayStr(d)} ${Math.round(p)}p ${realDays.has(d) ? "real" : "est"}`),
}, null, 2));
console.log(`\nLast ${DAYS} days (columns are weeks, oldest left). # real, - = + estimated (light to heavy), . none\n` + rows.join("\n"));
