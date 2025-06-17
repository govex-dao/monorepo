import mainnetfutarchy from "../../backend/deployments/futarchy-mainnet.json";
import testnetfutarchy from "../../backend/deployments/futarchy-testnet.json";
import assetPackage from "../../backend/futarchy-results/futarchy-pub-asset-contract-short.json";
import stablePackage from "../../backend/futarchy-results/futarchy-pub-stable-contract-short.json";

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

const network = (import.meta.env.VITE_NETWORK ?? "mainnet") as Network;

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
  apiEndpoint: import.meta.env.VITE_API_URL ?? "https://www.govex.ai/api/",
  futarchyPackage:
    network === "mainnet"
      ? mainnetfutarchy.packageId
      : testnetfutarchy.packageId,
  futarchyFactoryId:
    network === "mainnet"
      ? mainnetfutarchy.factoryId
      : testnetfutarchy.factoryId,
  futarchyPaymentManagerId:
    network === "mainnet"
      ? mainnetfutarchy.feeManagerId
      : testnetfutarchy.feeManagerId,
  assetPackage: assetPackage.packageId,
  assetTreasury: assetPackage.treasuryCapId,
  assetMetaData: assetPackage.metadataId,
  assetType: assetPackage.coinType,
  stablePackage: stablePackage.packageId,
  stableTreasury: stablePackage.treasuryCapId,
  stableMetaData: stablePackage.metadataId,
  stableType: stablePackage.coinType,
  network: network,
  explorerUrl: "https://testnet.suivision.xyz/",
};
