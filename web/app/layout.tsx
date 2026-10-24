import type { Metadata } from "next";
import "./globals.css";

const siteUrl = process.env.NEXT_PUBLIC_SITE_URL?.trim().replace(/\/+$/, "");

export const metadata: Metadata = {
  metadataBase: siteUrl ? new URL(siteUrl) : undefined,
  title: {
    default: "EchoPrompter — Native macOS Teleprompter",
    template: "%s | EchoPrompter",
  },
  description:
    "A native macOS teleprompter with smooth scrolling, live voice following, and recorded-audio script synchronization.",
  applicationName: "EchoPrompter",
  keywords: [
    "macOS teleprompter",
    "teleprompter for Mac",
    "voice controlled teleprompter",
    "audio synced teleprompter",
    "video recording teleprompter",
    "presentation prompter",
    "floating teleprompter",
    "script reader for Mac",
  ],
  authors: [{ name: "Arjun Sah" }],
  creator: "Arjun Sah",
  publisher: "EchoPrompter",
  category: "Productivity",
  alternates: siteUrl ? { canonical: "/" } : undefined,
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      "max-image-preview": "large",
      "max-snippet": -1,
      "max-video-preview": -1,
    },
  },
  openGraph: {
    type: "website",
    locale: "en_US",
    title: "EchoPrompter — Native macOS Teleprompter",
    description:
      "Stay on script with smooth scrolling, live voice following, and recorded-audio synchronization on your Mac.",
    siteName: "EchoPrompter",
    url: siteUrl,
  },
  twitter: {
    card: "summary",
    title: "EchoPrompter — Native macOS Teleprompter",
    description:
      "A thoughtful macOS teleprompter for normal scrolling, voice following, and recorded audio.",
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
