import { Toaster } from "react-hot-toast";
import { Outlet, useLocation } from "react-router-dom";
import { Helmet } from "react-helmet-async";
import { Header } from "@/components/Header";
import { Container } from "@radix-ui/themes";

type RouteMetadata = {
  title: string;
  description: string;
  ogImage?: string;
};

const logo = "/images/twitter-image-govex.png";
const routeMetadata: Record<string, RouteMetadata> = {
  "/": {
    title: "Trade - Govex",
    description: "View all proposals.",
    ogImage: logo,
  },
  "/create": {
    title: "Create - Govex",
    description: "Create proposals and DAOs.",
    ogImage: logo,
  },
  "/learn": {
    title: "Learn - Govex",
    description: "Learn more about the Govex platform.",
    ogImage: logo,
  },
};

function getRouteMetadata(pathname: string): RouteMetadata {
  // First check for exact matches
  if (routeMetadata[pathname]) {
    return routeMetadata[pathname];
  }

  // Parse the URL to handle query parameters
  const url = new URL(window.location.origin + pathname);
  const searchParams = new URLSearchParams(url.search);

  // Handle /?dao={daoid}
  if (pathname === "/" && searchParams.has("dao")) {
    return {
      title: "Proposal View - Govex",
      description: "View proposals for your DAO.",
      ogImage: logo,
    };
  }

  // Handle /create?dao={daoid}
  if (pathname === "/create" && searchParams.has("dao")) {
    return {
      title: "Create Proposal - Govex",
      description: "Create proposals for your DAO.",
      ogImage: logo,
    };
  }

  // Handle /trade/:proposalId
  if (pathname.startsWith("/trade/")) {
    return {
      title: "Proposal View - Govex",
      description: "Trade the selected proposal",
      ogImage: logo,
    };
  }

  // Default to home route metadata
  return routeMetadata["/"];
}

export function Root() {
  const location = useLocation();
  const { title, description, ogImage } = getRouteMetadata(location.pathname);

  return (
    <div>
      <Helmet>
        <title>{title}</title>
        <meta name="description" content={description} data-rh="true" />
        {/* Open Graph metadata */}
        <meta property="og:title" content={title} />
        <meta property="og:description" content={description} />
        {ogImage && <meta property="og:image" content={ogImage} />}
        <meta property="og:url" content={window.location.href} />
        <meta property="og:type" content="website" />
      </Helmet>
      <Toaster position="bottom-center" />
      <Header />
      <Container py="4" style={{ maxWidth: "100vw", width: "100vw" }}>
        <Outlet />
      </Container>
    </div>
  );
}
