import { Suspense } from "react";
import { DaoView } from "../../routes/DaoView";
import type { Metadata } from "next";
import { CONSTANTS } from "../../constants";

type Props = {
  params: Promise<{ daoId: string }>;
};

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { daoId } = await params;
  
  try {
    const response = await fetch(
      `${CONSTANTS.apiEndpoint}daos?dao_id=${encodeURIComponent(daoId)}`,
      { next: { revalidate: 300 } } // Cache for 5 minutes
    );
    
    if (!response.ok) {
      throw new Error("Failed to fetch DAO data");
    }
    
    const data = await response.json();
    const dao = data.data?.[0];
    
    if (!dao) {
      return {
        title: "DAO Not Found",
        description: "The requested DAO could not be found.",
      };
    }
    
    const title = dao.dao_name !== "Govex" 
      ? `${dao.dao_name} - Powered by Govex`
      : dao.dao_name;
    
    const description = dao.dao_name === "Govex"
      ? `Explore ${dao.dao_name}, the original DAO from this futarchy platform on Sui. See active proposals and trade outcomes.`
      : `Explore ${dao.dao_name}, a futarchy-governed DAO on Sui where prediction markets govern. See active proposals and trade outcomes.`;
    
    const keywords = [
      dao.dao_name,
      dao.asset_symbol,
      dao.stable_symbol,
      "futarchy",
      "DAO",
      "Sui",
      "governance",
      "decentralized organization"
    ].filter(Boolean);
    
    return {
      title,
      description,
      keywords,
      openGraph: {
        title,
        description,
        type: "website",
        images: [`/api/og/dao/${dao.dao_id}`],
      },
      twitter: {
        card: "summary_large_image",
        title,
        description,
        images: [`/api/og/dao/${dao.dao_id}`],
      },
    };
  } catch (error) {
    console.error("Error generating metadata for DAO:", error);
    return {
      title: "DAO View",
      description: "View DAO details on Govex, the futarchy platform on Sui.",
    };
  }
}

export default async function DaoPage({ params }: Props) {
  const { daoId } = await params;
  
  let jsonLd = null;
  
  try {
    const response = await fetch(
      `${CONSTANTS.apiEndpoint}daos?dao_id=${encodeURIComponent(daoId)}`,
      { next: { revalidate: 300 } }
    );
    
    if (response.ok) {
      const data = await response.json();
      const dao = data.data?.[0];
      
      if (dao) {
        jsonLd = {
          '@context': 'https://schema.org',
          '@type': 'Organization',
          name: dao.dao_name,
          description: dao.dao_name === "Govex"
            ? `Explore ${dao.dao_name}, the original DAO from this futarchy platform on Sui.`
            : `Explore ${dao.dao_name}, a futarchy-governed DAO on Sui where prediction markets govern.`,
          url: `${process.env.NEXT_PUBLIC_APP_URL || 'https://govex.ai'}/dao/${dao.dao_id}`,
          foundingDate: dao.timestamp,
          logo: dao.icon_url || dao.icon_cache_path,
          numberOfEmployees: {
            '@type': 'QuantitativeValue',
            value: dao.proposal_count || 0,
          },
        };
      }
    }
  } catch (error) {
    console.error("Error fetching DAO for structured data:", error);
  }
  
  return (
    <>
      {jsonLd && (
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
        />
      )}
      <Suspense fallback={<div>Loading...</div>}>
        <DaoView />
      </Suspense>
    </>
  );
}