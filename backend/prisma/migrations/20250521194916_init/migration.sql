-- CreateTable
CREATE TABLE "Cursor" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "eventSeq" TEXT NOT NULL,
    "txDigest" TEXT NOT NULL
);

-- CreateTable
CREATE TABLE "Dao" (
    "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    "dao_id" TEXT NOT NULL,
    "minAssetAmount" BIGINT NOT NULL,
    "minStableAmount" BIGINT NOT NULL,
    "timestamp" BIGINT NOT NULL,
    "assetType" TEXT NOT NULL,
    "stableType" TEXT NOT NULL,
    "icon_url" TEXT NOT NULL,
    "icon_cache_path" TEXT,
    "dao_name" TEXT NOT NULL,
    "asset_decimals" INTEGER NOT NULL,
    "stable_decimals" INTEGER NOT NULL,
    "asset_name" TEXT NOT NULL,
    "stable_name" TEXT NOT NULL,
    "asset_icon_url" TEXT NOT NULL,
    "stable_icon_url" TEXT NOT NULL,
    "asset_symbol" TEXT NOT NULL,
    "stable_symbol" TEXT NOT NULL,
    "review_period_ms" BIGINT NOT NULL,
    "trading_period_ms" BIGINT NOT NULL,
    "amm_twap_start_delay" BIGINT NOT NULL,
    "amm_twap_step_max" BIGINT NOT NULL,
    "amm_twap_initial_observation" BIGINT NOT NULL,
    "twap_threshold" BIGINT NOT NULL
);

