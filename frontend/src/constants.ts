import assetPackage from "../../backend/futarchy-results/futarchy-pub-asset-contract-short.json";
import stablePackage from "../../backend/futarchy-results/futarchy-pub-stable-contract-short.json";
import { readFileSync } from 'fs';

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

/// We assume our config files are in the format: { "packageId": "0x..." }
const parseConfigurationFile = (fileName: string) => {
	try {
		return JSON.parse(readFileSync(`${fileName}.json`, 'utf8'));
	} catch (e) {
		throw new Error(`Missing config file ${fileName}.json`);
	}
};

const FUTARCHY_CONTRACT = parseConfigurationFile(`deployments/${process.env.NETWORK}-futarchy`);
const network = (process.env.NETWORK ?? "mainnet") as Network;

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
  futarchyPackage: FUTARCHY_CONTRACT.packageId,
  futarchyFactoryId: FUTARCHY_CONTRACT.factoryId,
  futarchyPaymentManagerId: FUTARCHY_CONTRACT.feeManagerId,
  assetPackage: assetPackage.packageId,
  assetTreasury: assetPackage.treasuryCapId,
  assetMetaData: assetPackage.metadataId,
  assetType: network === 'mainnet'
    ? "0x0f5a49f57d89b812eface201194381d5c81b462f39b90b220a024750737ea5d4::govex::GOVEX"
    : assetPackage.coinType,
  stablePackage: stablePackage.packageId,
  stableTreasury: stablePackage.treasuryCapId,
  stableMetaData: stablePackage.metadataId,
  stableType: network === 'mainnet'
    ? "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC"
    : stablePackage.coinType,
  network: network,
  explorerUrl: "https://testnet.suivision.xyz/",
};
