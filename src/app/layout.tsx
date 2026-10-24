import type { Metadata } from 'next';
import { TooltipProvider } from '@/components/ui/tooltip';
import './globals.css';
import '../styles/poin.css';

export const metadata: Metadata = {
  title: 'poin 데모',
  description: '망설임의 순간을 읽고 더 나은 다음 턴을 함께 만드는 레이어',
};

export default function RootLayout({ children }: LayoutProps<'/'>) {
  return (
    <html lang="ko" className="h-full antialiased">
      <body
        className="min-h-full bg-white text-[var(--c-text)]"
        style={{ fontFamily: '-apple-system, "SF Pro Text", "Apple SD Gothic Neo", system-ui, sans-serif' }}
      >
        <TooltipProvider>{children}</TooltipProvider>
      </body>
    </html>
  );
}
