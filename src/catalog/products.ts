// 데모용 목 카탈로그 72개, 13개 카테고리.
// 데모 시나리오의 세 상품(p01 캔들, p04 몬스테라, p07 드립 세트)은 이름·가격·트레이드오프를 바꾸지 말 것.
// 일부러 넣은 상황: 품절(stock 0), 얼마 안 남음(1~3), 할인(listPrice), 오래 걸리는 배송(shipDays 4~7), 옵션, similar 비교 묶음.
import type { Product } from './types';

export const BUDGET = 80_000;

export const products: Product[] = [
  // ── 캔들·디퓨저 ──
  {
    id: 'p01', name: '소이 캔들 3종 세트', price: 32_000, category: '캔들·디퓨저', emoji: '🕯️', tint: ['#FFF4E8', '#FCE3D0'],
    features: ['라벤더 · 우디 · 시트러스 3종', '각 120g, 약 30시간 연소', '선물 포장 박스 기본'],
    tradeoff: { pro: '분위기 최고', con: '향 호불호' }, rating: 4.6,
    reviews: ['포장이 예뻐요', '향이 오래가요', '시트러스는 조금 강해요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 24, shipDays: 1, giftWrap: true, tags: ['집들이', '생일', '감사'], similar: ['p25', 'p26'],
  },
  {
    id: 'p02', name: '리드 디퓨저 200ml', price: 28_000, category: '캔들·디퓨저', emoji: '🌾', tint: ['#F6F1FA', '#E6DCF0'],
    features: ['약 2~3개월 사용', '유리병 + 리드 8개', '향 3종 중 선택'],
    tradeoff: { pro: '불 없이 은은함', con: '향이 약하다는 후기' }, rating: 4.3,
    reviews: ['현관에 두기 딱', '은은해서 좋아요', '한 달 지나니 향이 확 약해져요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 0, shipDays: 2, giftWrap: true, options: [{ name: '향', values: ['화이트 머스크', '블랙체리', '피오니'] }],
    tags: ['집들이', '회사 동료'], similar: ['p27'],
  },
  {
    id: 'p03', name: '아로마 캔들 워머 램프', price: 89_000, listPrice: 109_000, category: '캔들·디퓨저', emoji: '🏮', tint: ['#FFF1E0', '#F6D9B8'],
    features: ['할로겐 전구로 캔들을 녹여 발향', '타이머 · 밝기 조절', '캔들 1개 포함'],
    tradeoff: { pro: '그을음 없이 안전', con: '예산 초과' }, rating: 4.7,
    reviews: ['인테리어 효과 최고', '캔들이 오래 써져요', '전구가 생각보다 뜨거워요'], returnPolicy: '무료 반품 14일',
    stock: 5, shipDays: 2, giftWrap: true, tags: ['집들이', '나를 위한'],
  },
  {
    id: 'p25', name: '우드윅 캔들 라지', price: 46_000, category: '캔들·디퓨저', emoji: '🔥', tint: ['#FBEFE4', '#EED6C0'],
    features: ['나무 심지가 타닥타닥 소리', '약 60시간 연소', '향 2종 중 선택'],
    tradeoff: { pro: '소리까지 분위기', con: '심지 관리가 까다로움' }, rating: 4.5,
    reviews: ['장작 소리가 힐링이에요', '향이 진해요', '심지 안 자르면 그을음이 나요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 2, shipDays: 1, giftWrap: true, options: [{ name: '향', values: ['시더우드', '바닐라'] }],
    tags: ['생일', '커플'], similar: ['p01', 'p26'],
  },
  {
    id: 'p26', name: '미니 캔들 6종 샘플러', price: 19_000, listPrice: 24_000, category: '캔들·디퓨저', emoji: '🧁', tint: ['#FFF6EE', '#F7E2D2'],
    features: ['40g 미니 캔들 6개', '각 약 10시간 연소', '향 비교용 카드'],
    tradeoff: { pro: '여러 향을 맛보기', con: '하나하나가 금방 닳음' }, rating: 4.2,
    reviews: ['향 고르기 전에 좋아요', '가성비 좋아요', '너무 작아서 금방 끝나요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 30, shipDays: 1, giftWrap: true, tags: ['회사 동료', '감사'], similar: ['p01', 'p25'],
  },
  {
    id: 'p27', name: '차량용 디퓨저 클립', price: 15_000, category: '캔들·디퓨저', emoji: '🚗', tint: ['#EEF2F6', '#D8E0EA'],
    features: ['송풍구 클립형', '리필 패드 3개', '약 1개월 지속'],
    tradeoff: { pro: '차 있는 사람에게 실용적', con: '차가 없으면 쓸 데가 없음' }, rating: 4.0,
    reviews: ['차 냄새가 잡혀요', '디자인이 깔끔해요', '여름엔 향이 너무 빨리 날아가요'], returnPolicy: '무료 반품 7일',
    stock: 40, shipDays: 1, tags: ['회사 동료', '부모님'], similar: ['p02'],
  },

  // ── 식물 ──
  {
    id: 'p04', name: '미니 몬스테라 화분', price: 45_000, category: '식물', emoji: '🪴', tint: ['#F0F7EC', '#DCEBD6'],
    features: ['세라믹 화분 포함, 높이 약 40cm', '공기 정화 식물', '관리 가이드 카드 동봉'],
    tradeoff: { pro: '오래 남음', con: '물 주기 관리 필요' }, rating: 4.5,
    reviews: ['잎이 싱싱해요', '생각보다 커요', '포장이 꼼꼼해요'], returnPolicy: '생물이라 단순 변심 반품 불가, 파손 시 교환',
    stock: 12, shipDays: 2, giftWrap: true, tags: ['집들이'], similar: ['p05', 'p28'],
  },
  {
    id: 'p05', name: '스투키 미니 화분', price: 19_000, category: '식물', emoji: '🌵', tint: ['#EEF5EA', '#D5E6CC'],
    features: ['한 달에 한 번 물 주기', '높이 약 25cm', '시멘트 화분'],
    tradeoff: { pro: '거의 안 죽음', con: '모양이 밋밋함' }, rating: 4.4,
    reviews: ['키우기 정말 쉬워요', '책상에 두기 좋아요', '좀 심심해 보여요'], returnPolicy: '생물이라 단순 변심 반품 불가, 파손 시 교환',
    stock: 18, shipDays: 2, tags: ['집들이', '회사 동료'], similar: ['p04', 'p28'],
  },
  {
    id: 'p06', name: '테라리움 만들기 키트', price: 36_000, category: '식물', emoji: '🫙', tint: ['#EAF4F1', '#CFE6DE'],
    features: ['유리병 · 이끼 · 미니 피규어', '설명서 + 영상 가이드', '완성 높이 약 15cm'],
    tradeoff: { pro: '만드는 재미', con: '조립 시간 필요' }, rating: 4.5,
    reviews: ['같이 만들면 재밌어요', '완성하면 예뻐요', '1시간 넘게 걸렸어요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 0, shipDays: 3, tags: ['아이', '커플'],
  },
  {
    id: 'p28', name: '올리브나무 중형', price: 92_000, category: '식물', emoji: '🌳', tint: ['#EFF3E6', '#D7E0C4'],
    features: ['높이 약 90cm', '토분 포함', '화물 배송'],
    tradeoff: { pro: '거실 분위기가 확 바뀜', con: '크고 배송이 오래 걸림' }, rating: 4.6,
    reviews: ['거실 포인트가 됐어요', '잎이 은빛이라 예뻐요', '받는 데 일주일 가까이 걸렸어요'], returnPolicy: '생물이라 단순 변심 반품 불가, 파손 시 교환',
    stock: 3, shipDays: 5, tags: ['집들이', '부모님'], similar: ['p04', 'p05'],
  },
  {
    id: 'p36', name: '프리저브드 플라워 박스', price: 54_000, listPrice: 64_000, category: '식물', emoji: '🌹', tint: ['#FCEEF1', '#F2D3DB'],
    features: ['물 없이 1~2년 유지', '원형 박스', '메시지 카드 포함'],
    tradeoff: { pro: '시들지 않는 꽃', con: '먼지가 쌓이면 관리가 어려움' }, rating: 4.4,
    reviews: ['받자마자 감동했대요', '색이 사진이랑 같아요', '뚜껑 열면 먼지가 금방 앉아요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 8, shipDays: 1, giftWrap: true, options: [{ name: '색', values: ['로즈 핑크', '화이트'] }],
    tags: ['생일', '커플', '부모님'],
  },

  // ── 커피·차 ──
  {
    id: 'p07', name: '핸드드립 입문 세트', price: 78_000, category: '커피·차', emoji: '☕', tint: ['#F7EFE9', '#EBDCD2'],
    features: ['드리퍼 · 서버 · 필터 40매 · 원두 200g', '입문 레시피 카드', '선물 포장 가능'],
    tradeoff: { pro: '매일 씀', con: '예산을 거의 다 씀' }, rating: 4.8,
    reviews: ['선물용으로 딱', '원두가 신선해요', '커피 안 마시면 쓸 일이 없어요'], returnPolicy: '무료 반품 7일',
    stock: 9, shipDays: 1, giftWrap: true, tags: ['집들이', '생일'], similar: ['p29', 'p30'],
  },
  {
    id: 'p08', name: '티 샘플러 12종', price: 24_000, category: '커피·차', emoji: '🍵', tint: ['#F3F6E8', '#E1E8C8'],
    features: ['녹차 · 홍차 · 허브티 12종', '티백 24개', '틴 케이스'],
    tradeoff: { pro: '취향 탐색에 좋음', con: '양이 적음' }, rating: 4.4,
    reviews: ['골라 마시는 재미', '케이스가 예뻐요', '금방 다 마셔요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 25, shipDays: 1, giftWrap: true, tags: ['감사', '회사 동료'], similar: ['p31'],
  },
  {
    id: 'p09', name: '전자동 커피머신', price: 189_000, listPrice: 229_000, category: '커피·차', emoji: '🤖', tint: ['#EFEDEC', '#D9D4D1'],
    features: ['원두 분쇄부터 추출까지 자동', '우유 스팀 노즐', '물통 1.2L'],
    tradeoff: { pro: '버튼 하나로 에스프레소', con: '예산 두 배 이상' }, rating: 4.6,
    reviews: ['카페 안 가게 돼요', '소음이 좀 있어요', '청소가 귀찮아요'], returnPolicy: '무료 반품 14일',
    stock: 4, shipDays: 3, tags: ['집들이', '부모님'],
  },
  {
    id: 'p29', name: '모카포트 2인 세트', price: 42_000, category: '커피·차', emoji: '🫖', tint: ['#F4EEEA', '#E3D6CE'],
    features: ['모카포트 2인용', '에스프레소 잔 2개', '가스레인지 · 인덕션 겸용'],
    tradeoff: { pro: '진한 커피를 집에서', con: '사용법을 익혀야 함' }, rating: 4.5,
    reviews: ['커플 선물로 했어요', '향이 진해요', '처음엔 넘쳐서 고생했어요'], returnPolicy: '무료 반품 7일',
    stock: 1, shipDays: 2, giftWrap: true, options: [{ name: '색', values: ['실버', '레드'] }],
    tags: ['커플', '나를 위한'], similar: ['p07', 'p30'],
  },
  {
    id: 'p30', name: '콜드브루 보틀 1L', price: 23_000, category: '커피·차', emoji: '🧊', tint: ['#EAF1F5', '#D3E1EA'],
    features: ['내열 유리 보틀', '미세 필터 내장', '냉장고 문 수납 크기'],
    tradeoff: { pro: '여름에 최고', con: '추출에 12시간' }, rating: 4.3,
    reviews: ['여름 내내 썼어요', '세척이 쉬워요', '겨울엔 손이 안 가요'], returnPolicy: '무료 반품 7일',
    stock: 0, shipDays: 1, tags: ['나를 위한'], similar: ['p07', 'p29'],
  },
  {
    id: 'p31', name: '블렌딩 티 만들기 키트', price: 31_000, category: '커피·차', emoji: '🌿', tint: ['#F1F5EC', '#DCE6CF'],
    features: ['찻잎 · 꽃잎 8종', '빈 티백 30개', '블렌딩 레시피북'],
    tradeoff: { pro: '같이 만드는 재미', con: '수제 포장이라 배송이 늦음' }, rating: 4.3,
    reviews: ['레시피가 친절해요', '향이 좋아요', '주문하고 일주일 걸렸어요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 14, shipDays: 6, giftWrap: true, tags: ['커플', '생일'], similar: ['p08'],
  },

  // ── 주방 ──
  {
    id: 'p10', name: '원목 도마 & 치즈나이프 세트', price: 39_000, category: '주방', emoji: '🧀', tint: ['#FAF2E6', '#EEDCC0'],
    features: ['월넛 원목 도마', '치즈나이프 3종', '집들이 플레이팅용'],
    tradeoff: { pro: '오래 씀', con: '오일 관리 필요' }, rating: 4.6,
    reviews: ['플레이팅이 살아나요', '나무 결이 예뻐요', '물에 오래 두면 안 돼요'], returnPolicy: '무료 반품 7일',
    stock: 0, shipDays: 2, giftWrap: true, tags: ['집들이', '커플'], similar: ['p32'],
  },
  {
    id: 'p11', name: '내열 유리 밀폐용기 5종', price: 29_000, category: '주방', emoji: '🥡', tint: ['#EEF4F8', '#D6E4EE'],
    features: ['오븐 · 전자레인지 사용 가능', '사이즈 5종', '실리콘 패킹 뚜껑'],
    tradeoff: { pro: '실용성 최고', con: '선물 느낌이 약함' }, rating: 4.7,
    reviews: ['매일 써요', '튼튼해요', '선물로는 좀 평범해요'], returnPolicy: '무료 반품 7일',
    stock: 50, shipDays: 1, tags: ['집들이', '부모님'],
  },
  {
    id: 'p12', name: '무쇠 주물 냄비 22cm', price: 129_000, category: '주방', emoji: '🍲', tint: ['#FBEDEA', '#F0D2CB'],
    features: ['법랑 코팅 주물', '인덕션 · 오븐 겸용', '컬러 4종'],
    tradeoff: { pro: '평생 씀', con: '무겁고 예산 초과' }, rating: 4.9,
    reviews: ['요리가 맛있어져요', '색이 정말 예뻐요', '너무 무거워요'], returnPolicy: '무료 반품 14일',
    stock: 6, shipDays: 2, options: [{ name: '색', values: ['체리', '세이지', '크림', '블랙'] }], tags: ['집들이', '부모님'],
  },
  {
    id: 'p32', name: '수제 세라믹 플레이트 2P', price: 34_000, category: '주방', emoji: '🍽️', tint: ['#F5F2EE', '#E4DDD4'],
    features: ['지름 24cm', '작가 수작업, 무늬가 하나씩 다름', '주문 후 제작'],
    tradeoff: { pro: '세상에 하나뿐인 그릇', con: '제작 기간이 김' }, rating: 4.7,
    reviews: ['식탁이 갤러리 같아요', '무게감이 좋아요', '받기까지 일주일 넘게 걸렸어요'], returnPolicy: '주문 제작이라 단순 변심 반품 불가',
    stock: 7, shipDays: 7, giftWrap: true, tags: ['집들이', '커플'], similar: ['p10'],
  },
  {
    id: 'p37', name: '실리콘 주방도구 5종', price: 17_000, category: '주방', emoji: '🥄', tint: ['#F3F3EF', '#E0E0D8'],
    features: ['뒤집개 · 국자 · 주걱 등 5종', '내열 230도', '거치 스탠드'],
    tradeoff: { pro: '부담 없이 실용적', con: '설렘은 적음' }, rating: 4.3,
    reviews: ['코팅 팬에 딱', '색이 차분해요', '스탠드가 좀 가벼워요'], returnPolicy: '무료 반품 7일',
    stock: 60, shipDays: 1, tags: ['집들이'],
  },
  {
    id: 'p38', name: '스텐 텀블러 473ml', price: 27_000, category: '주방', emoji: '🥤', tint: ['#EEF1EE', '#D8DED8'],
    features: ['이중 진공 보온 · 보냉', '슬라이드 뚜껑', '이니셜 각인 가능'],
    tradeoff: { pro: '매일 들고 다님', con: '흔한 선물' }, rating: 4.5,
    reviews: ['얼음이 하루 가요', '각인이 예뻐요', '뚜껑 틈 세척이 번거로워요'], returnPolicy: '각인 시 반품 불가, 미각인 무료 반품 7일',
    stock: 2, shipDays: 1, giftWrap: true, tags: ['회사 동료', '생일'],
  },

  // ── 패브릭 ──
  {
    id: 'p13', name: '와플 코튼 담요', price: 49_000, category: '패브릭', emoji: '🛋️', tint: ['#F7F3EE', '#E8DFD3'],
    features: ['면 100% 와플 조직', '150 × 200cm', '세탁기 사용 가능'],
    tradeoff: { pro: '포근함', con: '색 취향을 탐' }, rating: 4.5,
    reviews: ['감촉이 좋아요', '소파에 걸치기 좋아요', '색이 사진과 조금 달라요'], returnPolicy: '무료 반품 7일',
    stock: 11, shipDays: 2, giftWrap: true, options: [{ name: '색', values: ['오트밀', '그레이', '세이지'] }],
    tags: ['집들이', '부모님'], similar: ['p33'],
  },
  {
    id: 'p14', name: '린넨 키친타월 3P', price: 18_000, category: '패브릭', emoji: '🧻', tint: ['#F4F2EC', '#E2DDD0'],
    features: ['린넨 혼방', '3가지 패턴', '흡수력 좋음'],
    tradeoff: { pro: '부담 없는 가격', con: '존재감이 약함' }, rating: 4.2,
    reviews: ['가볍게 주기 좋아요', '잘 말라요', '선물로는 소소해요'], returnPolicy: '무료 반품 7일',
    stock: 33, shipDays: 1, giftWrap: true, tags: ['집들이', '회사 동료'],
  },
  {
    id: 'p15', name: '부클레 쿠션 커버 2P', price: 34_000, category: '패브릭', emoji: '🧸', tint: ['#F8F1EC', '#EADBCF'],
    features: ['부클레 원단', '45 × 45cm', '지퍼 마감'],
    tradeoff: { pro: '집 분위기가 바뀜', con: '쿠션 크기를 맞춰야 함' }, rating: 4.3,
    reviews: ['거실이 화사해져요', '촉감이 좋아요', '속통은 따로 사야 해요'], returnPolicy: '무료 반품 7일',
    stock: 9, shipDays: 2, tags: ['집들이'],
  },
  {
    id: 'p33', name: '극세사 수면 담요', price: 25_000, listPrice: 32_000, category: '패브릭', emoji: '🐑', tint: ['#FBF0F2', '#EFD9DE'],
    features: ['극세사 양면', '130 × 180cm', '정전기 방지 가공'],
    tradeoff: { pro: '겨울에 제일 따뜻함', con: '보풀이 생김' }, rating: 4.2,
    reviews: ['진짜 따뜻해요', '아이가 끌어안고 자요', '두 번 빨았더니 보풀이 생겼어요'], returnPolicy: '무료 반품 7일',
    stock: 40, shipDays: 1, giftWrap: true, options: [{ name: '색', values: ['핑크', '베이지'] }],
    tags: ['나를 위한', '아이'], similar: ['p13'],
  },
  {
    id: 'p39', name: '린넨 앞치마', price: 29_000, category: '패브릭', emoji: '👘', tint: ['#F2EFE8', '#DED8CA'],
    features: ['워싱 린넨', '크로스 끈', '앞주머니 2개'],
    tradeoff: { pro: '요리하는 사람에게 딱', con: '구김이 잘 감' }, rating: 4.4,
    reviews: ['사진 찍으면 예뻐요', '주머니가 깊어요', '다림질 안 하면 쭈글쭈글해요'], returnPolicy: '무료 반품 7일',
    stock: 0, shipDays: 2, tags: ['커플', '집들이'],
  },

  // ── 조명 ──
  {
    id: 'p16', name: '무드 조명 스탠드', price: 59_000, category: '조명', emoji: '💡', tint: ['#FFF7E3', '#F7E6BC'],
    features: ['3단계 색온도', '패브릭 갓', '높이 45cm'],
    tradeoff: { pro: '밤 분위기가 살아남', con: '자리를 차지함' }, rating: 4.6,
    reviews: ['불빛이 따뜻해요', '침대 옆에 딱', '생각보다 커요'], returnPolicy: '무료 반품 14일',
    stock: 8, shipDays: 2, tags: ['집들이', '나를 위한'], similar: ['p17', 'p34'],
  },
  {
    id: 'p17', name: 'LED 캔들 라이트 3P', price: 26_000, category: '조명', emoji: '🔆', tint: ['#FFF8EC', '#F5E5C9'],
    features: ['흔들리는 불꽃 효과', '리모컨 · 타이머', '건전지 포함'],
    tradeoff: { pro: '불 걱정 없음', con: '진짜 촛불 느낌은 덜함' }, rating: 4.1,
    reviews: ['아이 있는 집에 좋아요', '분위기 내기 쉬워요', '가까이서 보면 티 나요'], returnPolicy: '무료 반품 7일',
    stock: 20, shipDays: 1, tags: ['아이', '부모님'], similar: ['p16', 'p34'],
  },
  {
    id: 'p18', name: '디자이너 펜던트 조명', price: 145_000, category: '조명', emoji: '🪩', tint: ['#F2EFEA', '#DDD6CC'],
    features: ['유리 셰이드', '길이 조절 코드', '주문 후 제작'],
    tradeoff: { pro: '인테리어 포인트', con: '설치가 필요하고 예산 초과' }, rating: 4.7,
    reviews: ['집이 달라 보여요', '빛이 예쁘게 퍼져요', '설치 기사를 불렀어요'], returnPolicy: '설치 전 무료 반품 14일',
    stock: 6, shipDays: 7, tags: ['집들이'],
  },
  {
    id: 'p34', name: '달 무드등 15cm', price: 33_000, listPrice: 39_000, category: '조명', emoji: '🌕', tint: ['#FAF6EA', '#ECE3C8'],
    features: ['3D 프린팅 달 표면', '16색 터치 조절', 'USB 충전, 원목 받침'],
    tradeoff: { pro: '보자마자 예쁨', con: '밝기가 약해 조명으로는 부족' }, rating: 4.4,
    reviews: ['아이 방에 뒀어요', '선물 반응 최고', '책 읽기엔 어두워요'], returnPolicy: '무료 반품 7일',
    stock: 15, shipDays: 1, giftWrap: true, tags: ['생일', '아이', '커플'], similar: ['p16', 'p17'],
  },
  {
    id: 'p42', name: '클립형 독서등', price: 18_000, category: '조명', emoji: '📖', tint: ['#F1F3F5', '#DCE1E6'],
    features: ['집게형 고정', '3단 밝기', '충전식 8시간'],
    tradeoff: { pro: '눈이 편함', con: '디자인은 평범' }, rating: 4.2,
    reviews: ['부모님이 잘 쓰세요', '가벼워요', '집게가 두꺼운 책엔 안 물려요'], returnPolicy: '무료 반품 7일',
    stock: 25, shipDays: 1, tags: ['나를 위한', '부모님'],
  },

  // ── 수납 ──
  {
    id: 'p19', name: '라탄 바구니 세트', price: 42_000, category: '수납', emoji: '🧺', tint: ['#FAF3E7', '#EDDDC2'],
    features: ['대 · 중 · 소 3개', '천연 라탄 수작업', '면 이너백'],
    tradeoff: { pro: '정리와 장식을 동시에', con: '먼지가 끼기 쉬움' }, rating: 4.4,
    reviews: ['어디 둬도 예뻐요', '튼튼해요', '틈에 먼지가 껴요'], returnPolicy: '무료 반품 7일',
    stock: 6, shipDays: 4, tags: ['집들이'],
  },
  {
    id: 'p20', name: '원목 트레이', price: 21_000, category: '수납', emoji: '🪵', tint: ['#F7EEE3', '#E8D6BF'],
    features: ['오크 원목', '38 × 26cm', '손잡이 홈'],
    tradeoff: { pro: '어디든 잘 어울림', con: '평범할 수 있음' }, rating: 4.3,
    reviews: ['커피 마실 때 써요', '마감이 깔끔해요', '조금 작아요'], returnPolicy: '무료 반품 7일',
    stock: 14, shipDays: 1, giftWrap: true, tags: ['집들이', '감사'],
  },
  {
    id: 'p21', name: '모듈 선반 3단', price: 68_000, category: '수납', emoji: '📚', tint: ['#F1F1EE', '#DCDCD4'],
    features: ['칸 추가 가능 모듈형', '공구 없이 조립', '화이트 · 오크'],
    tradeoff: { pro: '실용성 높음', con: '부피가 커서 배송이 번거로움' }, rating: 4.2,
    reviews: ['조립이 쉬워요', '수납이 많이 돼요', '박스가 엄청 커요'], returnPolicy: '무료 반품 7일 (미조립)',
    stock: 10, shipDays: 5, tags: ['집들이'],
  },
  {
    id: 'p43', name: '아크릴 액세서리 정리함', price: 16_000, category: '수납', emoji: '💍', tint: ['#F5F1F7', '#E3DAE8'],
    features: ['투명 아크릴 3단 서랍', '반지 · 귀걸이 칸', '벨벳 바닥'],
    tradeoff: { pro: '화장대가 깔끔해짐', con: '지문이 잘 묻음' }, rating: 4.3,
    reviews: ['한눈에 보여서 좋아요', '생일 선물로 줬어요', '지문 닦기 귀찮아요'], returnPolicy: '무료 반품 7일',
    stock: 0, shipDays: 1, tags: ['나를 위한', '생일'],
  },
  {
    id: 'p44', name: '패브릭 수납함 3P', price: 24_000, category: '수납', emoji: '📦', tint: ['#F2F0EC', '#DFDBD2'],
    features: ['접이식', '손잡이 달림', '30 × 30cm 큐브'],
    tradeoff: { pro: '어디든 들어감', con: '세워 두면 쳐짐' }, rating: 4.1,
    reviews: ['선반에 딱 맞아요', '가벼워요', '모서리가 조금 처져요'], returnPolicy: '무료 반품 7일',
    stock: 30, shipDays: 1, tags: ['집들이'],
  },

  // ── 욕실 ──
  {
    id: 'p22', name: '호텔 수건 4P', price: 38_000, category: '욕실', emoji: '🛁', tint: ['#EFF4F7', '#D8E3EA'],
    features: ['코마사 40수', '200g 두께', '이니셜 자수 가능'],
    tradeoff: { pro: '누구나 씀', con: '흔한 선물' }, rating: 4.6,
    reviews: ['보송보송해요', '빨아도 안 줄어요', '선물로는 무난해요'], returnPolicy: '무료 반품 7일 (미사용)',
    stock: 18, shipDays: 1, giftWrap: true, tags: ['집들이', '부모님', '감사'], similar: ['p35'],
  },
  {
    id: 'p23', name: '핸드워시 & 로션 세트', price: 33_000, category: '욕실', emoji: '🧴', tint: ['#F5F0F4', '#E6DAE3'],
    features: ['각 300ml', '무화과 향', '펌프형 유리병'],
    tradeoff: { pro: '고급스러워 보임', con: '금방 다 씀' }, rating: 4.5,
    reviews: ['향이 고급스러워요', '병이 예뻐요', '한 달이면 다 써요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 13, shipDays: 1, giftWrap: true, tags: ['집들이', '감사'],
  },
  {
    id: 'p24', name: '규조토 발매트', price: 25_000, category: '욕실', emoji: '🫧', tint: ['#F1F3F1', '#DCE1DC'],
    features: ['물기가 바로 마름', '60 × 39cm', '사포 동봉'],
    tradeoff: { pro: '바로 마름', con: '떨어뜨리면 깨짐' }, rating: 4.3,
    reviews: ['신기하게 바로 말라요', '위생적이에요', '모서리가 깨졌어요'], returnPolicy: '무료 반품 7일',
    stock: 22, shipDays: 2, tags: ['집들이'],
  },
  {
    id: 'p35', name: '유기농 코튼 수건 2P', price: 29_000, category: '욕실', emoji: '🤍', tint: ['#F3F5F2', '#DFE5DC'],
    features: ['유기농 면 인증', '무형광 · 무염색', '아기 피부에도 순함'],
    tradeoff: { pro: '피부에 순함', con: '흡수력은 호텔 수건보다 덜함' }, rating: 4.4,
    reviews: ['아기 목욕 후에 써요', '부드러워요', '얇아서 흡수가 아쉬워요'], returnPolicy: '무료 반품 7일 (미사용)',
    stock: 12, shipDays: 1, giftWrap: true, tags: ['감사', '아이'], similar: ['p22'],
  },
  {
    id: 'p47', name: '입욕제 선물 세트', price: 9_900, category: '욕실', emoji: '🛀', tint: ['#F7F0F8', '#E8DAEC'],
    features: ['배스밤 4개', '천연 에센셜 오일', '종이 상자 포장'],
    tradeoff: { pro: '작지만 기분 좋은 선물', con: '욕조가 없으면 못 씀' }, rating: 4.2,
    reviews: ['색이 예뻐요', '향이 은은해요', '욕조 없는 집이라 못 썼어요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 45, shipDays: 1, giftWrap: true, tags: ['생일', '회사 동료', '나를 위한'],
  },

  // ── 뷰티·향수 ──
  {
    id: 'p40', name: '핸드크림 3종 세트', price: 19_000, category: '뷰티·향수', emoji: '🤲', tint: ['#FBF3EE', '#EFDCD0'],
    features: ['30ml × 3', '로즈 · 무화과 · 코튼', '끈적임 적은 제형'],
    tradeoff: { pro: '누구에게나 무난', con: '흔한 선물' }, rating: 4.4,
    reviews: ['파우치에 쏙 들어가요', '향이 은은해요', '보습력은 보통이에요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 40, shipDays: 1, giftWrap: true, tags: ['회사 동료', '감사'], similar: ['p41'],
  },
  {
    id: 'p41', name: '시어버터 핸드크림 대용량', price: 27_000, listPrice: 30_000, category: '뷰티·향수', emoji: '🧈', tint: ['#FAF5E8', '#EDE3C6'],
    features: ['150ml 튜브', '시어버터 20%', '향 2종 중 선택'],
    tradeoff: { pro: '보습력 최고', con: '조금 무거운 제형' }, rating: 4.7,
    reviews: ['겨울 필수템', '부모님이 좋아하세요', '바르고 나면 좀 미끈거려요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 2, shipDays: 1, giftWrap: true, options: [{ name: '향', values: ['무향', '라벤더'] }],
    tags: ['부모님', '나를 위한'], similar: ['p40'],
  },
  {
    id: 'p48', name: '니치 향수 30ml', price: 89_000, category: '뷰티·향수', emoji: '🌸', tint: ['#F6EEF3', '#E7D5E1'],
    features: ['오 드 퍼퓸', '향 2종 중 선택', '시향지 동봉'],
    tradeoff: { pro: '특별한 날 선물', con: '향 취향을 모르면 위험' }, rating: 4.5,
    reviews: ['지속력이 좋아요', '병이 고급스러워요', '생각보다 무거운 향이었어요'], returnPolicy: '개봉 시 반품 불가',
    stock: 5, shipDays: 2, giftWrap: true, options: [{ name: '향', values: ['우디 앰버', '화이트 티'] }],
    tags: ['생일', '커플'],
  },
  {
    id: 'p49', name: '립밤 3종', price: 8_900, category: '뷰티·향수', emoji: '💋', tint: ['#FCEFEF', '#F0D6D6'],
    features: ['무색 · 코랄 · 체리', '시어버터 함유', '스틱형'],
    tradeoff: { pro: '부담 없는 가격', con: '선물 느낌은 약함' }, rating: 4.1,
    reviews: ['가볍게 돌리기 좋아요', '발림성 좋아요', '체리는 색이 거의 안 나요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 70, shipDays: 1, tags: ['회사 동료', '생일'],
  },
  {
    id: 'p54', name: '옥 괄사 & 롤러 세트', price: 56_000, category: '뷰티·향수', emoji: '💆', tint: ['#EEF5F2', '#D5E6DE'],
    features: ['천연 옥 괄사 + 롤러', '양쪽 크기 다른 헤드', '실크 파우치 포함'],
    tradeoff: { pro: '아침 붓기 관리', con: '효과는 사람마다 다름' }, rating: 3.9,
    reviews: ['차갑게 해 두면 시원해요', '디자인이 예뻐요', '효과는 잘 모르겠어요'], returnPolicy: '무료 반품 7일',
    stock: 14, shipDays: 1, tags: ['부모님', '나를 위한'],
  },
  {
    id: 'p55', name: '고체 향수 틴', price: 9_500, category: '뷰티·향수', emoji: '🪙', tint: ['#F5F2EA', '#E3DDCB'],
    features: ['15g 틴 케이스', '머스크 향', '천연 밀랍 베이스'],
    tradeoff: { pro: '들고 다니기 좋음', con: '지속력이 짧음' }, rating: 4.0,
    reviews: ['주머니에 쏙', '향이 순해요', '두 시간이면 날아가요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 26, shipDays: 1, giftWrap: true, tags: ['회사 동료', '감사'],
  },

  // ── 문구·취미 ──
  {
    id: 'p45', name: '가죽 커버 다이어리 2027', price: 26_000, category: '문구·취미', emoji: '📔', tint: ['#F4EDE6', '#E2D2C3'],
    features: ['소가죽 커버', '만년 위클리 속지', '이니셜 각인 가능'],
    tradeoff: { pro: '1년 내내 곁에 둠', con: '다이어리 안 쓰는 사람도 많음' }, rating: 4.4,
    reviews: ['가죽 냄새가 좋아요', '각인이 고급져요', '종이가 얇아 비쳐요'], returnPolicy: '각인 시 반품 불가, 미각인 무료 반품 7일',
    stock: 15, shipDays: 1, giftWrap: true, options: [{ name: '색', values: ['브라운', '블랙', '버건디'] }],
    tags: ['회사 동료', '생일'], similar: ['p46'],
  },
  {
    id: 'p46', name: '만년필 입문 세트', price: 48_000, listPrice: 56_000, category: '문구·취미', emoji: '🖋️', tint: ['#EEF0F4', '#D7DBE5'],
    features: ['EF촉 만년필', '병잉크 + 컨버터', '선물 상자'],
    tradeoff: { pro: '오래 기억에 남음', con: '잉크 관리가 번거로움' }, rating: 4.6,
    reviews: ['필기감이 부드러워요', '아버지가 좋아하셨어요', '처음엔 손에 잉크가 묻어요'], returnPolicy: '무료 반품 7일 (미사용)',
    stock: 3, shipDays: 2, giftWrap: true, tags: ['감사', '부모님'], similar: ['p45'],
  },
  {
    id: 'p58', name: '명화 퍼즐 1000피스', price: 21_000, category: '문구·취미', emoji: '🧩', tint: ['#EEF2F7', '#D6DEEA'],
    features: ['고흐 · 모네 중 랜덤', '완성 75 × 50cm', '접착제 포함'],
    tradeoff: { pro: '둘이 같이 하기 좋음', con: '완성까지 오래 걸림' }, rating: 4.3,
    reviews: ['주말 내내 했어요', '인쇄 품질 좋아요', '한 조각이 빠져 있었어요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 12, shipDays: 2, tags: ['커플', '나를 위한'],
  },
  {
    id: 'p59', name: '수채화 입문 키트', price: 34_000, category: '문구·취미', emoji: '🎨', tint: ['#F3F0F8', '#DFD8EC'],
    features: ['고체 물감 24색', '붓 3종 + 스케치북', '영상 강의 링크'],
    tradeoff: { pro: '새 취미를 선물', con: '해외 배송이라 늦음' }, rating: 4.5,
    reviews: ['발색이 예뻐요', '아이랑 같이 써요', '도착까지 5일 걸렸어요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 9, shipDays: 4, giftWrap: true, tags: ['나를 위한', '아이'],
  },
  {
    id: 'p60', name: '일러스트 엽서 30장', price: 7_500, category: '문구·취미', emoji: '💌', tint: ['#FBF2EC', '#F0DCCF'],
    features: ['작가 일러스트 30종', '봉투 10장', '스티커 1장'],
    tradeoff: { pro: '선물에 곁들이기 좋음', con: '단독 선물로는 약함' }, rating: 4.4,
    reviews: ['그림이 다 달라서 좋아요', '종이가 두꺼워요', '봉투가 좀 부족해요'], returnPolicy: '무료 반품 7일',
    stock: 80, shipDays: 1, tags: ['감사', '회사 동료'],
  },
  {
    id: 'p61', name: '일회용 필름 카메라 2P', price: 24_000, category: '문구·취미', emoji: '📷', tint: ['#F1F1F1', '#DCDCDC'],
    features: ['27컷 × 2개', '플래시 내장', '현상 쿠폰 1장'],
    tradeoff: { pro: '추억이 남음', con: '현상 비용이 따로 듦' }, rating: 4.5,
    reviews: ['여행 가서 썼어요', '감성 사진이 나와요', '현상비가 생각보다 비싸요'], returnPolicy: '무료 반품 7일 (미개봉)',
    stock: 0, shipDays: 1, tags: ['커플', '생일'],
  },

  // ── 테크 소품 ──
  {
    id: 'p50', name: '3in1 무선 충전 거치대', price: 59_000, category: '테크 소품', emoji: '🔋', tint: ['#EEF0F3', '#D6DAE1'],
    features: ['폰 · 이어폰 · 워치 동시 충전', '최대 15W', '어댑터 포함'],
    tradeoff: { pro: '책상이 깔끔해짐', con: '기종에 따라 호환이 다름' }, rating: 4.4,
    reviews: ['선이 하나라 좋아요', '디자인이 깔끔해요', '갤럭시 워치는 안 돼요'], returnPolicy: '무료 반품 14일',
    stock: 6, shipDays: 1, giftWrap: true, options: [{ name: '색', values: ['화이트', '블랙'] }],
    tags: ['회사 동료', '생일'], similar: ['p51'],
  },
  {
    id: 'p51', name: '무선 충전 패드', price: 25_000, listPrice: 29_000, category: '테크 소품', emoji: '🔌', tint: ['#EFF2F1', '#D9DFDD'],
    features: ['최대 10W', '미끄럼 방지 패드', 'C타입 케이블 포함'],
    tradeoff: { pro: '가볍게 주기 좋음', con: '어댑터는 따로' }, rating: 4.1,
    reviews: ['침대 옆에 두고 써요', '가성비 좋아요', '위치 맞추기가 까다로워요'], returnPolicy: '무료 반품 14일',
    stock: 30, shipDays: 1, tags: ['회사 동료'], similar: ['p50'],
  },
  {
    id: 'p52', name: '휴대용 블루투스 스피커', price: 49_000, category: '테크 소품', emoji: '🔊', tint: ['#EAF4F2', '#CFE5E0'],
    features: ['방수 IPX7', '12시간 재생', '스트랩 포함'],
    tradeoff: { pro: '어디서든 음악', con: '저음이 약함' }, rating: 4.3,
    reviews: ['캠핑 갈 때 필수', '색이 예뻐요', '볼륨 키우면 소리가 깨져요'], returnPolicy: '무료 반품 14일',
    stock: 2, shipDays: 1, giftWrap: true, options: [{ name: '색', values: ['민트', '그레이'] }],
    tags: ['생일', '커플'], similar: ['p53'],
  },
  {
    id: 'p53', name: '무드등 블루투스 스피커', price: 79_000, category: '테크 소품', emoji: '🎶', tint: ['#F6F0E8', '#E8DACA'],
    features: ['캔들 같은 불빛', '360도 사운드', '해외 배송'],
    tradeoff: { pro: '조명과 음악을 한 번에', con: '배송이 오래 걸리고 예산을 거의 다 씀' }, rating: 4.5,
    reviews: ['밤에 켜 두면 분위기 최고', '소리가 꽉 차요', '배송에 나흘 걸렸어요'], returnPolicy: '무료 반품 14일',
    stock: 7, shipDays: 4, giftWrap: true, tags: ['집들이', '커플'], similar: ['p52'],
  },
  {
    id: 'p62', name: '3in1 멀티 충전 케이블', price: 9_900, category: '테크 소품', emoji: '🧵', tint: ['#F0F0F2', '#DADAE0'],
    features: ['C타입 · 라이트닝 · 마이크로 5핀', '1.2m 패브릭 피복', '고속 충전'],
    tradeoff: { pro: '누구나 쓸모 있음', con: '선물 느낌은 없음' }, rating: 4.0,
    reviews: ['사무실에서 다들 빌려 가요', '튼튼해요', '데이터 전송은 느려요'], returnPolicy: '무료 반품 7일',
    stock: 100, shipDays: 1, tags: ['회사 동료'],
  },
  {
    id: 'p63', name: '전자 메모패드', price: 32_000, category: '테크 소품', emoji: '📝', tint: ['#EEF3EE', '#D6E2D6'],
    features: ['10인치 LCD 필기', '버튼 한 번에 지우기', '배터리 1년'],
    tradeoff: { pro: '종이 없이 무한 메모', con: '저장이 안 됨' }, rating: 4.2,
    reviews: ['아이 낙서판으로 최고', '회의 메모에 좋아요', '저장이 안 돼서 아쉬워요'], returnPolicy: '무료 반품 7일',
    stock: 11, shipDays: 2, tags: ['아이', '회사 동료'],
  },
  {
    id: 'p64', name: '노이즈캔슬링 이어폰', price: 159_000, listPrice: 199_000, category: '테크 소품', emoji: '🎧', tint: ['#EEEEF2', '#D7D7DF'],
    features: ['액티브 노이즈캔슬링', '케이스 포함 30시간', '무선 충전 케이스'],
    tradeoff: { pro: '출퇴근길이 조용해짐', con: '예산 두 배' }, rating: 4.6,
    reviews: ['지하철에서 신세계', '착용감 좋아요', '통화 품질은 보통'], returnPolicy: '개봉 시 반품 불가',
    stock: 4, shipDays: 1, giftWrap: true, options: [{ name: '색', values: ['블랙', '화이트'] }],
    tags: ['생일', '나를 위한'],
  },

  // ── 반려동물 ──
  {
    id: 'p56', name: '노즈워크 매트', price: 23_000, category: '반려동물', emoji: '🐶', tint: ['#F5F1E8', '#E5DCC8'],
    features: ['간식 숨기는 펠트 매트', '50 × 50cm', '세탁기 사용 가능'],
    tradeoff: { pro: '혼자 있는 시간에 좋음', con: '물어뜯는 아이는 금방 망가뜨림' }, rating: 4.4,
    reviews: ['30분은 혼자 놀아요', '세탁이 쉬워요', '우리 애는 사흘 만에 찢었어요'], returnPolicy: '무료 반품 7일 (미사용)',
    stock: 16, shipDays: 2, tags: ['반려동물'], similar: ['p57'],
  },
  {
    id: 'p57', name: '고양이 숨숨집 방석', price: 38_000, category: '반려동물', emoji: '🐱', tint: ['#F4F0F5', '#E2DAE6'],
    features: ['동굴형 니트', '분리 쿠션', '세탁 가능'],
    tradeoff: { pro: '고양이가 좋아함', con: '털이 잘 붙음' }, rating: 4.6,
    reviews: ['들어가서 안 나와요', '니트가 도톰해요', '털 떼기가 일이에요'], returnPolicy: '무료 반품 7일 (미사용)',
    stock: 0, shipDays: 2, options: [{ name: '색', values: ['크림', '그레이'] }], tags: ['반려동물'], similar: ['p56'],
  },
  {
    id: 'p65', name: '수제 펫 간식 3종', price: 8_500, category: '반려동물', emoji: '🦴', tint: ['#F7F0E6', '#E9DAC3'],
    features: ['닭가슴살 · 연어 · 고구마', '무첨가 건조', '소포장 3봉'],
    tradeoff: { pro: '부담 없이 기분 좋은 선물', con: '알레르기 확인 필요' }, rating: 4.5,
    reviews: ['기호성 좋아요', '성분이 단순해요', '양이 적어요'], returnPolicy: '식품이라 개봉 시 반품 불가',
    stock: 12, shipDays: 1, giftWrap: true, tags: ['반려동물', '감사'],
  },
  {
    id: 'p66', name: '이름 각인 펫 목걸이', price: 29_000, category: '반려동물', emoji: '🏷️', tint: ['#F3F1EC', '#E0DBCF'],
    features: ['스텐 이름표 각인', '가죽 목줄', '각인 제작'],
    tradeoff: { pro: '세상에 하나뿐', con: '각인 제작이라 오래 걸림' }, rating: 4.4,
    reviews: ['각인이 선명해요', '가죽이 부드러워요', '엿새 만에 받았어요'], returnPolicy: '각인 제작이라 반품 불가',
    stock: 20, shipDays: 6, giftWrap: true, options: [{ name: '크기', values: ['S', 'M', 'L'] }],
    tags: ['반려동물', '생일'],
  },
  {
    id: 'p67', name: '스마트 자동 급식기', price: 119_000, category: '반려동물', emoji: '🍚', tint: ['#EEF2F4', '#D6DEE3'],
    features: ['앱으로 급식 예약', '4L 사료통', '정전 대비 건전지'],
    tradeoff: { pro: '출장 가도 안심', con: '예산 초과, 앱 설정 필요' }, rating: 4.3,
    reviews: ['여행 갈 때 든든해요', '양 조절이 정확해요', '와이파이 연결이 자주 끊겨요'], returnPolicy: '무료 반품 14일',
    stock: 5, shipDays: 2, tags: ['반려동물'],
  },

  // ── 식품·간식 ──
  {
    id: 'p68', name: '수제 쿠키 박스 24구', price: 52_000, category: '식품·간식', emoji: '🍪', tint: ['#FAF1E6', '#EEDBC1'],
    features: ['쿠키 8종 × 3개', '당일 구워 발송', '유통기한 10일'],
    tradeoff: { pro: '받자마자 같이 먹기 좋음', con: '금방 사라짐' }, rating: 4.6,
    reviews: ['사무실에서 순삭', '포장이 예뻐요', '조금 달아요'], returnPolicy: '식품이라 단순 변심 반품 불가',
    stock: 8, shipDays: 2, giftWrap: true, tags: ['감사', '회사 동료', '생일'],
  },
  {
    id: 'p69', name: '제철 과일 선물 세트', price: 65_000, category: '식품·간식', emoji: '🍑', tint: ['#FCEFEA', '#F2D7CC'],
    features: ['제철 과일 3종 2kg', '산지 직송', '보자기 포장'],
    tradeoff: { pro: '어른께 드리기 좋음', con: '보관 기간이 짧음' }, rating: 4.5,
    reviews: ['과일이 크고 달아요', '부모님이 좋아하셨어요', '하나가 살짝 무른 채 왔어요'], returnPolicy: '신선식품이라 상품 하자 시에만 교환',
    stock: 4, shipDays: 3, giftWrap: true, tags: ['부모님', '감사'],
  },
  {
    id: 'p70', name: '수제 그래놀라 3종', price: 18_000, listPrice: 22_000, category: '식품·간식', emoji: '🥣', tint: ['#F7F1E4', '#E9DDC0'],
    features: ['오리지널 · 초코 · 메이플', '각 200g', '설탕 30% 줄임'],
    tradeoff: { pro: '건강한 아침', con: '취향이 갈림' }, rating: 4.3,
    reviews: ['요거트랑 먹어요', '바삭해요', '초코맛은 좀 달아요'], returnPolicy: '식품이라 개봉 시 반품 불가',
    stock: 25, shipDays: 1, tags: ['나를 위한', '회사 동료'],
  },
  {
    id: 'p71', name: '미니 꿀 스틱 30개', price: 9_800, category: '식품·간식', emoji: '🍯', tint: ['#FBF4E2', '#F0E2B6'],
    features: ['아카시아 꿀 12g × 30', '스틱형', '선물 상자'],
    tradeoff: { pro: '가볍고 실용적', con: '단 걸 안 먹으면 쓸모없음' }, rating: 4.4,
    reviews: ['차에 넣어 먹기 좋아요', '들고 다니기 편해요', '상자가 좀 찌그러져 왔어요'], returnPolicy: '식품이라 개봉 시 반품 불가',
    stock: 60, shipDays: 1, giftWrap: true, tags: ['감사', '부모님'],
  },
  {
    id: 'p72', name: '와인 & 치즈 페어링 박스', price: 98_000, category: '식품·간식', emoji: '🍷', tint: ['#F6ECEE', '#E6D0D5'],
    features: ['레드 와인 1병', '치즈 3종 + 크래커', '성인 인증 필요'],
    tradeoff: { pro: '집들이 파티에 딱', con: '예산 초과, 성인 인증 필요' }, rating: 4.7,
    reviews: ['파티 분위기 최고', '치즈 조합이 좋아요', '받을 때 신분증 확인이 번거로웠어요'], returnPolicy: '주류라 반품 불가',
    stock: 1, shipDays: 1, giftWrap: true, tags: ['집들이', '커플'],
  },
];

const byId = new Map(products.map((p) => [p.id, p]));

export const findProduct = (id: string): Product | undefined => byId.get(id);

export const categories = Array.from(new Set(products.map((p) => p.category)));

export const tags = Array.from(new Set(products.flatMap((p) => p.tags)));

/** 재고 상태: 품절 / 얼마 안 남음(1~3) / 여유 */
export type StockState = 'out' | 'low' | 'ok';
export const stockState = (p: Product): StockState => (p.stock <= 0 ? 'out' : p.stock <= 3 ? 'low' : 'ok');

/** 할인율(%). listPrice가 없거나 price보다 작으면 0 */
export const discountPct = (p: Product) =>
  p.listPrice && p.listPrice > p.price ? Math.round((1 - p.price / p.listPrice) * 100) : 0;
