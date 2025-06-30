'use client';

import { Helmet } from "react-helmet-async";
import { CONSTANTS } from '../constants';
import { usePathname } from "next/navigation";

type Proposal = {
    id: string;
    title: string;
    details?: string;
    daoName: string;
    daoId: string;
    currentState: number;
    createdAt: string;
    outcomeMessages: string[];
    winningOutcome?: string;
}

type Dao = {
    id: string;
    name: string;
    description?: string;
    iconUrl?: string;
    verified?: boolean;
    assetSymbol: string;
    stableSymbol: string;
    proposalCount: number;
    timestamp: string;
}

type Route = "/" | "/create" | "/learn" | "/dao/:id" | "/trade/:id";

type PathRouteConfig = {
    title: string;
    description: string;
    keywords: string;
    structuredDataType?: "WebApplication" | "EducationalOrganization" | "WebPage" | "Organization";
    ogImage?: string;
}

type RouteConfig = PathRouteConfig & {
    canonicalUrl: string;
};

const defaultConfig: PathRouteConfig = {
    title: "Govex - Futarchy on Sui",
    description: "Discover and trade on futarchy proposals. Explore DAOs, prediction markets, and governance on Govex, the leading futarchy platform on Sui.",
    keywords:   "futarchy, prediction markets, trade, DAOs, governance, Sui, Govex",
    structuredDataType: "WebApplication",
    ogImage: typeof window !== 'undefined' ? `${window.location.origin}/images/og.png` : '/images/og.png'
};


function getConfig(l: Route, dao?: Dao, proposal?: Proposal): RouteConfig {
    let config: PathRouteConfig = defaultConfig;

    let location: Route = l;
    if (/^\/dao\/[^/]+$/.test(l))
        location = "/dao/:id";
    else if (/^\/trade\/[^/]+$/.test(l))
        location = "/trade/:id";

    switch (location) {
        case "/create":
            config = {
                title: "Create - Govex",
                description: "Create new proposals or DAOs on Govex. Launch your own futarchy markets and participate in decentralized governance on Sui.",
                keywords: "create DAO, create proposal, futarchy, governance, Sui, Govex",
                structuredDataType: "WebPage",
                ogImage: defaultConfig.ogImage,
            };
            break;
        case "/learn":
            config = {
                title: "Learn - Govex",
                description: "Learn about futarchy, prediction markets, and how Govex empowers decentralized governance on Sui. Educational resources and guides.",
                keywords: "futarchy education, prediction markets guide, DAO governance, blockchain education, Sui tutorial",
                structuredDataType: "EducationalOrganization",
                ogImage: defaultConfig.ogImage,
            };
            break;
        case "/dao/:id":
            config = {
                title: dao ? `${dao.name}${dao.name !== "Govex" ? " - Powered by Govex" : ""}` : "DAO View - Govex",
                description: dao
                    ? (dao.name === "Govex"
                        ? `Explore ${dao.name}, the original DAO from this futarchy platform on Sui. See active proposals and trade outcomes.`
                        : `Explore ${dao.name}, a futarchy-governed DAO on Sui where prediction markets govern. See active proposals and trade outcomes.`)
                    : "View DAO details on Govex, the futarchy platform on Sui.",
                keywords:  `${dao ? `${dao.name}, ${dao.assetSymbol}, ${dao.stableSymbol},` : ''} futarchy, DAO, Sui, governance, decentralized organization`,
                structuredDataType: "Organization",
                ogImage: dao ? `${CONSTANTS.apiEndpoint}og/dao/${dao?.id}` : defaultConfig.ogImage,
            };
            break;
        case "/trade/:id":
            config = {
                title: proposal ? `${proposal.title} - ${proposal.daoName}` : "Proposal View - Govex",
                description: proposal
                    ? (proposal.details || `Proposal by ${proposal.daoName}`)
                    : "View proposal details on Govex, the futarchy platform on Sui.",
                keywords:  `${proposal ? `${proposal.daoName}, ${proposal.outcomeMessages?.slice(0, 2).join(', ')}, ${proposal.title}, ` : ''} futarchy, prediction market, trade, vote, AMM`,
                structuredDataType: "WebPage",
                ogImage: proposal ? `${CONSTANTS.apiEndpoint}og/proposal/${proposal?.id}` : defaultConfig.ogImage,
            };
            break;
        default:
            config = defaultConfig;
            break;
    }

    return {
        ...config,
        canonicalUrl: typeof window !== 'undefined' ? window.location.href : '',
    }
}

interface SEOProps {
    proposal?: Proposal;
    dao?: Dao;
}

export function SEOMetadata(props: SEOProps) {
    const pathname = usePathname();
    const {
        title,
        description,
        keywords,
        ogImage,
        canonicalUrl,
    } = getConfig(pathname as Route, props.dao, props.proposal);

    return (
        <Helmet>
            {/* Basic SEO */}
            <title>{title}</title>
            <meta name="description" content={description} />
            <meta name="keywords" content={keywords} />
            <meta name="author" content={!!props.proposal ? props.proposal.daoName : "Govex"} />
            <meta name="robots" content={"index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1"} />
            <meta name="googlebot" content={"index, follow"} />
            <link rel="canonical" href={canonicalUrl} />

            {/* Geo tags */}
            <meta name="geo.region" content="Global" />
            <meta name="geo.placename" content="Global" />

            {/* Open Graph */}
            <meta property="og:title" content={title} />
            <meta property="og:description" content={description} />
            <meta property="og:image" content={ogImage} />
            <meta property="og:image:width" content="1200" />
            <meta property="og:image:height" content="630" />
            <meta property="og:image:alt" content={title} />
            <meta property="og:url" content={canonicalUrl} />
            <meta property="og:type" content={!!props.proposal ? "article" : "website"} />
            <meta property="og:site_name" content="Govex" />
            <meta property="og:locale" content="en_US" />

            {/* Twitter Card */}
            <meta name="twitter:card" content="summary_large_image" />
            <meta name="twitter:title" content={title} />
            <meta name="twitter:description" content={description} />
            <meta name="twitter:image" content={ogImage} />
            <meta name="twitter:image:alt" content={title} />
            <meta name="twitter:site" content="@govexdotai" />
            <meta name="twitter:creator" content="@govexdotai" />
            <meta name="twitter:domain" content="govex.ai" />

            {/* Mobile and viewport */}
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=5.0" />
            <meta name="mobile-web-app-capable" content="yes" />
            <meta name="apple-mobile-web-app-capable" content="yes" />
            <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
            <meta name="apple-mobile-web-app-title" content="Govex" />

            {/* Favicon and theme color */}
            <link rel="icon" href="/favicon.ico" />
            <link rel="apple-touch-icon" href="/images/govex-icon.png" />
            <meta name="theme-color" content="#1f2937" />
            <meta name="msapplication-TileColor" content="#1f2937" />

            {/* Preconnect to external domains for performance */}
            <link rel="preconnect" href="https://fonts.googleapis.com" />
            <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />

            {/* Structured Data */}
            {/* TODO: Add structured data */}

            {/* Breadcrumb structured data */}
            {/* TODO: Add breadcrumb structured data */}

        </Helmet>
    );
} 