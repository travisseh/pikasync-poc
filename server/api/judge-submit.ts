// POST /api/judge/submit — async judge for background wakes.
// Same body as /api/judge. Persists a pending job, responds with {jobId} in ~1s,
// then runs the judge after the response via waitUntil and stores the result.
// The phone collects it later with GET /api/judge/result?jobId=…

import { waitUntil } from "@vercel/functions";
import { randomUUID } from "node:crypto";
import { runJudge, validateRequest, JudgeError } from "../lib/judge";
import { putJob } from "../lib/jobs";

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

  const jobId = randomUUID().replace(/-/g, "");
  try {
    await putJob({ jobId, status: "pending", monthLabel: parsed.monthLabel, count: parsed.count });
  } catch (e: any) {
    res.status(502).json({ error: `job store unavailable: ${String(e?.message ?? e)}` });
    return;
  }

  waitUntil((async () => {
    try {
      const result = await runJudge(parsed, key);
      await putJob({ jobId, status: "done", book: result.book, usage: result.usage });
    } catch (e: any) {
      const msg = e instanceof JudgeError ? (e.body?.error ?? e.message) : String(e?.message ?? e);
      await putJob({ jobId, status: "failed", error: String(msg).slice(0, 500) }).catch(() => {});
    }
  })());

  res.status(202).json({ jobId });
}
