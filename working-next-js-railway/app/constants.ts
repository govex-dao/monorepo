export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

const network = (process.env.NEXT_PUBLIC_NETWORK ?? "mainnet") as Network;

export enum QueryKey {
  Locked = "locked",
  Escrow = "escrow",
  GetOwnedObjects = "getOwnedObjects",
  Dao = "dao",
  Proposals = "proposals",
  ProposalDetail = "",
  VerificationHistory = "verification-history",
}

export const CONSTANTS = {
  apiEndpoint: process.env.NEXT_PUBLIC_API_URL ? `https://${process.env.NEXT_PUBLIC_API_URL}/` : "https://www.govex.ai/api/",
  network: network,
  explorerUrl: "https://testnet.suivision.xyz/",
};