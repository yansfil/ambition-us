'use client';
// 화면 없는 poin 런타임: 신호 수집·순간 감지·추론·반응 처리를 마운트 동안 설치한다.
import { useEffect } from 'react';
import { installEngine } from './engine';

export default function PoinRuntime() {
  useEffect(() => installEngine(), []);
  return null;
}
