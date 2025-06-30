import { LearnDashboard } from "../routes/LearnDashboard";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Learn",
  description: "Learn about futarchy, prediction markets, and how Govex empowers decentralized governance on Sui. Educational resources and guides.",
  keywords: ["futarchy education", "prediction markets guide", "DAO governance", "blockchain education", "Sui tutorial"],
  openGraph: {
    title: "Learn - Govex",
    description: "Learn about futarchy, prediction markets, and how Govex empowers decentralized governance on Sui. Educational resources and guides.",
    type: "website",
  },
  twitter: {
    title: "Learn - Govex",
    description: "Learn about futarchy, prediction markets, and how Govex empowers decentralized governance on Sui. Educational resources and guides.",
  },
};

export default function LearnPage() {
  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'EducationalOrganization',
    name: 'Govex Learn',
    description: 'Learn about futarchy, prediction markets, and how Govex empowers decentralized governance on Sui.',
    url: `${process.env.NEXT_PUBLIC_APP_URL || 'https://govex.ai'}/learn`,
    provider: {
      '@type': 'Organization',
      name: 'Govex',
      url: process.env.NEXT_PUBLIC_APP_URL || 'https://govex.ai',
    },
  };

  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      <LearnDashboard />
    </>
  );
}