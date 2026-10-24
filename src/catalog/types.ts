export interface ProductOption {
  name: string; // 예: "향", "색", "용량"
  values: string[]; // 예: ["라벤더", "우디", "시트러스"]
}

export interface Product {
  id: string; // 예: "p01"
  name: string;
  price: number; // 판매가(원)
  category: string;
  emoji: string;
  tint: [string, string]; // 이미지 영역 그라데이션 두 색
  features: string[];
  tradeoff: { pro: string; con: string }; // 카드에 한 줄로: "분위기 최고 · 향 호불호가 있음"
  rating: number;
  reviews: string[]; // 짧은 리뷰 3개
  returnPolicy: string; // 예: "무료 반품 7일"
  // ── 확장 필드 (2차) ──
  stock: number; // 남은 수량. 0이면 품절, 1~3이면 "얼마 안 남음"
  shipDays: number; // 주문 후 도착까지 걸리는 날(1 = 내일 도착)
  listPrice?: number; // 할인 전 가격. 있으면 price보다 커야 한다
  options?: ProductOption[]; // 고를 수 있는 옵션
  giftWrap?: boolean; // 선물 포장 가능
  tags: string[]; // 쓰임새: "집들이", "생일", "감사", "나를 위한", "커플", "아이", "반려동물" 등
  similar?: string[]; // 비교하기 좋은 비슷한 상품 id
}
