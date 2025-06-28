import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Image optimization
  images: {
    domains: ["www.govex.ai", "govex.ai"],
    unoptimized: process.env.NODE_ENV === "development",
  },
  
  // Environment variables accessible in the browser
  env: {
    NEXT_PUBLIC_API_URL: process.env.NEXT_PUBLIC_API_URL || "https://www.govex.ai/api",
    NEXT_PUBLIC_NETWORK: process.env.NEXT_PUBLIC_NETWORK || "mainnet",
  },
  
  // Redirects and rewrites for API proxy if needed
  async rewrites() {
    return [
      {
        source: "/api/proxy/:path*",
        destination: `${process.env.NEXT_PUBLIC_API_URL || "https://www.govex.ai/api"}/:path*`,
      },
    ];
  },
  
  // React strict mode for better debugging
  reactStrictMode: true,
  
  // Experimental features for better performance
  experimental: {
    // Optimize CSS
    // optimizeCss: true, // Disabled due to critters dependency issue
  },
  
  // TypeScript and ESLint in production builds
  typescript: {
    ignoreBuildErrors: false,
  },
  eslint: {
    ignoreDuringBuilds: false,
  },
};

export default nextConfig;
