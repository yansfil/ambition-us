'use client';
// 모듈 A 진입점: 채팅 쇼핑 에이전트 화면(시안 01·03·05). props 없음.
// poin 스토어 연동은 CONTRACTS.md 흐름 1·6·7을 따른다.
import './chat.css';
import { useChat } from '@ai-sdk/react';
import { DefaultChatTransport } from 'ai';
import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react';
import { Conversation, ConversationContent, ConversationScrollButton } from '@/components/ai-elements/conversation';
import type { Product } from '@/catalog/types';
import { t } from '@/i18n';
import { log } from '@/lib/log';
import { poin, usePoin } from '@/poin/store';
import type { ChatTurn } from '@/poin/types';
import { useCart } from './cartStore';
import ChatInput from './ChatInput';
import MessageView, { Dots } from './Messages';
import MissionCard from './MissionCard';
import PoinMark from './PoinMark';
import type { ChatUIMessage, PoinTurnMeta } from './types';

interface Outgoing {
  text: string;
  poin?: PoinTurnMeta;
}

interface Inflight {
  t0: number;
  started: boolean;
  poin?: PoinTurnMeta & { directive: string };
}

// 왼쪽 로그 패널(16 + 270px)을 피해서 가운데 680px 칼럼
const COLUMN: CSSProperties = { left: 'max(300px, calc(50% - 340px))', width: 'min(680px, calc(100vw - 320px))' };

const textOf = (m: ChatUIMessage) => m.parts.map((p) => (p.type === 'text' ? p.text : '')).join('').trim();

