// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// You can choose a different env (e.g. using a .env file, or a predefined list)

// http://localhost:3000/
import futarchyPackage from "../../backend/futarchy-results/futarchy-pub-short.json";
import assetPackage from "../../backend/futarchy-results/futarchy-pub-asset-contract-short.json";
import stablePackage from "../../backend/futarchy-results/futarchy-pub-stable-contract-short.json";

export type Network = "mainnet" | "testnet" | "devnet" | "localnet";

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
  futarchyPackage: futarchyPackage.packageId,
  futarchyFactoryId: futarchyPackage.factoryId,
  futarchyPaymentManagerId: futarchyPackage.feeManagerId,
  assetPackage: assetPackage.packageId,
  assetTreasury: assetPackage.treasuryCapId,
  assetMetaData: assetPackage.metadataId,
  assetType: assetPackage.coinType,
  stablePackage: stablePackage.packageId,
  stableTreasury: stablePackage.treasuryCapId,
  stableMetaData: stablePackage.metadataId,
  stableType: stablePackage.coinType,
  network: "mainnet" as Network,
};
