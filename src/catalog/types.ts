export interface Product {
  id: string; // 예: "p01"
  name: string;
  price: number; // 원
  category: string;
  emoji: string;
  tint: [string, string]; // 이미지 영역 그라데이션 두 색
  features: string[];
  tradeoff: { pro: string; con: string }; // 카드에 한 줄로: "분위기 최고 · 향 호불호가 있음"
  rating: number;
  reviews: string[]; // 짧은 리뷰 3개
  returnPolicy: string; // 예: "무료 반품 7일"
}
