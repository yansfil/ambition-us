'use client';
// 채팅 속 poin 표식(시안 05). poin 레이어 요소라 data-poin-layer를 붙여 커서 수집기가 무시하게 한다.
interface Props {
  text: string;
  hint?: string;
}

export default function PoinMark({ text, hint }: Props) {
  return (
    <div
      data-poin-layer
      className="poin-glass flex items-center gap-[9px] self-center rounded-full py-[7px] pl-[11px] pr-[14px] text-[12.5px] font-medium"
    >
      <span className="poin-orb" />
      <span>{text}</span>
      {hint && <span className="font-normal text-[var(--on-dark-muted)]">{hint}</span>}
    </div>
  );
}
