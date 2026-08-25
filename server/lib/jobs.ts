// Job store client: the Convex pikabook-share deployment holds judge job
// status/results so they survive across Vercel invocations.

const site = process.env.CONVEX_SITE_URL ?? "https://silent-marmot-268.convex.site";

export async function putJob(job: {
  jobId: string; status: "pending" | "done" | "failed";
  monthLabel?: string; count?: number; book?: any; usage?: any; error?: string;
}): Promise<void> {
  const r = await fetch(`${site}/judge-job`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-judge-secret": process.env.JUDGE_JOB_SECRET ?? "" },
    body: JSON.stringify(job),
  });
  if (!r.ok) throw new Error(`job store ${r.status}: ${await r.text()}`);
}

export async function getJob(jobId: string): Promise<any | null> {
  const r = await fetch(`${site}/judge-job?jobId=${encodeURIComponent(jobId)}`);
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`job store ${r.status}: ${await r.text()}`);
  return await r.json();
}
