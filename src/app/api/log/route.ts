import { writeEntries } from '@/lib/log-server';
import type { LogEntry } from '@/lib/log';

export async function POST(req: Request) {
  try {
    const batch = (await req.json()) as LogEntry[];
    if (!Array.isArray(batch)) return new Response('bad batch', { status: 400 });
    await writeEntries(batch.slice(0, 500).map((e) => ({ ...e, src: 'client' as const })));
    return new Response(null, { status: 204 });
  } catch (err) {
    console.error('[poin:runtime] /api/log 실패', err);
    return new Response('log write failed', { status: 500 });
  }
}
