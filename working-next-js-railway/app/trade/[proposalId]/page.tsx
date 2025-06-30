import { Suspense } from "react";
import { ProposalView } from "../../routes/ProposalView";
import type { Metadata } from "next";
import { CONSTANTS } from "../../constants";
import { ProposalSkeleton } from "../../components/LoadingStates";

type Props = {
  params: Promise<{ proposalId: string }>;
};

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { proposalId } = await params;
  
  try {
    const response = await fetch(
      `${CONSTANTS.apiEndpoint}proposals/${proposalId}`,
      { next: { revalidate: 120 } } // Cache for 2 minutes
    );
    
    if (!response.ok) {
      throw new Error("Failed to fetch proposal data");
    }
    
    const proposal = await response.json();
    
    if (!proposal) {
      return {
        title: "Proposal Not Found",
        description: "The requested proposal could not be found.",
      };
    }
    
    const title = `${proposal.title} - ${proposal.dao_name}`;
    const description = proposal.details || `Proposal by ${proposal.dao_name}`;
    const keywords = [
      proposal.dao_name,
      ...proposal.outcome_messages?.slice(0, 2) || [],
      proposal.title,
      "futarchy",
      "prediction market",
      "trade",
      "vote",
      "AMM"
    ].filter(Boolean);
    
    return {
      title,
      description,
      keywords,
      authors: [{ name: proposal.dao_name }],
      openGraph: {
        title,
        description,
        type: "article",
        publishedTime: proposal.created_at,
        authors: [proposal.dao_name],
        images: [`/api/og/proposal/${proposal.proposal_id}`],
      },
      twitter: {
        card: "summary_large_image",
        title,
        description,
        images: [`/api/og/proposal/${proposal.proposal_id}`],
      },
    };
  } catch (error) {
    console.error("Error generating metadata for proposal:", error);
    return {
      title: "Proposal View",
      description: "View proposal details on Govex, the futarchy platform on Sui.",
    };
  }
}

export default async function ProposalPage({ params }: Props) {
  const { proposalId } = await params;
  
  let proposal = null;
  let jsonLd = null;
  
  try {
    const response = await fetch(
      `${CONSTANTS.apiEndpoint}proposals/${proposalId}`,
      { next: { revalidate: 120 } }
    );
    
    if (response.ok) {
      proposal = await response.json();
      
      if (proposal) {
        jsonLd = {
          '@context': 'https://schema.org',
          '@type': 'Article',
          headline: proposal.title,
          description: proposal.details || `Proposal by ${proposal.dao_name}`,
          datePublished: proposal.created_at,
          author: {
            '@type': 'Organization',
            name: proposal.dao_name,
          },
          publisher: {
            '@type': 'Organization',
            name: 'Govex',
            url: process.env.NEXT_PUBLIC_APP_URL || 'https://govex.ai',
          },
          url: `${process.env.NEXT_PUBLIC_APP_URL || 'https://govex.ai'}/trade/${proposal.proposal_id}`,
          keywords: [
            proposal.dao_name,
            ...proposal.outcome_messages?.slice(0, 2) || [],
            'futarchy',
            'prediction market',
          ].join(', '),
        };
      }
    }
  } catch (error) {
    console.error("Error fetching proposal for structured data:", error);
  }
  
  return (
    <>
      {jsonLd && (
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
        />
      )}
      <Suspense fallback={<ProposalSkeleton />}>
        <ProposalView initialData={proposal} />
      </Suspense>
    </>
  );
}