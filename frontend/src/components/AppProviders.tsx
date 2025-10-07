/**
 * Shared providers component used by all entry points
 * This centralizes all the context providers needed by the app
 * to avoid duplication across different entry files.
 */

import React from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Theme } from "@radix-ui/themes";
import { HelmetProvider } from "react-helmet-async";
import { getFullnodeUrl } from "@mysten/sui/client";
import {
  SuiClientProvider,
  WalletProvider,
  createNetworkConfig,
} from "@mysten/dapp-kit";
import { CONSTANTS } from "@/constants";

// Configure Sui network connections for all available networks
const { networkConfig } = createNetworkConfig({
  localnet: { url: getFullnodeUrl("localnet") },
  devnet: { url: getFullnodeUrl("devnet") },
  testnet: { url: getFullnodeUrl("testnet") },
  mainnet: { url: getFullnodeUrl("mainnet") },
});

interface AppProvidersProps {
  children: React.ReactNode;
  queryClient?: QueryClient;      // Optional: for SSR to pass custom QueryClient with specific settings
  helmetContext?: any;            // Optional: for SSR to collect meta tags during rendering
  includeWallet?: boolean;        // Optional: wallet provider is only needed on client side
}

export function AppProviders({ 
  children, 
  queryClient,
  helmetContext,
  includeWallet = true 
}: AppProvidersProps) {
  const client = queryClient || new QueryClient();

  return (
    <React.StrictMode>
      <HelmetProvider context={helmetContext}>
        <Theme appearance="dark">
          <QueryClientProvider client={client}>
            <SuiClientProvider
              networks={networkConfig}
              defaultNetwork={CONSTANTS.network}
            >
              {includeWallet ? (
                <WalletProvider autoConnect>
                  {children}
                </WalletProvider>
              ) : (
                children
              )}
            </SuiClientProvider>
          </QueryClientProvider>
        </Theme>
      </HelmetProvider>
    </React.StrictMode>
  );
}