import { writeEntries } from '@/lib/log-server';
import type { LogEntry } from '@/lib/log';

export async function POST(req: Request) {
  // 프로덕션에서는 클라이언트 로그를 받지 않는다(아무나 쓰레기를 쓰지 못하게).
  if (process.env.NODE_ENV !== 'development') return new Response(null, { status: 404 });
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
