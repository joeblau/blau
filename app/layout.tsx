import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import './globals.css';
import { Geist, Geist_Mono } from "next/font/google";

const geist = Geist({ subsets: ['latin'], variable: '--font-geist-sans' });
const geistMono = Geist_Mono({ subsets: ['latin'], variable: '--font-geist-mono' });

export const metadata: Metadata = {
  title: 'blau.app',
  description: 'Developer tools, marketing tools, and entertainment. Explore MADE, Previral, ShortReel, Stint, and Doodle.',
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className={`${geist.variable} ${geistMono.variable}`}>
      <body className="min-h-svh antialiased">{children}</body>
    </html>
  );
}
