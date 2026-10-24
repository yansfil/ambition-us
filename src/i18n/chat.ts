// chat 모듈 UI 문구. 이 파일은 해당 모듈 담당만 수정한다. 영어 전환 시 en/chat.ts를 같은 키로 추가.
const comma = (n: number) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');

export const chat = {
  brand: '선물가게',
  brandSub: '쇼핑 에이전트',

  missionKicker: '오늘의 미션',
  missionTitle: '친구 집들이 선물을 8만 원 안에서 골라 보세요.',
  missionSub: '에이전트와 대화하며 골라 장바구니에 담고 결제까지 해 보세요.',
  missionPillLabel: '미션',
  missionPillText: '친구 집들이 선물 · 8만 원 이하',
  missionDoneLabel: '미션 완료',
  missionCollapse: '접기',

  heroTitle: '무엇을 찾아 드릴까요?',
  placeholderHero: '원하는 선물을 편하게 말씀해 주세요',
  placeholderFollow: '이어서 물어보세요',
  send: '보내기',

  thinking: '생각하는 중',
  searching: '카탈로그를 찾는 중…',
  searched: (n: number) => `카탈로그에서 ${n}개를 살펴봤어요`,
  preparingCards: '상품 카드를 준비하는 중…',
  addingToCart: '장바구니에 담는 중…',
  addedToCart: (name: string) => `장바구니에 담았어요 · ${name}`,
  checkingOut: '결제하는 중…',
  toolFailed: '도구 실행에 실패했어요',
  errorGeneric: '응답을 받지 못했어요. 잠시 후 다시 보내 주세요.',
  retry: '다시 시도',

  won: (n: number) => `${comma(n)}원`,
  budgetLeft: (n: number) => `여유 ${comma(n)}원`,
  budgetOver: (n: number) => `예산 ${comma(n)}원 초과`,
  add: '담기',
  cardLabel: (name: string) => `상품 카드 · ${name}`, // DOM 규약 data-poin-label
  addLabel: (name: string) => `담기 · ${name}`, // DOM 규약 data-poin-label
  added: '담음',
  addMessage: (name: string) => `${name} 담을게요`,
  rating: (r: number) => `★ ${r.toFixed(1)}`,
  soldOut: '품절',
  stockLeft: (n: number) => `${n}개 남음`,
  discount: (pct: number) => `${pct}%`,
  arrival: (days: number) => (days <= 1 ? '내일 도착' : `${days}일 뒤 도착`),
  giftWrap: '선물 포장',
  optionsLine: (opts: { name: string; values: string[] }[]) => `옵션 · ${opts.map((o) => `${o.name} ${o.values.length}종`).join(', ')}`,
  outOfStock: (name: string) => `품절이라 담지 못했어요 · ${name}`,
  addedWithOption: (name: string, option: string) => `장바구니에 담았어요 · ${name} (${option})`,

  poinMarkHint: '다음 응답에 반영했어요',
  poinDraftMark: 'poin이 다음 질문 초안을 채웠어요',
  poinDraftHint: '고쳐서 보내도 돼요',

  cart: '장바구니',
  cartEmpty: '아직 담은 상품이 없어요',
  cartTotal: '합계',
  cartRemove: '빼기',
  checkout: '결제하기',
  checkoutMessage: '결제할게요',
  ordered: '주문 완료',

  orderDoneTitle: '결제가 끝났어요',
  orderNo: (id: string) => `주문번호 ${id}`,
  orderTotal: '결제 금액',
  orderFailed: '결제하지 못했어요',
} as const;
