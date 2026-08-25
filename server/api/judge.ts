// POST /api/judge — server-side photobook judge.
// Body: { monthLabel, count, maxIndex, correction?, sheets: [base64 jpeg] }
// Returns: { book: { title, cover_index, selections: [{index, page}] }, usage: {...} }
// The phone uploads contact sheets only; the Anthropic key lives here, not in the app.

export const config = { maxDuration: 300 };

interface JudgeRequest {
  monthLabel: string;
  count: number;
  maxIndex: number;
  correction?: string;
  sheets: string[];
}

export default async function handler(req: any, res: any) {
  if (req.method !== "POST") {
    res.status(405).json({ error: "POST only" });
    return;
  }
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) {
    res.status(500).json({ error: "server missing ANTHROPIC_API_KEY" });
    return;
  }

  const { monthLabel, count, maxIndex, correction, sheets } =
    (req.body ?? {}) as JudgeRequest;
  if (
    !monthLabel ||
    !Number.isInteger(count) ||
    !Number.isInteger(maxIndex) ||
    !Array.isArray(sheets) ||
    sheets.length === 0
  ) {
    res.status(400).json({ error: "need monthLabel, count, maxIndex, sheets[]" });
    return;
  }

  const prompt = `You are choosing photos for a printed monthly family photobook the parents will keep forever.

The attached contact sheet images cover ${monthLabel}. Each photo is labeled [index] with its date and face count. Valid indexes are 0 through ${maxIndex}.

Choose EXACTLY ${count} photos and design the book:
- Chronological narrative arc across the month
- Balance the people; labeled names are the family this book is about — strongly prefer photos of them
- Include 2-4 non-people shots ONLY if they clearly add story (a place, trip, event, or milestone); skip mundane food, objects, and receipts unless visually exceptional
- Prefer emotional resonance and storytelling over technical perfection
- At most 1 page per scene/moment (2 only for a clearly major event like a birthday or a big trip highlight); at most 2 photos from the same location or session across the whole book — even with different people in them
- Every page must feature a named family member or a clear family story moment; never pick context-free, obstructed, or filler shots (someone alone at a desk, an empty room, a view-blocked subject)

Respond with ONLY a JSON object, no other text:
{"title": "short book title", "cover_index": <index>, "selections": [{"index": <int>, "page": <1-${count} in book order>}]}
The selections array must contain exactly ${count} entries with distinct indexes.
${correction ? `\nIMPORTANT CORRECTION — your previous answer had these problems, fix them while keeping everything else:\n${correction}` : ""}`;

  const content: any[] = sheets.map((data) => ({
    type: "image",
    source: { type: "base64", media_type: "image/jpeg", data },
  }));
  content.push({ type: "text", text: prompt });

  // A max_tokens cutoff truncates the JSON mid-object (this exact failure hit
  // the on-device client), so check stop_reason and retry once with double the
  // budget rather than trying to decode a partial reply.
  async function callModel(maxTokens: number): Promise<any> {
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": key!,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: "claude-sonnet-5",
        max_tokens: maxTokens,
        messages: [{ role: "user", content }],
      }),
    });
    const j: any = await r.json();
    if (!r.ok) throw { status: 502, body: { error: `anthropic ${r.status}`, detail: j } };
    return j;
  }

  let json: any;
  try {
    // Sonnet 5 reasons internally before answering, and that reasoning counts
    // against max_tokens — a tight budget can be fully consumed with NO text
    // emitted (seen live: 4000 tokens, zero text). The JSON answer itself is
    // tiny, so a large budget costs nothing when unused.
    json = await callModel(16000);
    if (json.stop_reason === "max_tokens") json = await callModel(32000);
  } catch (e: any) {
    res.status(e.status ?? 502).json(e.body ?? { error: String(e) });
    return;
  }

  const text: string | undefined = (json.content ?? [])
    .map((b: any) => b.text)
    .find((t: any) => typeof t === "string");
  if (!text) {
    res.status(502).json({ error: `no text in model response (stop_reason=${json.stop_reason})` });
    return;
  }
  if (json.stop_reason === "max_tokens") {
    res.status(502).json({
      error: `judge reply truncated at max_tokens even after retry (${text.length} chars)`,
    });
    return;
  }
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start < 0 || end < 0) {
    res.status(502).json({ error: `no JSON in judge output (stop_reason=${json.stop_reason}): ${text.slice(0, 200)}` });
    return;
  }

  let book: any;
  try {
    book = JSON.parse(text.slice(start, end + 1));
  } catch (e) {
    res.status(502).json({
      error: `judge JSON parse failed (stop_reason=${json.stop_reason}, ${text.length} chars): ${e}`,
    });
    return;
  }

  // Validation mirrors the on-device client: exact count, distinct, in range.
  const sels = book.selections;
  if (!Array.isArray(sels) || typeof book.title !== "string" || !Number.isInteger(book.cover_index)) {
    res.status(502).json({ error: "judge output missing fields" });
    return;
  }
  const idxs = sels.map((s: any) => s.index);
  if (new Set(idxs).size !== idxs.length) {
    res.status(502).json({ error: "judge returned duplicate indexes" });
    return;
  }
  if (idxs.some((i: any) => !Number.isInteger(i) || i < 0 || i > maxIndex)) {
    res.status(502).json({ error: "judge returned out-of-range index" });
    return;
  }
  // Strip any extra fields (e.g. a caption the model volunteers anyway).
  book = {
    title: book.title,
    cover_index: book.cover_index,
    selections: sels.map((s: any) => ({ index: s.index, page: s.page })),
  };

  res.status(200).json({ book, usage: json.usage ?? {} });
}
