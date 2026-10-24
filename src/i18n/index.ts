// 모든 UI 문구의 진입점. 컴포넌트에서 한글을 직접 쓰지 말고 t.<모듈>.<키>로 가져온다.
import { chat } from './chat';
import { poin } from './poin';
import { panel } from './panel';
import { sense } from './sense';
import { consent } from './consent';

export const t = { chat, poin, panel, sense, consent };
