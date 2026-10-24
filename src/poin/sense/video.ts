// 감지 모드의 로컬 video 엘리먼트 공유 지점. SenseRunner가 쓰고 SenseThumb가 읽는다.
// 이 엘리먼트의 프레임은 화면 그리기와 로컬 추론에만 쓰고 어디로도 보내지 않는다.
let current: HTMLVideoElement | null = null;

export const getSenseVideo = () => current;
export const setSenseVideo = (v: HTMLVideoElement | null) => {
  current = v;
};
