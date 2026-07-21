import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  metadataBase: new URL("https://easyshop-open.maxscogna.chatgpt.site"),
  title: "Easyshop — Create at the speed of seeing",
  description: "A native, open-source photo editor for Mac with layers, colour, honest on-device Vision ML and a movable interface built for fast photographic work.",
  openGraph: {
    title: "Easyshop — Photoshop-style power, finally effortless",
    description: "Layers, colour and on-device Vision ML in a native open-source Mac editor that stays out of your way.",
    images: ["/og.png"],
  },
  twitter: { card: "summary_large_image", images: ["/og.png"] },
  icons: {
    icon: "/assets/easyshop-icon.png",
    shortcut: "/assets/easyshop-icon.png",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased`}
      >
        {children}
      </body>
    </html>
  );
}