/** 마크다운 기호(표 구분선, 굵게, 제목)를 걷어낸 한 줄 텍스트 */
const plain = (md: string) =>
  md
    .replace(/^\s*\|?[\s:|-]+\|[\s:|-]*$/gm, ' ')
    .replace(/[|*#>`_]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

/** poin 추론에 넘길 최근 대화 요약. 도구 결과는 한 줄 표기로 접는다. */
function toTurns(messages: ChatUIMessage[]): ChatTurn[] {
  const turns: ChatTurn[] = [];
  for (const m of messages) {
    if (m.role === 'user') {
      turns.push({ role: m.metadata?.poin ? 'poin' : 'user', text: textOf(m) });
      continue;
    }
    if (m.role !== 'assistant') continue;
    const bits: string[] = [];
    for (const p of m.parts) {
      if (p.type === 'text' && p.text.trim()) bits.push(p.text.trim());
      else if (p.type === 'tool-show_products' && p.state === 'output-available')
        bits.push(`[상품 카드: ${p.output.products.map((x) => `${x.name}(${x.price}원)`).join(', ')}]`);
      else if (p.type === 'tool-add_to_cart' && p.state === 'output-available' && p.output.ok)
        bits.push(`[장바구니 담기: ${p.output.product.name}]`);
      else if (p.type === 'tool-checkout' && p.state === 'output-available' && p.output.ok)
        bits.push(`[결제 완료: ${p.output.orderId}, ${p.output.total}원]`);
    }
    if (bits.length) turns.push({ role: 'assistant', text: bits.join('\n') });
  }
  return turns.slice(-8);
}

export default function ChatApp() {
  const [transport] = useState(
    () =>
      new DefaultChatTransport<ChatUIMessage>({
        api: '/api/chat',
        body: () => ({ cart: useCart.getState().items.map((p) => p.id) }),
      }),
  );
  const inflight = useRef<Inflight | null>(null);

  const { messages, sendMessage, status, error, regenerate, setMessages, stop, clearError } = useChat<ChatUIMessage>({
    transport,
    onError: (e) => {
      const f = inflight.current;
      log.error('chat', '응답 에러', { message: e.message, ms: f ? Math.round(performance.now() - f.t0) : undefined, traceId: f?.poin?.traceId });
    },
    onFinish: ({ message, isAbort, isDisconnect, isError }) => {
      const f = inflight.current;
      inflight.current = null;
      const text = textOf(message);
      const tools = message.parts.filter((p) => p.type.startsWith('tool-')).map((p) => p.type.slice(5));
      const ms = f ? Math.round(performance.now() - f.t0) : -1;
      const data = { ms, chars: text.length, tools, isAbort, isDisconnect, isError, poin: !!f?.poin };
      if (isError || isDisconnect) log.warn('chat', `응답 비정상 종료 (${ms}ms)`, data);
      else log.info('chat', `응답 완료 (${ms}ms)`, data);
      if (f?.poin) {
        const { traceId, directive, markText } = f.poin;
        const trace = poin().traces.find((x) => x.id === traceId);
        if (!trace) log.warn('outcome', 'poin 턴 응답이 끝났지만 trace를 찾지 못함', { traceId });
        if (trace && !trace.outcome) log.warn('outcome', 'trace에 outcome이 없어 agent_turn으로 채움', { traceId });
        const base = trace?.outcome ?? { effect: { kind: 'agent_turn' as const, directive, markText }, description: markText };
        const turnSummary = plain(text).slice(0, 80);
        poin().updateTrace(traceId, { outcome: { ...base, turnSummary } });
        log.info('outcome', 'poin 턴 응답 반영', { traceId, turnSummary, tools });
      }
    },
  });

  const busy = status === 'submitted' || status === 'streaming';
  const busyRef = useRef(false);
  const queue = useRef<Outgoing[]>([]);
  const sendRef = useRef(sendMessage);
  useEffect(() => {
    sendRef.current = sendMessage;
  }, [sendMessage]);

  const [input, setInput] = useState('');
  const [heroMissionOpen, setHeroMissionOpen] = useState(true);
  const [topMissionOpen, setTopMissionOpen] = useState(false);
  const [draftMark, setDraftMark] = useState(false);
  const inputRef = useRef<HTMLTextAreaElement | null>(null);

  const transmit = useCallback((item: Outgoing) => {
    busyRef.current = true;
    if (item.poin) {
      inflight.current = { t0: performance.now(), started: false, poin: { ...item.poin, directive: item.text } };
      log.info('chat', 'poin 턴 전송', { traceId: item.poin.traceId, markText: item.poin.markText, directive: item.text });
    } else {
      inflight.current = { t0: performance.now(), started: false };
      poin().pushSignal({ kind: 'verbal', type: 'message_sent', data: { text: item.text } });
      log.info('chat', '메시지 전송', { text: item.text });
    }
    void sendRef.current({ text: item.text, metadata: item.poin ? { poin: item.poin } : undefined }).catch((e: unknown) =>
      log.error('chat', 'sendMessage 실패', e),
    );
  }, []);

  /** 응답 중이면 큐에 넣고 끝난 뒤 보낸다 */
  const dispatch = useCallback(
    (item: Outgoing) => {
      if (busyRef.current) {
        if (queue.current.length) log.warn('chat', '대기열에 이미 메시지가 있음', { queued: queue.current.length });
        queue.current.push(item);
        log.info('chat', '응답 중이라 전송 대기', { text: item.text, poin: !!item.poin });
        return;
      }
      transmit(item);
    },
    [transmit],
  );

  // 상태 변화: chatBusy, 응답 시작 지연, 대기열 비우기
  useEffect(() => {
    poin().setChatBusy(busy);
    busyRef.current = busy;
    const f = inflight.current;
    if (status === 'streaming' && f && !f.started) {
      f.started = true;
      log.info('chat', `응답 시작 (${Math.round(performance.now() - f.t0)}ms)`, { poin: !!f.poin });
    }
    if ((status === 'ready' || status === 'error') && queue.current.length) {
      const next = queue.current.shift()!;
      log.info('chat', '대기 메시지 전송', { text: next.text, poin: !!next.poin });
      transmit(next);
    }
  }, [status, busy, transmit]);

  // 대화 맥락: 스트리밍 중에는 갱신하지 않는다(스토어 갱신 폭주 방지)
  useEffect(() => {
    if (status === 'streaming') return;
    poin().setChatContext(toTurns(messages));
  }, [messages, status]);

  // 도구 파트 상태 변화 로그 + 부수효과(카트 담기, 결제 완료)
  const toolStates = useRef(new Map<string, string>());
  const handled = useRef(new Set<string>());
  useEffect(() => {
    for (const m of messages) {
      if (m.role !== 'assistant') continue;
      for (const p of m.parts) {
        if (!p.type.startsWith('tool-') || !('toolCallId' in p)) continue;
        const prev = toolStates.current.get(p.toolCallId);
        if (prev !== p.state) {
          toolStates.current.set(p.toolCallId, p.state);
          const lvl = p.state === 'output-error' ? 'error' : 'info';
          log[lvl]('tool', `${p.type.slice(5)} → ${p.state}`, {
            toolCallId: p.toolCallId,
            input: 'input' in p ? p.input : undefined,
            error: p.state === 'output-error' ? p.errorText : undefined,
          });
        }
        if (p.state !== 'output-available' || handled.current.has(p.toolCallId)) continue;
        if (p.type === 'tool-add_to_cart') {
          handled.current.add(p.toolCallId);
          if (p.output.ok) useCart.getState().add(p.output.product, 'tool');
        } else if (p.type === 'tool-checkout') {
          handled.current.add(p.toolCallId);
          if (p.output.ok) {
            useCart.getState().placeOrder({ orderId: p.output.orderId, total: p.output.total, items: p.output.items });
            setTimeout(() => {
              log.info('session', '결제 완료로 세션 종료 요청');
              poin().endSession();
            }, 1500);
          } else {
            log.warn('chat', '결제 실패', { error: p.output.error });
          }
        }
      }
    }
  }, [messages]);

  // poin → 채팅: 초안 채우기, poin 턴
  useEffect(() => {
    const onDraft = (d: NonNullable<ReturnType<typeof poin>['draftFill']>) => {
      setInput(d.text);
      setDraftMark(true);
      poin().consumeDraftFill();
      log.info('chat', 'poin 초안 채움', { traceId: d.traceId, text: d.text });
      requestAnimationFrame(() => {
        const el = inputRef.current;
        if (!el) return;
        el.focus();
        el.setSelectionRange(el.value.length, el.value.length);
      });
    };
    const onTurn = (p: NonNullable<ReturnType<typeof poin>['pendingTurn']>) => {
      poin().consumeTurn();
      log.info('chat', 'poin 턴 수신', { traceId: p.traceId, markText: p.markText, busy: busyRef.current });
      dispatch({ text: p.directive, poin: { markText: p.markText, traceId: p.traceId } });
    };
    // 마운트 전에 들어온 요청도 처리
    const s0 = poin();
    if (s0.draftFill) onDraft(s0.draftFill);
    if (s0.pendingTurn) onTurn(s0.pendingTurn);
    return usePoin.subscribe((s, prev) => {
      if (s.draftFill && s.draftFill !== prev.draftFill) onDraft(s.draftFill);
      if (s.pendingTurn && s.pendingTurn !== prev.pendingTurn) onTurn(s.pendingTurn);
    });
  }, [dispatch]);

  // CartPill 등 채팅 밖에서 보내는 말
  useEffect(() => {
    useCart.getState().setSendBridge((text) => dispatch({ text }));
    return () => useCart.getState().setSendBridge(null);
  }, [dispatch]);

  // 새 세션(회고의 "새 세션 시작"): 채팅과 카트 초기화
  useEffect(() => {
    let last = poin().sessionId;
    return usePoin.subscribe((s) => {
      if (s.sessionId === last) return;
      last = s.sessionId;
      void stop();
      queue.current = [];
      inflight.current = null;
      toolStates.current.clear();
      handled.current.clear();
      setMessages([]);
      clearError();
      useCart.getState().reset();
      setInput('');
      setDraftMark(false);
      setHeroMissionOpen(true);
      setTopMissionOpen(false);
      log.info('chat', '새 세션: 채팅 초기화');
    });
  }, [setMessages, stop, clearError]);

  const submit = () => {
    const text = input.trim();
    if (!text) return;
    if (busyRef.current) {
      log.debug('chat', '응답 중 전송 시도 무시', { text });
      return;
    }
    setInput('');
    setDraftMark(false);
    dispatch({ text });
  };

  const onAdd = useCallback(
    (p: Product) => {
      // 이미 담긴 상품이면(빠른 이중 클릭 등) 채팅으로 다시 보내지 않는다
      if (!useCart.getState().add(p, 'card')) return;
      dispatch({ text: t.chat.addMessage(p.name) });
    },
    [dispatch],
  );

  const hasMessages = messages.length > 0;
  const last = messages[messages.length - 1];
  const lastPart = last?.role === 'assistant' ? last.parts[last.parts.length - 1] : undefined;
  const textStreaming = lastPart?.type === 'text' && lastPart.text.length > 0 && lastPart.state === 'streaming';
  const toolPending = !!lastPart && lastPart.type.startsWith('tool-') && 'state' in lastPart && !String(lastPart.state).startsWith('output');
  const showThinking = busy && !textStreaming && !toolPending;

  const input$ = (
    <ChatInput
      key="input"
      textareaRef={inputRef}
      value={input}
      onChange={setInput}
      onSubmit={submit}
      busy={busy}
      placeholder={hasMessages ? t.chat.placeholderFollow : t.chat.placeholderHero}
      className={hasMessages ? 'mb-[22px] w-full' : 'w-[560px] max-w-full'}
    />
  );
  const draftMark$ = draftMark ? <PoinMark key="draft" text={t.chat.poinDraftMark} hint={t.chat.poinDraftHint} /> : null;

  if (!hasMessages) {
    return (
      <div className="fixed inset-y-0 z-[5] flex flex-col items-center justify-center gap-[22px]" style={COLUMN}>
        <MissionCard
          key="mission"
          expanded={heroMissionOpen}
          onToggle={() => setHeroMissionOpen((v) => !v)}
          className={heroMissionOpen ? 'w-[520px] max-w-full' : undefined}
        />
        <h2 key="title" className="text-[30px] font-[650] tracking-[-0.03em]">
          {t.chat.heroTitle}
        </h2>
        {draftMark$}
        {input$}
      </div>
    );
  }

  return (
    <div className="fixed inset-y-0 z-[5] flex flex-col pt-[60px]" style={COLUMN}>
      <div key="brand" className="absolute left-1 top-[22px] text-[15px] font-[650] tracking-[-0.01em]">
        {t.chat.brand}
        <small className="ml-[7px] text-[13px] font-medium text-[var(--c-muted)]">{t.chat.brandSub}</small>
      </div>
      <MissionCard
        key="mission"
        expanded={topMissionOpen}
        onToggle={() => setTopMissionOpen((v) => !v)}
        className={topMissionOpen ? 'mt-1 w-full' : 'mt-1'}
      />
      <Conversation key="conv" className="min-h-0 flex-1">
        <ConversationContent className="gap-[14px] px-0 py-[18px]">
          {messages.map((m) => (
            <MessageView key={m.id} message={m} streaming={busy && m === last} onAdd={onAdd} />
          ))}
          {showThinking && (
            <div className="flex items-center gap-2 text-[13px] text-[var(--c-faint)]">
              <Dots />
              <span>{t.chat.thinking}</span>
            </div>
          )}
          {error && !busy && (
            <div className="flex items-center gap-3 text-[13px] text-[var(--c-warn-text)]">
              <span>{t.chat.errorGeneric}</span>
              <button
                type="button"
                className="rounded-full bg-[var(--c-soft)] px-3 py-1 font-semibold text-[var(--c-text)]"
                onClick={() => {
                  log.info('chat', '에러 후 다시 시도');
                  inflight.current = { t0: performance.now(), started: false };
                  void regenerate();
                }}
              >
                {t.chat.retry}
              </button>
            </div>
          )}
          {draftMark$}
        </ConversationContent>
        <ConversationScrollButton />
      </Conversation>
      {input$}
    </div>
  );
}
