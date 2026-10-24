'use client';
// 검은 알약 입력창. Enter 전송, Shift+Enter 줄바꿈, 한글 조합 중 Enter 무시. 최대 4줄까지 자동으로 늘어난다.
import { useLayoutEffect, useState, type RefObject } from 'react';
import { t } from '@/i18n';
import { cn } from '@/lib/utils';

const LINE = 24; // px, leading-6
const MAX_LINES = 4;

interface Props {
  value: string;
  onChange: (v: string) => void;
  onSubmit: () => void;
  busy: boolean;
  placeholder: string;
  textareaRef: RefObject<HTMLTextAreaElement | null>;
  className?: string;
}

export default function ChatInput({ value, onChange, onSubmit, busy, placeholder, textareaRef, className }: Props) {
  const [multiline, setMultiline] = useState(false);
  const canSend = value.trim().length > 0 && !busy;

  useLayoutEffect(() => {
    const el = textareaRef.current;
    if (!el) return;
    el.style.height = 'auto';
    const h = Math.min(el.scrollHeight, LINE * MAX_LINES);
    el.style.height = `${h}px`;
    el.style.overflowY = el.scrollHeight > LINE * MAX_LINES ? 'auto' : 'hidden';
    setMultiline(h > LINE + 2);
  }, [value, textareaRef]);

  return (
    <div
      className={cn(
        'relative flex min-h-[60px] items-center bg-[var(--c-pill)] py-[18px] pl-[26px] pr-[64px] text-white transition-[border-radius,box-shadow] duration-200',
        'shadow-[0_18px_40px_-18px_rgba(40,10,0,0.55)] focus-within:shadow-[0_0_0_4px_rgba(26,26,26,0.1),0_18px_40px_-18px_rgba(40,10,0,0.55)]',
        multiline ? 'rounded-[24px]' : 'rounded-full',
        className,
      )}
    >
      <textarea
        ref={textareaRef}
        data-poin-target="input"
        rows={1}
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={(e) => {
          if (e.key !== 'Enter' || e.shiftKey) return;
          if (e.nativeEvent.isComposing || e.keyCode === 229) return;
          e.preventDefault();
          if (canSend) onSubmit();
        }}
        className="block w-full resize-none bg-transparent text-[16px] font-medium leading-6 text-white outline-none placeholder:text-white/45"
      />
      <button
        type="button"
        aria-label={t.chat.send}
        disabled={!canSend}
        onClick={onSubmit}
        className={cn(
          'absolute bottom-[9px] right-[9px] grid size-[42px] place-items-center rounded-full bg-[#F2F2F2] text-[var(--c-pill)] transition-opacity',
          canSend ? 'opacity-100 hover:bg-white' : 'cursor-default opacity-35',
        )}
      >
        <svg width="13" height="13" viewBox="0 0 14 14" fill="none" aria-hidden>
          <path d="M7 12V2M7 2L2.5 6.5M7 2L11.5 6.5" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>
    </div>
  );
}
