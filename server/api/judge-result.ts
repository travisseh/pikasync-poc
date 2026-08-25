// GET /api/judge/result?jobId=… → { status: "pending"|"done"|"failed", book?, usage?, error? }

import { getJob } from "../lib/jobs";

export default async function handler(req: any, res: any) {
  if (req.method !== "GET") {
    res.status(405).json({ error: "GET only" });
    return;
  }
  const jobId = String(req.query?.jobId ?? "");
  if (!jobId) {
    res.status(400).json({ error: "need jobId" });
    return;
  }
  try {
    const job = await getJob(jobId);
    if (!job) {
      res.status(404).json({ error: "unknown job" });
      return;
    }
    res.status(200).json({
      status: job.status,
      book: job.book ?? undefined,
      usage: job.usage ?? undefined,
      error: job.error ?? undefined,
      createdAt: job.createdAt,
      updatedAt: job.updatedAt,
    });
  } catch (e: any) {
    res.status(502).json({ error: String(e?.message ?? e) });
  }
}
