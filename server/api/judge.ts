// POST /api/judge — synchronous server-side photobook judge (interactive runs).
// Body: { monthLabel, count, maxIndex, correction?, sheets: [base64 jpeg] }
// Returns: { book: { title, cover_index, selections: [{index, page}] }, usage: {...} }
// The phone uploads contact sheets only; the Anthropic key lives here, not in the app.
// Background wakes use /api/judge/submit + /api/judge/result instead (see lib/judge.ts).

import { runJudge, validateRequest, JudgeError } from "../lib/judge";

export const config = { maxDuration: 300 };

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
  const parsed = validateRequest(req.body);
  if (!parsed) {
    res.status(400).json({ error: "need monthLabel, count, maxIndex, sheets[]" });
    return;
  }
  try {
    const result = await runJudge(parsed, key);
    res.status(200).json(result);
  } catch (e: any) {
    if (e instanceof JudgeError) {
      res.status(502).json(e.body);
    } else {
      res.status(502).json({ error: String(e) });
    }
  }
}
