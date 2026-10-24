#!/usr/bin/env node
// Throwaway, read-only probe: one Hardcover query shaped like BookOrbit's dashboard body.
// Usage: HARDCOVER_DEV_KEY=hc_pat_... node koreader-plugin/tools/hardcover_dashboard_probe.mjs
const key = (process.env.HARDCOVER_DEV_KEY || "").replace(/^Bearer\s+/i, "");
if (!key) {
  console.error("Set HARDCOVER_DEV_KEY");
  process.exit(1);
}

const yearStart = `${new Date().getFullYear()}-01-01`;
const bookFields = `
  book_id edition_id status_id rating last_read_date
  book { title cached_image pages contributions { author { name } } }
  edition { pages isbn_13 publisher { name } }
  user_book_reads(order_by: { id: desc }, limit: 1) { progress_pages started_at finished_at }`;
const query = `query {
  me {
    username name books_count
    reading: user_books(where: { status_id: { _eq: 2 } }, order_by: { last_read_date: desc_nulls_last }, limit: 10) { ${bookFields} }
    finished: user_books(where: { status_id: { _eq: 3 }, last_read_date: { _gte: "${yearStart}" } }, order_by: { last_read_date: desc_nulls_last }, limit: 20) { ${bookFields} }
    wanted: user_books(where: { status_id: { _eq: 1 } }, limit: 20) { book_id book { title } }
    goals(where: { archived: { _eq: false } }, order_by: [{ end_date: asc }, { id: asc }]) { goal metric progress start_date end_date }
  }
}`;

const toBook = (u) => {
  const read = u.user_book_reads?.[0];
  const pages = u.edition?.pages ?? u.book?.pages ?? null;
  return {
    id: u.book_id,
    title: u.book?.title,
    authors: (u.book?.contributions ?? []).map((c) => c.author?.name),
    cover: u.book?.cached_image?.url ?? null,
    progress: read && pages ? Math.round((100 * (read.progress_pages ?? 0)) / pages) : null,
    lastRead: u.last_read_date,
  };
};

const started = Date.now();
const res = await fetch("https://api.hardcover.app/v1/graphql", {
  method: "POST",
  headers: { "content-type": "application/json", authorization: `Bearer ${key}`, "user-agent": "bookorbit-probe" },
  body: JSON.stringify({ query }),
});
const ms = Date.now() - started;
const json = await res.json();
if (!res.ok || json.errors) {
  console.error(res.status, JSON.stringify(json.errors ?? json));
  process.exit(1);
}
const me = Array.isArray(json.data.me) ? json.data.me[0] : json.data.me;
const goal = me.goals.find((g) => g.metric === "book") ?? me.goals[0];
console.log(
  JSON.stringify(
    {
      requests: 1,
      topLevelFields: 1,
      durationMs: ms,
      responseBytes: JSON.stringify(json).length,
      greeting: me.name ?? me.username,
      totalBooks: me.books_count,
      continueReading: me.reading.map(toBook),
      finishedThisYear: me.finished.map(toBook),
      wantToReadSample: me.wanted.length,
      readingGoal: goal && { goalBooks: goal.goal, completedBooks: goal.progress, metric: goal.metric, year: goal.end_date?.slice(0, 4) },
    },
    null,
    2,
  ),
);
