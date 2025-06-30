import type { Metadata, Viewport } from "next";
import { Providers } from "./providers";
import { Header } from "./components/navigation/Header";
import { MinimalFooter } from "./components/navigation/Footer";
import "./styles/base.css";

export const metadata: Metadata = {
  title: {
    default: "Govex - Futarchy on Sui",
    template: "%s | Govex"
  },
  description: "Discover and trade on futarchy proposals. Explore DAOs, prediction markets, and governance on Govex, the leading futarchy platform on Sui.",
  keywords: ["futarchy", "prediction markets", "trade", "DAOs", "governance", "Sui", "Govex"],
  authors: [{ name: "Govex" }],
  creator: "Govex",
  publisher: "Govex",
  metadataBase: new URL(process.env.NEXT_PUBLIC_APP_URL || 'https://govex.ai'),
  openGraph: {
    type: "website",
    locale: "en_US",
    url: "/",
    siteName: "Govex",
    title: "Govex - Futarchy on Sui",
    description: "Discover and trade on futarchy proposals. Explore DAOs, prediction markets, and governance on Govex, the leading futarchy platform on Sui.",
    images: [
      {
        url: "/images/og.png",
        width: 1200,
        height: 630,
        alt: "Govex - Futarchy on Sui",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "Govex - Futarchy on Sui",
    description: "Discover and trade on futarchy proposals. Explore DAOs, prediction markets, and governance on Govex, the leading futarchy platform on Sui.",
    creator: "@govexdotai",
    site: "@govexdotai",
    images: ["/images/og.png"],
  },
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      'max-video-preview': -1,
      'max-image-preview': 'large',
      'max-snippet': -1,
    },
  },
  icons: {
    icon: "/favicon.ico",
    apple: "/images/govex-icon.png",
  },
  category: "finance",
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 5,
  themeColor: "#1f2937",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'WebApplication',
    name: 'Govex',
    description: 'Discover and trade on futarchy proposals. Explore DAOs, prediction markets, and governance on Govex, the leading futarchy platform on Sui.',
    url: process.env.NEXT_PUBLIC_APP_URL || 'https://govex.ai',
    applicationCategory: 'FinanceApplication',
    operatingSystem: 'Web',
    offers: {
      '@type': 'Offer',
      price: '0',
      priceCurrency: 'USD',
    },
    publisher: {
      '@type': 'Organization',
      name: 'Govex',
      url: process.env.NEXT_PUBLIC_APP_URL || 'https://govex.ai',
    },
  };

  return (
    <html lang="en" className="dark-theme" style={{ colorScheme: "dark" }}>
      <body className="bg-gray-900 text-white min-h-screen">
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
        />
        <Providers>
          <div className="min-h-screen flex flex-col">
            <Header />
            <main className="flex-1 flex flex-col">
              {children}
            </main>
            <MinimalFooter />
          </div>
        </Providers>
      </body>
    </html>
  );
}