-- CreateTable
CREATE TABLE "Proposal" (
    "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    "proposal_id" TEXT NOT NULL,
    "market_state_id" TEXT NOT NULL,
    "dao_id" TEXT NOT NULL,
    "proposer" TEXT NOT NULL,
    "outcome_count" BIGINT NOT NULL,
    "outcome_messages" TEXT NOT NULL,
    "created_at" BIGINT NOT NULL,
    "escrow_id" TEXT NOT NULL,
    "asset_value" BIGINT NOT NULL,
    "stable_value" BIGINT NOT NULL,
    "asset_type" TEXT NOT NULL,
    "stable_type" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "details" TEXT NOT NULL,
    "metadata" TEXT NOT NULL,
    "current_state" INTEGER,
    "review_period_ms" BIGINT NOT NULL,
    "trading_period_ms" BIGINT NOT NULL,
    "initial_outcome_amounts" TEXT,
    "twap_start_delay" BIGINT NOT NULL,
    "twap_step_max" BIGINT NOT NULL,
    "twap_initial_observation" BIGINT NOT NULL,
    "twap_threshold" BIGINT NOT NULL,
    CONSTRAINT "Proposal_dao_id_fkey" FOREIGN KEY ("dao_id") REFERENCES "Dao" ("dao_id") ON DELETE RESTRICT ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "ProposalTWAP" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "proposalId" TEXT NOT NULL,
    "outcome" INTEGER NOT NULL,
    "twap" BIGINT,
    "timestamp" BIGINT NOT NULL,
    "oracle_id" TEXT NOT NULL,
    CONSTRAINT "ProposalTWAP_proposalId_fkey" FOREIGN KEY ("proposalId") REFERENCES "Proposal" ("proposal_id") ON DELETE RESTRICT ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "DaoVerificationRequest" (
    "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    "dao_id" TEXT NOT NULL,
    "requester" TEXT NOT NULL,
    "attestation_url" TEXT NOT NULL,
    "verification_id" TEXT NOT NULL,
    "timestamp" BIGINT NOT NULL,
    "status" TEXT NOT NULL DEFAULT 'pending',
    CONSTRAINT "DaoVerificationRequest_dao_id_fkey" FOREIGN KEY ("dao_id") REFERENCES "Dao" ("dao_id") ON DELETE RESTRICT ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "DaoVerification" (
    "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    "dao_id" TEXT NOT NULL,
    "attestation_url" TEXT NOT NULL,
    "verification_id" TEXT NOT NULL,
    "verified" BOOLEAN NOT NULL,
    "validator" TEXT NOT NULL,
    "timestamp" BIGINT NOT NULL,
    "reject_reason" TEXT,
    CONSTRAINT "DaoVerification_dao_id_fkey" FOREIGN KEY ("dao_id") REFERENCES "Dao" ("dao_id") ON DELETE RESTRICT ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "ProposalStateChange" (
    "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    "proposal_id" TEXT NOT NULL,
    "old_state" INTEGER NOT NULL,
    "new_state" INTEGER NOT NULL,
    "timestamp" BIGINT NOT NULL,
    CONSTRAINT "ProposalStateChange_proposal_id_fkey" FOREIGN KEY ("proposal_id") REFERENCES "Proposal" ("proposal_id") ON DELETE RESTRICT ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "ProposalResult" (
    "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    "proposal_id" TEXT NOT NULL,
    "dao_id" TEXT NOT NULL,
    "outcome" TEXT NOT NULL,
    "winning_outcome" BIGINT NOT NULL,
    "timestamp" BIGINT NOT NULL,
    CONSTRAINT "ProposalResult_proposal_id_fkey" FOREIGN KEY ("proposal_id") REFERENCES "Proposal" ("proposal_id") ON DELETE RESTRICT ON UPDATE CASCADE
);

-- CreateTable
CREATE TABLE "SwapEvent" (
    "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    "market_id" TEXT NOT NULL,
    "outcome" INTEGER NOT NULL,
    "is_buy" BOOLEAN NOT NULL,
    "amount_in" BIGINT NOT NULL,
    "amount_out" BIGINT NOT NULL,
    "price_impact" BIGINT NOT NULL,
    "price" BIGINT NOT NULL,
    "sender" TEXT NOT NULL,
    "timestamp" BIGINT NOT NULL,
    "asset_reserve" BIGINT NOT NULL,
    "stable_reserve" BIGINT NOT NULL
);

-- CreateTable
CREATE TABLE "ResultSigned" (
    "id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    "dao_id" TEXT NOT NULL,
    "proposal_id" TEXT NOT NULL,
    "result" TEXT NOT NULL,
    "winning_outcome" BIGINT NOT NULL,
    "timestamp" BIGINT NOT NULL
);

-- CreateIndex
CREATE UNIQUE INDEX "Dao_dao_id_key" ON "Dao"("dao_id");

-- CreateIndex
CREATE INDEX "Dao_dao_id_idx" ON "Dao"("dao_id");

-- CreateIndex
CREATE UNIQUE INDEX "Proposal_proposal_id_key" ON "Proposal"("proposal_id");

-- CreateIndex
CREATE UNIQUE INDEX "Proposal_market_state_id_key" ON "Proposal"("market_state_id");

-- CreateIndex
CREATE INDEX "Proposal_dao_id_idx" ON "Proposal"("dao_id");

-- CreateIndex
CREATE UNIQUE INDEX "ProposalTWAP_proposalId_outcome_key" ON "ProposalTWAP"("proposalId", "outcome");

-- CreateIndex
CREATE INDEX "DaoVerificationRequest_verification_id_idx" ON "DaoVerificationRequest"("verification_id");

-- CreateIndex
CREATE INDEX "DaoVerificationRequest_dao_id_status_timestamp_idx" ON "DaoVerificationRequest"("dao_id", "status", "timestamp");

-- CreateIndex
CREATE UNIQUE INDEX "DaoVerification_dao_id_key" ON "DaoVerification"("dao_id");

-- CreateIndex
CREATE INDEX "DaoVerification_verification_id_idx" ON "DaoVerification"("verification_id");

-- CreateIndex
CREATE INDEX "DaoVerification_dao_id_timestamp_verified_idx" ON "DaoVerification"("dao_id", "timestamp", "verified");

-- CreateIndex
CREATE UNIQUE INDEX "DaoVerification_dao_id_verification_id_key" ON "DaoVerification"("dao_id", "verification_id");

-- CreateIndex
CREATE INDEX "ProposalStateChange_proposal_id_idx" ON "ProposalStateChange"("proposal_id");

-- CreateIndex
CREATE UNIQUE INDEX "ProposalResult_proposal_id_key" ON "ProposalResult"("proposal_id");

-- CreateIndex
CREATE INDEX "ProposalResult_proposal_id_idx" ON "ProposalResult"("proposal_id");

-- CreateIndex
CREATE INDEX "ProposalResult_dao_id_idx" ON "ProposalResult"("dao_id");

-- CreateIndex
CREATE INDEX "SwapEvent_market_id_idx" ON "SwapEvent"("market_id");

-- CreateIndex
CREATE INDEX "SwapEvent_outcome_idx" ON "SwapEvent"("outcome");

-- CreateIndex
CREATE INDEX "SwapEvent_sender_idx" ON "SwapEvent"("sender");

-- CreateIndex
CREATE INDEX "SwapEvent_timestamp_idx" ON "SwapEvent"("timestamp");

-- CreateIndex
CREATE UNIQUE INDEX "ResultSigned_proposal_id_key" ON "ResultSigned"("proposal_id");

-- CreateIndex
CREATE INDEX "ResultSigned_proposal_id_idx" ON "ResultSigned"("proposal_id");

-- CreateIndex
CREATE INDEX "ResultSigned_dao_id_idx" ON "ResultSigned"("dao_id");

-- CreateIndex
CREATE INDEX "ResultSigned_timestamp_idx" ON "ResultSigned"("timestamp");
