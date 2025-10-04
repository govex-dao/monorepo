use anchor_lang::prelude::{AnchorDeserialize, Pubkey, Space};

use anyhow::{Context, Result, anyhow, bail};
use jupiter_amm_interface::{
    AccountMap, Amm, AmmContext, AmmProgramIdToLabel, KeyedAccount, Quote, Swap,
    SwapAndAccountMetas, SwapMode, SwapParams,
};

pub mod futarchy_amm;

pub use futarchy_amm::{FutarchyAmm, MAX_BPS, TAKER_FEE_BPS};
use rust_decimal::Decimal;

use crate::futarchy_amm::{FutarchyAmmSwap, SwapType};

pub const FUTARCHY_PROGRAM_ID: Pubkey =
    Pubkey::from_str_const("FUTARELBfJfQ8RDGhg1wdhddq1odMAJUePHFuBYfUxKq");
pub const SPL_TOKEN_PROGRAM_ID: Pubkey =
    Pubkey::from_str_const("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
pub const FUTARCHY_EVENT_AUTHORITY_KEY: Pubkey =
    Pubkey::from_str_const("DGEympSS4qLvdr9r3uGHTfACdN8snShk4iGdJtZPxuBC");

impl AmmProgramIdToLabel for FutarchyAmmClient {
    const PROGRAM_ID_TO_LABELS: &[(Pubkey, jupiter_amm_interface::AmmLabel)] =
        &[(FUTARCHY_PROGRAM_ID, "MetaDAO AMM")];
}

#[derive(Debug)]
pub enum FutarchyAmmError {
    MathOverflow,
    InvalidReserves,
    AmmInvariantViolated,
    InvalidQuoteParams,
    ExactOutNotSupported,
    InvalidAmmData,
}

impl std::fmt::Display for FutarchyAmmError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self)
    }
}

#[derive(Debug, Clone)]
pub struct FutarchyAmmClient {
    pub dao_address: Pubkey,
    pub state: FutarchyAmm,
}

impl Amm for FutarchyAmmClient {
    fn label(&self) -> String {
        "MetaDAO AMM".to_string()
    }

    fn program_id(&self) -> Pubkey {
        FUTARCHY_PROGRAM_ID
    }

    fn key(&self) -> Pubkey {
        self.dao_address
    }

    fn get_reserve_mints(&self) -> Vec<Pubkey> {
        vec![self.state.base_mint, self.state.quote_mint]
    }

    fn get_accounts_to_update(&self) -> Vec<Pubkey> {
        vec![self.dao_address]
    }

    fn update(&mut self, account_map: &AccountMap) -> Result<()> {
        let dao_account = account_map.get(&self.dao_address).with_context(|| {
            format!(
                "DAO account not found for dao address: {}",
                self.dao_address
            )
        })?;

        if dao_account.data.len() < 8 + FutarchyAmm::INIT_SPACE {
            bail!(FutarchyAmmError::InvalidAmmData);
        }

        // we don't do Dao deserialization in case it changes, just deserialize the amm
        let amm_data =
            FutarchyAmm::deserialize(&mut &dao_account.data[8..8 + FutarchyAmm::INIT_SPACE])?;

        self.state = amm_data;

        Ok(())
    }

    fn get_accounts_len(&self) -> usize {
        9
    }

    fn from_keyed_account(keyed_account: &KeyedAccount, _amm_context: &AmmContext) -> Result<Self>
    where
        Self: Sized,
    {
        if keyed_account.account.data.len() < 8 + FutarchyAmm::INIT_SPACE {
            bail!(FutarchyAmmError::InvalidAmmData);
        }

        let amm_data = FutarchyAmm::deserialize(
            &mut &keyed_account.account.data[8..8 + FutarchyAmm::INIT_SPACE],
        )?;

        Ok(Self {
            dao_address: keyed_account.key,
            state: amm_data,
        })
    }

    fn get_swap_and_account_metas(&self, swap_params: &SwapParams) -> Result<SwapAndAccountMetas> {
        let SwapParams {
            source_mint,
            destination_token_account,
            source_token_account,
            token_transfer_authority,
            ..
        } = swap_params;

        let (user_base_account, user_quote_account) = if *source_mint == self.state.base_mint {
            (*source_token_account, *destination_token_account)
        } else {
            (*destination_token_account, *source_token_account)
        };

        Ok(SwapAndAccountMetas {
            swap: Swap::TokenSwap,
            account_metas: FutarchyAmmSwap {
                dao: self.dao_address,
                trader: *token_transfer_authority,
                user_base_account,
                user_quote_account,
                amm_base_vault: self.state.amm_base_vault,
                amm_quote_vault: self.state.amm_quote_vault,
                token_program: SPL_TOKEN_PROGRAM_ID,
                futarchy_program: FUTARCHY_PROGRAM_ID,
                futarchy_event_authority: FUTARCHY_EVENT_AUTHORITY_KEY,
            }
            .into(),
        })
    }

    fn clone_amm(&self) -> Box<dyn Amm + Send + Sync> {
        Box::new(self.clone())
    }

    fn quote(
        &self,
        quote_params: &jupiter_amm_interface::QuoteParams,
    ) -> Result<jupiter_amm_interface::Quote> {
        let swap_type = if quote_params.input_mint == self.state.quote_mint
            && quote_params.output_mint == self.state.base_mint
        {
            SwapType::Buy
        } else if quote_params.input_mint == self.state.base_mint
            && quote_params.output_mint == self.state.quote_mint
        {
            SwapType::Sell
        } else {
            bail!(FutarchyAmmError::InvalidQuoteParams);
        };

        if quote_params.swap_mode == SwapMode::ExactOut {
            bail!(FutarchyAmmError::ExactOutNotSupported);
        }

        let out_amount = self
            .state
            .state
            .clone()
            .swap(quote_params.amount, swap_type)?;

        let fee_pct = Decimal::new(TAKER_FEE_BPS as i64, 2);

        // this isn't exact because of compounding, but should be close enough
        let fee_amount = (quote_params.amount as u128)
            .checked_mul(TAKER_FEE_BPS as u128)
            .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?
            .checked_div(MAX_BPS as u128)
            .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?
            as u64;

        Ok(Quote {
            in_amount: quote_params.amount,
            out_amount,
            fee_amount,
            fee_mint: quote_params.input_mint,
            fee_pct,
        })
    }
}

#[cfg(test)]
mod tests {

    use super::*;

    use jupiter_amm_interface::{ClockRef, KeyedAccount, SwapMode};
    use solana_client::rpc_client::RpcClient;
    use solana_commitment_config::CommitmentConfig;
    use solana_sdk::pubkey;

    #[test]
    fn test_futarchy_amm() {
        use solana_sdk::account::Account;
        use std::collections::HashMap;

        let rpc_url = "https://api.devnet.solana.com".to_string();
        let client = RpcClient::new_with_commitment(rpc_url, CommitmentConfig::confirmed());

        let dao_pubkey = pubkey!("9o2vDc7mnqLVu3humkRY1p87q2pFtXhF7QfnTo5qgCXE");

        let dao_account = client.get_account(&dao_pubkey).unwrap();

        let keyed_dao_account = KeyedAccount {
            key: dao_pubkey,
            account: dao_account.clone(),
            params: None,
        };

        let amm_context = AmmContext {
            clock_ref: ClockRef::default(),
        };

        let mut futarchy_amm =
            FutarchyAmmClient::from_keyed_account(&keyed_dao_account, &amm_context).unwrap();

        let accounts_to_update = futarchy_amm.get_accounts_to_update();
        let accounts_map: HashMap<Pubkey, Account, ahash::RandomState> = client
            .get_multiple_accounts(&accounts_to_update)
            .unwrap()
            .into_iter()
            .zip(accounts_to_update)
            .filter_map(|(account, pubkey)| account.map(|a| (pubkey, a)))
            .collect();
        futarchy_amm.update(&accounts_map).unwrap();

        // buy 1 USDC worth
        let res = futarchy_amm
            .quote(&jupiter_amm_interface::QuoteParams {
                amount: 1e6 as u64,
                input_mint: futarchy_amm.state.quote_mint,
                output_mint: futarchy_amm.state.base_mint,
                swap_mode: SwapMode::ExactIn,
            })
            .unwrap();

        println!("res: {:?}", res);

        // sell 10 META worth
        let res = futarchy_amm
            .quote(&jupiter_amm_interface::QuoteParams {
                amount: 1e6 as u64,
                input_mint: futarchy_amm.state.base_mint,
                output_mint: futarchy_amm.state.quote_mint,
                swap_mode: SwapMode::ExactIn,
            })
            .unwrap();

        println!("res: {:?}", res);
    }
}
use anchor_lang::prelude::{
    AccountMeta, AnchorDeserialize, AnchorSerialize, InitSpace, Pubkey, borsh,
};
use anyhow::{Result, anyhow, bail};

use crate::FutarchyAmmError;

// use crate::{FutarchyError, LP_TAKER_FEE_BPS, MAX_BPS, PROTOCOL_TAKER_FEE_BPS};
pub const LP_TAKER_FEE_BPS: u16 = 25;
pub const PROTOCOL_TAKER_FEE_BPS: u16 = 25;
pub const TAKER_FEE_BPS: u16 = LP_TAKER_FEE_BPS + PROTOCOL_TAKER_FEE_BPS;
pub const MAX_BPS: u16 = 10_000;
pub const PRICE_SCALE: u128 = 1_000_000_000_000;

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, InitSpace)]
pub struct Dao {
    /// Embedded FutarchyAmm - 1:1 relationship
    pub amm: FutarchyAmm,
    /// `nonce` + `dao_creator` are PDA seeds
    pub nonce: u64,
    pub dao_creator: Pubkey,
    pub pda_bump: u8,
    pub squads_multisig: Pubkey,
    pub squads_multisig_vault: Pubkey,
    pub base_mint: Pubkey,
    pub quote_mint: Pubkey,
    pub proposal_count: u32,
    // the percentage, in basis points, the pass price needs to be above the
    // fail price in order for the proposal to pass
    pub pass_threshold_bps: u16,
    pub seconds_per_proposal: u32,
    /// For manipulation-resistance the TWAP is a time-weighted average observation,
    /// where observation tries to approximate price but can only move by
    /// `twap_max_observation_change_per_update` per update. Because it can only move
    /// a little bit per update, you need to check that it has a good initial observation.
    /// Otherwise, an attacker could create a very high initial observation in the pass
    /// market and a very low one in the fail market to force the proposal to pass.
    ///
    /// We recommend setting an initial observation around the spot price of the token,
    /// and max observation change per update around 2% the spot price of the token.
    /// For example, if the spot price of META is $400, we'd recommend setting an initial
    /// observation of 400 (converted into the AMM prices) and a max observation change per
    /// update of 8 (also converted into the AMM prices). Observations can be updated once
    /// a minute, so 2% allows the proposal market to reach double the spot price or 0
    /// in 50 minutes.
    pub twap_initial_observation: u128,
    pub twap_max_observation_change_per_update: u128,
    /// Forces TWAP calculation to start after `twap_start_delay_seconds` seconds
    pub twap_start_delay_seconds: u32,
    /// As an anti-spam measure and to help liquidity, you need to lock up some liquidity
    /// in both futarchic markets in order to create a proposal.
    ///
    /// For example, for META, we can use a `min_quote_futarchic_liquidity` of
    /// 5000 * 1_000_000 (5000 USDC) and a `min_base_futarchic_liquidity` of
    /// 10 * 1_000_000_000 (10 META).
    pub min_quote_futarchic_liquidity: u64,
    pub min_base_futarchic_liquidity: u64,
    /// Minimum amount of base tokens that must be staked to launch a proposal
    pub base_to_stake: u64,
    pub seq_num: u64,
    pub initial_spending_limit: Option<InitialSpendingLimit>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, PartialEq, Eq, InitSpace)]
pub struct InitialSpendingLimit {
    pub amount_per_month: u64,
    #[max_len(10)]
    pub members: Vec<Pubkey>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, InitSpace)]
pub struct FutarchyAmm {
    pub state: PoolState,
    pub total_liquidity: u128,
    pub base_mint: Pubkey,
    pub quote_mint: Pubkey,
    pub amm_base_vault: Pubkey,
    pub amm_quote_vault: Pubkey,
}

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, InitSpace)]
pub enum PoolState {
    Spot { spot: Pool },
    Futarchy { spot: Pool, pass: Pool, fail: Pool },
}

#[derive(AnchorSerialize, AnchorDeserialize, PartialEq, Eq, Debug, Clone, Copy)]
pub enum Market {
    Spot,
    Pass,
    Fail,
}

impl PoolState {
    pub fn swap(&mut self, input_amount: u64, swap_type: SwapType) -> Result<u64> {
        match self {
            PoolState::Spot { spot } => spot.swap(input_amount, swap_type),
            PoolState::Futarchy { spot, pass, fail } => {
                let spot_output = spot.swap(input_amount, swap_type)?;

                let arbitrage_result =
                    arbitrage_after_spot_swap(spot, pass, fail, spot_output, swap_type)?;

                Ok(spot_output + arbitrage_result.spot_profit)
            }
        }
    }
}

#[derive(Default, Clone, Copy, Debug, AnchorDeserialize, AnchorSerialize, InitSpace)]
pub struct TwapOracle {
    /// Running sum of slots_per_last_update * last_observation.
    ///
    /// Assuming latest observations are as big as possible (u64::MAX * 1e12),
    /// we can store 18 million slots worth of observations, which turns out to
    /// be ~85 days worth of slots.
    ///
    /// Assuming that latest observations are 100x smaller than they could theoretically
    /// be, we can store 8500 days (23 years) worth of them. Even this is a very
    /// very conservative assumption - META/USDC prices should be between 1e9 and
    /// 1e15, which would overflow after 1e15 years worth of slots.
    ///
    /// So in the case of an overflow, the aggregator rolls back to 0. It's the
    /// client's responsibility to sanity check the assets or to handle an
    /// aggregator at T2 being smaller than an aggregator at T1.
    pub aggregator: u128,
    pub last_updated_timestamp: i64,
    pub created_at_timestamp: i64,
    /// A price is the number of quote units per base unit multiplied by 1e12.
    /// You cannot simply divide by 1e12 to get a price you can display in the UI
    /// because the base and quote decimals may be different. Instead, do:
    /// ui_price = (price * (10**(base_decimals - quote_decimals))) / 1e12
    pub last_price: u128,
    /// If we did a raw TWAP over prices, someone could push the TWAP heavily with
    /// a few extremely large outliers. So we use observations, which can only move
    /// by `max_observation_change_per_update` per update.
    pub last_observation: u128,
    /// The most that an observation can change per update.
    pub max_observation_change_per_update: u128,
    /// What the initial `latest_observation` is set to.
    pub initial_observation: u128,
    /// Number of seconds after amm.created_at_slot to start recording TWAP
    pub start_delay_seconds: u32,
}

impl TwapOracle {
    pub fn new(
        current_timestamp: i64,
        initial_observation: u128,
        max_observation_change_per_update: u128,
        start_delay_seconds: u32,
    ) -> Self {
        Self {
            created_at_timestamp: current_timestamp,
            last_updated_timestamp: current_timestamp,
            last_price: 0,
            last_observation: initial_observation,
            aggregator: 0,
            max_observation_change_per_update,
            initial_observation,
            start_delay_seconds,
        }
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, InitSpace)]
pub struct Pool {
    pub oracle: TwapOracle,
    pub quote_reserves: u64,
    pub base_reserves: u64,
    pub quote_protocol_fee_balance: u64,
    pub base_protocol_fee_balance: u64,
}

#[derive(PartialEq, Eq, Debug, Clone, Copy, AnchorSerialize, AnchorDeserialize)]
pub enum SwapType {
    Buy,
    Sell,
}

impl Pool {
    pub fn k(&self) -> u128 {
        // cannot overflow because u64::MAX * u64::MAX fits in u128
        (self.base_reserves as u128) * (self.quote_reserves as u128)
    }

    pub fn swap(&mut self, input_amount: u64, swap_type: SwapType) -> Result<u64> {
        let input_amount_after_protocol_fee = (input_amount as u128)
            .checked_mul((MAX_BPS - PROTOCOL_TAKER_FEE_BPS) as u128)
            .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?
            .checked_div(MAX_BPS as u128)
            .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?
            as u64;

        let k = self.k();

        let (input_reserve, output_reserve) = match swap_type {
            SwapType::Buy => (self.quote_reserves, self.base_reserves),
            SwapType::Sell => (self.base_reserves, self.quote_reserves),
        };

        // airlifted from uniswap v1:
        // https://github.com/Uniswap/v1-contracts/blob/c10c08d81d6114f694baa8bd32f555a40f6264da/contracts/uniswap_exchange.vy#L106-L111

        if input_reserve == 0 || output_reserve == 0 {
            bail!(FutarchyAmmError::InvalidReserves);
        }

        let input_amount_with_lp_fee = (input_amount_after_protocol_fee as u128)
            .checked_mul((MAX_BPS - LP_TAKER_FEE_BPS) as u128)
            .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;

        let numerator = input_amount_with_lp_fee
            .checked_mul(output_reserve as u128)
            .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;

        let denominator = (input_reserve as u128)
            .checked_mul(MAX_BPS as u128)
            .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?
            .checked_add(input_amount_with_lp_fee as u128)
            .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;

        let output_amount = (numerator
            .checked_div(denominator)
            .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?)
            as u64;

        match swap_type {
            SwapType::Buy => {
                self.quote_reserves = self
                    .quote_reserves
                    .checked_add(input_amount_after_protocol_fee)
                    .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;
                self.base_reserves = self
                    .base_reserves
                    .checked_sub(output_amount)
                    .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;
            }
            SwapType::Sell => {
                self.base_reserves = self
                    .base_reserves
                    .checked_add(input_amount_after_protocol_fee)
                    .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;
                self.quote_reserves = self
                    .quote_reserves
                    .checked_sub(output_amount)
                    .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;
            }
        }

        let new_k = self.k();

        if new_k < k {
            bail!(FutarchyAmmError::AmmInvariantViolated);
        }

        Ok(output_amount)
    }

    pub fn feeless_swap(&mut self, input_amount: u64, swap_type: SwapType) -> Result<u64> {
        let k = self.k();

        let (input_reserve, output_reserve) = match swap_type {
            SwapType::Buy => (self.quote_reserves, self.base_reserves),
            SwapType::Sell => (self.base_reserves, self.quote_reserves),
        };

        // airlifted from uniswap v1:
        // https://github.com/Uniswap/v1-contracts/blob/c10c08d81d6114f694baa8bd32f555a40f6264da/contracts/uniswap_exchange.vy#L106-L111

        if input_reserve == 0 || output_reserve == 0 {
            bail!(FutarchyAmmError::InvalidReserves);
        }

        let numerator = (input_amount as u128)
            .checked_mul(output_reserve as u128)
            .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;

        let denominator = (input_reserve as u128)
            .checked_add(input_amount as u128)
            .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;

        let output_amount = (numerator
            .checked_div(denominator)
            .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?)
            as u64;

        match swap_type {
            SwapType::Buy => {
                self.quote_reserves = self
                    .quote_reserves
                    .checked_add(input_amount)
                    .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;
                self.base_reserves = self
                    .base_reserves
                    .checked_sub(output_amount)
                    .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;
            }
            SwapType::Sell => {
                self.base_reserves = self
                    .base_reserves
                    .checked_add(input_amount)
                    .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;
                self.quote_reserves = self
                    .quote_reserves
                    .checked_sub(output_amount)
                    .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;
            }
        }

        let new_k = self.k();

        if new_k < k {
            bail!(FutarchyAmmError::AmmInvariantViolated);
        }

        Ok(output_amount)
    }

    pub fn simulate_swap(&self, input_amount: u64, swap_type: SwapType) -> Result<u64> {
        let mut pool = self.clone();
        pool.feeless_swap(input_amount, swap_type)
    }
}

#[derive(Debug, Clone)]
pub struct ArbitrageResult {
    pub spot_profit: u64,
    pub pass_profit: u64,
    pub fail_profit: u64,
}

pub fn arbitrage_after_spot_swap(
    spot: &mut Pool,
    pass: &mut Pool,
    fail: &mut Pool,
    max_input: u64,
    swap_type: SwapType,
) -> Result<ArbitrageResult> {
    let mut best_profit = 0;
    let mut best_input_amount = 0;

    let step_size = max_input / 100;

    // If we're buying spot, we want to maximize base profit & spot is possibly above
    // conditional, so we sell spot & buy conditional. If we're selling spot, we want
    // to maximize quote profit & spot is possibly below conditional, so we buy spot &
    // sell conditional.
    let (spot_direction, conditional_direction) = match swap_type {
        SwapType::Buy => (SwapType::Sell, SwapType::Buy),
        SwapType::Sell => (SwapType::Buy, SwapType::Sell),
    };

    for i in 1..=100 {
        let input_amount = i * step_size;

        let spot_output = spot.simulate_swap(input_amount, spot_direction).unwrap();

        let pass_output = pass
            .simulate_swap(spot_output, conditional_direction)
            .unwrap();

        let fail_output = fail
            .simulate_swap(spot_output, conditional_direction)
            .unwrap();

        let conditional_output = std::cmp::min(pass_output, fail_output);

        let profit = (conditional_output as i64)
            .checked_sub(input_amount as i64)
            .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?;

        if profit > best_profit {
            best_profit = profit;
            best_input_amount = input_amount;
        } else {
            break;
        }
    }

    let final_spot_output = spot
        .feeless_swap(best_input_amount, spot_direction)
        .unwrap();

    let final_pass_output = pass
        .feeless_swap(final_spot_output, conditional_direction)
        .unwrap();

    let final_fail_output = fail
        .feeless_swap(final_spot_output, conditional_direction)
        .unwrap();

    let final_conditional_output = std::cmp::min(final_pass_output, final_fail_output);

    let (remaining_pass, remaining_fail) = if final_pass_output > final_fail_output {
        (
            final_pass_output
                .checked_sub(final_conditional_output)
                .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?,
            0,
        )
    } else {
        (
            0,
            final_fail_output
                .checked_sub(final_conditional_output)
                .ok_or_else(|| anyhow!(FutarchyAmmError::MathOverflow))?,
        )
    };

    if final_conditional_output < best_input_amount {
        bail!(FutarchyAmmError::AmmInvariantViolated);
    }

    if final_conditional_output - best_input_amount != best_profit as u64 {
        bail!(FutarchyAmmError::AmmInvariantViolated);
    }

    Ok(ArbitrageResult {
        spot_profit: best_profit as u64,
        pass_profit: remaining_pass,
        fail_profit: remaining_fail,
    })
}

pub struct FutarchyAmmSwap {
    pub dao: Pubkey,
    pub trader: Pubkey,
    pub user_base_account: Pubkey,
    pub user_quote_account: Pubkey,
    pub amm_base_vault: Pubkey,
    pub amm_quote_vault: Pubkey,
    pub token_program: Pubkey,
    pub futarchy_program: Pubkey,
    pub futarchy_event_authority: Pubkey,
}

impl From<FutarchyAmmSwap> for Vec<AccountMeta> {
    fn from(accounts: FutarchyAmmSwap) -> Self {
        vec![
            AccountMeta::new(accounts.dao, false),
            AccountMeta::new(accounts.trader, true),
            AccountMeta::new(accounts.user_base_account, false),
            AccountMeta::new(accounts.user_quote_account, false),
            AccountMeta::new(accounts.amm_base_vault, false),
            AccountMeta::new(accounts.amm_quote_vault, false),
            AccountMeta::new_readonly(accounts.token_program, false),
            AccountMeta::new_readonly(accounts.futarchy_event_authority, false),
            AccountMeta::new_readonly(accounts.futarchy_program, false),
        ]
    }
}
use super::*;

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct InitializeQuestionArgs {
    pub question_id: [u8; 32],
    pub oracle: Pubkey,
    pub num_outcomes: u8,
}

#[event_cpi]
#[derive(Accounts)]
#[instruction(args: InitializeQuestionArgs)]
pub struct InitializeQuestion<'info> {
    #[account(
        init,
        payer = payer,
        space = 8 + Question::INIT_SPACE + (args.num_outcomes as usize * 4),
        seeds = [
            b"question", 
            args.question_id.as_ref(),
            args.oracle.key().as_ref(),
            &[args.num_outcomes],
        ],
        bump
    )]
    pub question: Box<Account<'info, Question>>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}

impl InitializeQuestion<'_> {
    pub fn handle(ctx: Context<Self>, args: InitializeQuestionArgs) -> Result<()> {
        require_gte!(args.num_outcomes, 2, VaultError::InsufficientNumConditions);

        let question = &mut ctx.accounts.question;

        let InitializeQuestionArgs {
            question_id,
            oracle,
            num_outcomes,
        } = args;

        question.set_inner(Question {
            question_id,
            oracle,
            payout_numerators: vec![0; num_outcomes as usize],
            payout_denominator: 0,
        });

        let clock = Clock::get()?;
        emit_cpi!(InitializeQuestionEvent {
            common: CommonFields {
                slot: clock.slot,
                unix_timestamp: clock.unix_timestamp,
            },
            question_id,
            oracle,
            num_outcomes,
            question: question.key(),
        });

        Ok(())
    }
}
use super::*;

use anchor_lang::system_program;
use anchor_spl::token;

#[event_cpi]
#[derive(Accounts)]
pub struct InitializeConditionalVault<'info> {
    #[account(
        init,
        payer = payer,
        space = 8 + ConditionalVault::INIT_SPACE + (32 * question.num_outcomes()),
        seeds = [
            b"conditional_vault", 
            question.key().as_ref(),
            underlying_token_mint.key().as_ref(),
        ],
        bump
    )]
    pub vault: Box<Account<'info, ConditionalVault>>,
    pub question: Account<'info, Question>,
    pub underlying_token_mint: Account<'info, Mint>,
    #[account(
        associated_token::authority = vault,
        associated_token::mint = underlying_token_mint
    )]
    pub vault_underlying_token_account: Box<Account<'info, TokenAccount>>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

impl<'info, 'c: 'info> InitializeConditionalVault<'info> {
    pub fn handle(ctx: Context<'_, '_, 'c, 'info, Self>) -> Result<()> {
        require!(
            !ctx.accounts.question.is_resolved(),
            VaultError::QuestionAlreadyResolved
        );

        let vault = &mut ctx.accounts.vault;

        let decimals = ctx.accounts.underlying_token_mint.decimals;

        let remaining_accs = &mut ctx.remaining_accounts.iter();

        let expected_num_conditional_tokens = ctx.accounts.question.num_outcomes();
        let mut conditional_token_mints = vec![];

        let mint_lamports = Rent::get()?.minimum_balance(Mint::LEN);
        for i in 0..expected_num_conditional_tokens {
            let (conditional_token_mint_address, pda_bump) = Pubkey::find_program_address(
                &[b"conditional_token", vault.key().as_ref(), &[i as u8]],
                ctx.program_id,
            );

            let conditional_token_mint = next_account_info(remaining_accs)?;
            require_eq!(conditional_token_mint.key(), conditional_token_mint_address);

            conditional_token_mints.push(conditional_token_mint_address);

            let cpi_accounts = system_program::Transfer {
                from: ctx.accounts.payer.to_account_info(),
                to: conditional_token_mint.to_account_info(),
            };
            let cpi_ctx =
                CpiContext::new(ctx.accounts.system_program.to_account_info(), cpi_accounts);
            system_program::transfer(cpi_ctx, mint_lamports)?;

            let vault_key = vault.key();
            let seeds = &[
                b"conditional_token",
                vault_key.as_ref(),
                &[i as u8],
                &[pda_bump],
            ];
            let signer = &[&seeds[..]];

            let cpi_accounts = system_program::Allocate {
                account_to_allocate: conditional_token_mint.to_account_info(),
            };
            let cpi_ctx =
                CpiContext::new(ctx.accounts.system_program.to_account_info(), cpi_accounts);
            system_program::allocate(cpi_ctx.with_signer(signer), Mint::LEN as u64)?;

            let cpi_accounts = system_program::Assign {
                account_to_assign: conditional_token_mint.to_account_info(),
            };
            let cpi_ctx =
                CpiContext::new(ctx.accounts.system_program.to_account_info(), cpi_accounts);
            system_program::assign(cpi_ctx.with_signer(signer), ctx.accounts.token_program.key)?;

            let cpi_program = ctx.accounts.token_program.to_account_info();
            let cpi_accounts = token::InitializeMint2 {
                mint: conditional_token_mint.to_account_info(),
            };
            let cpi_ctx = CpiContext::new(cpi_program, cpi_accounts);

            token::initialize_mint2(cpi_ctx, decimals, &vault.key(), None)?;
        }

        vault.set_inner(ConditionalVault {
            question: ctx.accounts.question.key(),
            underlying_token_mint: ctx.accounts.underlying_token_mint.key(),
            underlying_token_account: ctx.accounts.vault_underlying_token_account.key(),
            conditional_token_mints,
            pda_bump: ctx.bumps.vault,
            decimals,
            seq_num: 0,
        });

        let clock = Clock::get()?;
        emit_cpi!(InitializeConditionalVaultEvent {
            common: CommonFields {
                slot: clock.slot,
                unix_timestamp: clock.unix_timestamp,
            },
            vault: vault.key(),
            question: vault.question,
            underlying_token_mint: vault.underlying_token_mint,
            vault_underlying_token_account: vault.underlying_token_account,
            conditional_token_mints: vault.conditional_token_mints.clone(),
            pda_bump: vault.pda_bump,
            seq_num: vault.seq_num,
        });

        Ok(())
    }
}
use super::*;

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct ResolveQuestionArgs {
    pub payout_numerators: Vec<u32>,
}

#[event_cpi]
#[derive(Accounts)]
#[instruction(args: ResolveQuestionArgs)]
pub struct ResolveQuestion<'info> {
    #[account(mut, has_one = oracle)]
    pub question: Account<'info, Question>,
    pub oracle: Signer<'info>,
}

impl ResolveQuestion<'_> {
    pub fn handle(ctx: Context<Self>, args: ResolveQuestionArgs) -> Result<()> {
        let question = &mut ctx.accounts.question;

        require_eq!(
            question.payout_denominator,
            0,
            VaultError::QuestionAlreadyResolved
        );

        require_eq!(
            args.payout_numerators.len(),
            question.num_outcomes(),
            VaultError::InvalidNumPayoutNumerators
        );

        question.payout_denominator = args.payout_numerators.iter().sum();
        question.payout_numerators = args.payout_numerators.clone();

        require_gt!(question.payout_denominator, 0, VaultError::PayoutZero);

        let clock = Clock::get()?;
        emit_cpi!(ResolveQuestionEvent {
            common: CommonFields {
                slot: clock.slot,
                unix_timestamp: clock.unix_timestamp,
            },
            question: question.key(),
            payout_numerators: args.payout_numerators,
        });

        Ok(())
    }
}
use super::*;

impl<'info, 'c: 'info> InteractWithVault<'info> {
    pub fn validate_redeem_tokens(&self) -> Result<()> {
        require!(
            self.question.is_resolved(),
            VaultError::CantRedeemConditionalTokens
        );

        Ok(())
    }

    pub fn handle_redeem_tokens(ctx: Context<'_, '_, 'c, 'info, Self>) -> Result<()> {
        let accs = &ctx.accounts;

        let (mut conditional_token_mints, mut user_conditional_token_accounts) =
            Self::get_mints_and_user_token_accounts(&ctx)?;

        // calculate the expected future supplies of the conditional token mints
        // as current supply - user balance
        let expected_future_supplies: Vec<u64> = conditional_token_mints
            .iter()
            .zip(user_conditional_token_accounts.iter())
            .map(|(mint, account)| mint.supply - account.amount)
            .collect();

        let vault = &accs.vault;
        let question = &accs.question;

        let seeds = generate_vault_seeds!(vault);
        let signer = &[&seeds[..]];

        let user_underlying_balance_before = accs.user_underlying_token_account.amount;
        let vault_underlying_balance_before = accs.vault_underlying_token_account.amount;
        // safe because there is always at least two conditional tokens and thus
        // at least two user conditional token accounts
        let max_redeemable = user_conditional_token_accounts
            .iter()
            .map(|account| account.amount)
            .max()
            .unwrap();

        let mut total_numerator: u128 = 0;

        for (conditional_mint, user_conditional_token_account) in conditional_token_mints
            .iter()
            .zip(user_conditional_token_accounts.iter())
        {
            // this is safe because we check that every conditional mint is a part of the vault
            let payout_index = vault
                .conditional_token_mints
                .iter()
                .position(|mint| mint == &conditional_mint.key())
                .unwrap();

            total_numerator += user_conditional_token_account.amount as u128
                * question.payout_numerators[payout_index] as u128;

            token::burn(
                CpiContext::new(
                    accs.token_program.to_account_info(),
                    Burn {
                        mint: conditional_mint.to_account_info(),
                        from: user_conditional_token_account.to_account_info(),
                        authority: accs.authority.to_account_info(),
                    },
                ),
                user_conditional_token_account.amount,
            )?;
        }

        let total_redeemable = (total_numerator / question.payout_denominator as u128) as u64;

        token::transfer(
            CpiContext::new_with_signer(
                accs.token_program.to_account_info(),
                Transfer {
                    from: accs.vault_underlying_token_account.to_account_info(),
                    to: accs.user_underlying_token_account.to_account_info(),
                    authority: accs.vault.to_account_info(),
                },
                signer,
            ),
            total_redeemable,
        )?;

        require_gte!(max_redeemable, total_redeemable, VaultError::AssertFailed);

        ctx.accounts.user_underlying_token_account.reload()?;
        ctx.accounts.vault_underlying_token_account.reload()?;

        require_eq!(
            ctx.accounts.user_underlying_token_account.amount,
            user_underlying_balance_before + total_redeemable,
            VaultError::AssertFailed
        );

        require_eq!(
            ctx.accounts.vault_underlying_token_account.amount,
            vault_underlying_balance_before - total_redeemable,
            VaultError::AssertFailed
        );

        for acc in user_conditional_token_accounts.iter_mut() {
            acc.reload()?;
            require_eq!(acc.amount, 0, VaultError::AssertFailed);
        }

        for (mint, expected_supply) in conditional_token_mints
            .iter_mut()
            .zip(expected_future_supplies.iter())
        {
            mint.reload()?;
            require_eq!(mint.supply, *expected_supply, VaultError::AssertFailed);
        }

        ctx.accounts.vault.invariant(
            &ctx.accounts.question,
            conditional_token_mints
                .iter()
                .map(|mint| mint.supply)
                .collect::<Vec<u64>>(),
            ctx.accounts.vault_underlying_token_account.amount,
        )?;

        ctx.accounts.vault.seq_num += 1;

        let clock = Clock::get()?;
        emit_cpi!(RedeemTokensEvent {
            common: CommonFields {
                slot: clock.slot,
                unix_timestamp: clock.unix_timestamp,
            },
            user: ctx.accounts.authority.key(),
            vault: ctx.accounts.vault.key(),
            amount: total_redeemable,
            post_user_underlying_balance: ctx.accounts.user_underlying_token_account.amount,
            post_vault_underlying_balance: ctx.accounts.vault_underlying_token_account.amount,
            post_conditional_token_supplies: conditional_token_mints
                .iter()
                .map(|mint| mint.supply)
                .collect(),
            seq_num: ctx.accounts.vault.seq_num,
        });

        Ok(())
    }
}
use super::*;

pub mod add_metadata_to_conditional_tokens;
pub mod common;
pub mod initialize_conditional_vault;
pub mod initialize_question;
pub mod merge_tokens;
pub mod redeem_tokens;
pub mod resolve_question;
pub mod split_tokens;

pub use add_metadata_to_conditional_tokens::*;
pub use common::*;
pub use initialize_conditional_vault::*;
pub use initialize_question::*;
pub use resolve_question::*;
// pub use split_tokens::*;
// pub use merge_tokens::*;
// pub use redeem_tokens::*;
use super::*;

pub mod proph3t_deployer {
    use anchor_lang::declare_id;

    declare_id!("613BRiXuAEn7vibs2oAYzpGW9fXgjzDNuFMM4wPzLdY");
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct AddMetadataToConditionalTokensArgs {
    pub name: String,
    pub symbol: String,
    pub uri: String,
}

#[event_cpi]
#[derive(Accounts)]
pub struct AddMetadataToConditionalTokens<'info> {
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(mut)]
    pub vault: Account<'info, ConditionalVault>,
    #[account(
        mut,
        mint::authority = vault,
    )]
    pub conditional_token_mint: Account<'info, Mint>,
    /// CHECK: verified via cpi into token metadata
    #[account(mut)]
    pub conditional_token_metadata: AccountInfo<'info>,
    pub token_metadata_program: Program<'info, Metadata>,
    pub system_program: Program<'info, System>,
    pub rent: Sysvar<'info, Rent>,
}

impl AddMetadataToConditionalTokens<'_> {
    pub fn validate(&self) -> Result<()> {
        // require!(
        //     self.vault.status == VaultStatus::Active,
        //     VaultError::VaultAlreadySettled
        // );

        require!(
            self.vault
                .conditional_token_mints
                .contains(&self.conditional_token_mint.key()),
            VaultError::InvalidConditionalTokenMint
        );

        require!(
            self.conditional_token_metadata.data_is_empty(),
            VaultError::ConditionalTokenMetadataAlreadySet
        );

        #[cfg(feature = "production")]
        require_eq!(self.payer.key(), proph3t_deployer::ID);

        Ok(())
    }

    pub fn handle(ctx: Context<Self>, args: AddMetadataToConditionalTokensArgs) -> Result<()> {
        let seeds = generate_vault_seeds!(ctx.accounts.vault);
        let signer_seeds = &[&seeds[..]];

        let cpi_program = ctx.accounts.token_metadata_program.to_account_info();

        let cpi_accounts = CreateMetadataAccountsV3 {
            metadata: ctx.accounts.conditional_token_metadata.to_account_info(),
            mint: ctx.accounts.conditional_token_mint.to_account_info(),
            mint_authority: ctx.accounts.vault.to_account_info(),
            payer: ctx.accounts.payer.to_account_info(),
            update_authority: ctx.accounts.vault.to_account_info(),
            system_program: ctx.accounts.system_program.to_account_info(),
            rent: ctx.accounts.rent.to_account_info(),
        };

        create_metadata_accounts_v3(
            CpiContext::new(cpi_program, cpi_accounts).with_signer(signer_seeds),
            DataV2 {
                name: args.name.clone(),
                symbol: args.symbol.clone(),
                uri: args.uri.clone(),
                seller_fee_basis_points: 0,
                creators: None,
                collection: None,
                uses: None,
            },
            false,
            true,
            None,
        )?;

        ctx.accounts.vault.seq_num += 1;

        let clock = Clock::get()?;
        emit_cpi!(AddMetadataToConditionalTokensEvent {
            common: CommonFields {
                slot: clock.slot,
                unix_timestamp: clock.unix_timestamp,
            },
            vault: ctx.accounts.vault.key(),
            conditional_token_mint: ctx.accounts.conditional_token_mint.key(),
            conditional_token_metadata: ctx.accounts.conditional_token_metadata.key(),
            name: args.name,
            symbol: args.symbol,
            uri: args.uri,
            seq_num: ctx.accounts.vault.seq_num,
        });

        Ok(())
    }
}
use super::*;

impl<'info, 'c: 'info> InteractWithVault<'info> {
    pub fn handle_merge_tokens(ctx: Context<'_, '_, 'c, 'info, Self>, amount: u64) -> Result<()> {
        let accs = &ctx.accounts;

        let (mut conditional_token_mints, mut user_conditional_token_accounts) =
            Self::get_mints_and_user_token_accounts(&ctx)?;

        for conditional_token_account in user_conditional_token_accounts.iter() {
            require!(
                conditional_token_account.amount >= amount,
                VaultError::InsufficientConditionalTokens
            );
        }

        let vault = &accs.vault;

        let pre_user_underlying_balance = accs.user_underlying_token_account.amount;
        let pre_vault_underlying_balance = accs.vault_underlying_token_account.amount;

        let expected_future_balances: Vec<u64> = user_conditional_token_accounts
            .iter()
            .map(|account| account.amount - amount)
            .collect();
        let expected_future_supplies: Vec<u64> = conditional_token_mints
            .iter()
            .map(|mint| mint.supply - amount)
            .collect();

        let seeds = generate_vault_seeds!(vault);
        let signer = &[&seeds[..]];

        for (conditional_mint, user_conditional_token_account) in conditional_token_mints
            .iter()
            .zip(user_conditional_token_accounts.iter())
        {
            token::burn(
                CpiContext::new(
                    accs.token_program.to_account_info(),
                    Burn {
                        mint: conditional_mint.to_account_info(),
                        from: user_conditional_token_account.to_account_info(),
                        authority: accs.authority.to_account_info(),
                    },
                ),
                amount,
            )?;
        }

        // Transfer `amount` from vault to user
        token::transfer(
            CpiContext::new_with_signer(
                accs.token_program.to_account_info(),
                Transfer {
                    from: accs.vault_underlying_token_account.to_account_info(),
                    to: accs.user_underlying_token_account.to_account_info(),
                    authority: accs.vault.to_account_info(),
                },
                signer,
            ),
            amount,
        )?;

        ctx.accounts.user_underlying_token_account.reload()?;
        ctx.accounts.vault_underlying_token_account.reload()?;

        require_eq!(
            ctx.accounts.user_underlying_token_account.amount,
            pre_user_underlying_balance + amount,
            VaultError::AssertFailed
        );
        require_eq!(
            ctx.accounts.vault_underlying_token_account.amount,
            pre_vault_underlying_balance - amount,
            VaultError::AssertFailed
        );

        for (mint, expected_supply) in conditional_token_mints
            .iter_mut()
            .zip(expected_future_supplies.iter())
        {
            mint.reload()?;
            require_eq!(mint.supply, *expected_supply, VaultError::AssertFailed);
        }

        for (account, expected_balance) in user_conditional_token_accounts
            .iter_mut()
            .zip(expected_future_balances.iter())
        {
            account.reload()?;
            require_eq!(account.amount, *expected_balance, VaultError::AssertFailed);
        }

        ctx.accounts.vault.invariant(
            &ctx.accounts.question,
            conditional_token_mints
                .iter()
                .map(|mint| mint.supply)
                .collect::<Vec<u64>>(),
            ctx.accounts.vault_underlying_token_account.amount,
        )?;

        ctx.accounts.vault.seq_num += 1;

        emit_cpi!(MergeTokensEvent {
            common: CommonFields {
                slot: Clock::get()?.slot,
                unix_timestamp: Clock::get()?.unix_timestamp,
            },
            user: ctx.accounts.authority.key(),
            vault: ctx.accounts.vault.key(),
            amount,
            post_user_underlying_balance: ctx.accounts.user_underlying_token_account.amount,
            post_vault_underlying_balance: ctx.accounts.vault_underlying_token_account.amount,
            post_user_conditional_token_balances: user_conditional_token_accounts
                .iter()
                .map(|account| account.amount)
                .collect(),
            post_conditional_token_supplies: conditional_token_mints
                .iter()
                .map(|mint| mint.supply)
                .collect(),
            seq_num: ctx.accounts.vault.seq_num,
        });

        Ok(())
    }
}
use super::*;

impl<'info, 'c: 'info> InteractWithVault<'info> {
    pub fn handle_split_tokens(ctx: Context<'_, '_, 'c, 'info, Self>, amount: u64) -> Result<()> {
        let accs = &ctx.accounts;

        let (mut conditional_token_mints, mut user_conditional_token_accounts) =
            Self::get_mints_and_user_token_accounts(&ctx)?;

        let pre_vault_underlying_balance = accs.vault_underlying_token_account.amount;
        let pre_conditional_user_balances = user_conditional_token_accounts
            .iter()
            .map(|acc| acc.amount)
            .collect::<Vec<u64>>();
        let pre_conditional_mint_supplies = conditional_token_mints
            .iter()
            .map(|mint| mint.supply)
            .collect::<Vec<u64>>();

        require_gte!(
            accs.user_underlying_token_account.amount,
            amount,
            VaultError::InsufficientUnderlyingTokens
        );

        let vault = &accs.vault;

        let seeds = generate_vault_seeds!(vault);
        let signer = &[&seeds[..]];

        token::transfer(
            CpiContext::new(
                accs.token_program.to_account_info(),
                Transfer {
                    from: accs.user_underlying_token_account.to_account_info(),
                    to: accs.vault_underlying_token_account.to_account_info(),
                    authority: accs.authority.to_account_info(),
                },
            ),
            amount,
        )?;

        for (conditional_mint, user_conditional_token_account) in conditional_token_mints
            .iter()
            .zip(user_conditional_token_accounts.iter())
        {
            token::mint_to(
                CpiContext::new_with_signer(
                    accs.token_program.to_account_info(),
                    MintTo {
                        mint: conditional_mint.to_account_info(),
                        to: user_conditional_token_account.to_account_info(),
                        authority: accs.vault.to_account_info(),
                    },
                    signer,
                ),
                amount,
            )?;
        }

        ctx.accounts.user_underlying_token_account.reload()?;

        ctx.accounts.vault_underlying_token_account.reload()?;
        require_eq!(
            ctx.accounts.vault_underlying_token_account.amount,
            pre_vault_underlying_balance + amount,
            VaultError::AssertFailed
        );

        for (i, mint) in conditional_token_mints.iter_mut().enumerate() {
            mint.reload()?;
            require_eq!(
                mint.supply,
                pre_conditional_mint_supplies[i] + amount,
                VaultError::AssertFailed
            );
        }

        for (i, acc) in user_conditional_token_accounts.iter_mut().enumerate() {
            acc.reload()?;
            require_eq!(
                acc.amount,
                pre_conditional_user_balances[i] + amount,
                VaultError::AssertFailed
            );
        }

        ctx.accounts.vault.invariant(
            &ctx.accounts.question,
            conditional_token_mints
                .iter()
                .map(|mint| mint.supply)
                .collect::<Vec<u64>>(),
            ctx.accounts.vault_underlying_token_account.amount,
        )?;

        ctx.accounts.vault.seq_num += 1;

        let clock = Clock::get()?;
        emit_cpi!(SplitTokensEvent {
            common: CommonFields {
                slot: clock.slot,
                unix_timestamp: clock.unix_timestamp,
            },
            user: ctx.accounts.authority.key(),
            vault: ctx.accounts.vault.key(),
            amount,
            post_user_underlying_balance: ctx.accounts.user_underlying_token_account.amount,
            post_vault_underlying_balance: ctx.accounts.vault_underlying_token_account.amount,
            post_user_conditional_token_balances: user_conditional_token_accounts
                .iter()
                .map(|account| account.amount)
                .collect(),
            post_conditional_token_supplies: conditional_token_mints
                .iter()
                .map(|mint| mint.supply)
                .collect(),
            seq_num: ctx.accounts.vault.seq_num,
        });
        Ok(())
    }
}
use super::*;

#[event_cpi]
#[derive(Accounts)]
pub struct InteractWithVault<'info> {
    pub question: Account<'info, Question>,
    #[account(mut, has_one = question)]
    pub vault: Account<'info, ConditionalVault>,
    #[account(
        mut,
        constraint = vault_underlying_token_account.key() == vault.underlying_token_account @ VaultError::InvalidVaultUnderlyingTokenAccount
    )]
    pub vault_underlying_token_account: Account<'info, TokenAccount>,
    pub authority: Signer<'info>,
    #[account(
        mut,
        token::authority = authority,
        token::mint = vault.underlying_token_mint
    )]
    pub user_underlying_token_account: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

impl<'info, 'c: 'info> InteractWithVault<'info> {
    pub fn get_mints_and_user_token_accounts(
        ctx: &Context<'_, '_, 'c, 'info, Self>,
    ) -> Result<(Vec<Account<'info, Mint>>, Vec<Account<'info, TokenAccount>>)> {
        let remaining_accs = &mut ctx.remaining_accounts.iter();

        let expected_num_conditional_tokens = ctx.accounts.question.num_outcomes();
        require_eq!(
            remaining_accs.len(),
            expected_num_conditional_tokens * 2,
            VaultError::InvalidConditionals
        );

        let mut conditional_token_mints = vec![];
        let mut user_conditional_token_accounts = vec![];

        for i in 0..expected_num_conditional_tokens {
            let conditional_token_mint = next_account_info(remaining_accs)?;
            require_eq!(
                ctx.accounts.vault.conditional_token_mints[i],
                conditional_token_mint.key(),
                VaultError::ConditionalMintMismatch
            );

            // really, this should never fail because we initialize mints when we initialize the vault
            conditional_token_mints.push(
                Account::<Mint>::try_from(conditional_token_mint)
                    .or(Err(VaultError::BadConditionalMint))?,
            );
        }

        for i in 0..expected_num_conditional_tokens {
            let user_conditional_token_account = next_account_info(remaining_accs)?;

            let user_conditional_token_account =
                Account::<TokenAccount>::try_from(user_conditional_token_account)
                    .or(Err(VaultError::BadConditionalTokenAccount))?;

            require_eq!(
                user_conditional_token_account.mint,
                conditional_token_mints[i].key(),
                VaultError::ConditionalTokenMintMismatch
            );

            require_eq!(
                user_conditional_token_account.owner,
                ctx.accounts.authority.key(),
                VaultError::UnauthorizedConditionalTokenAccount
            );

            user_conditional_token_accounts.push(user_conditional_token_account);
        }

        Ok((conditional_token_mints, user_conditional_token_accounts))
    }
}
use anchor_lang::prelude::*;

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct CommonFields {
    pub slot: u64,
    pub unix_timestamp: i64,
}

impl CommonFields {
    pub fn new(clock: &Clock) -> Self {
        Self {
            slot: clock.slot,
            unix_timestamp: clock.unix_timestamp,
        }
    }
}

#[event]
pub struct AddMetadataToConditionalTokensEvent {
    pub common: CommonFields,
    pub vault: Pubkey,
    pub conditional_token_mint: Pubkey,
    pub conditional_token_metadata: Pubkey,
    pub name: String,
    pub symbol: String,
    pub uri: String,
    pub seq_num: u64,
}

// TODO add `vault` to this event
#[event]
pub struct InitializeConditionalVaultEvent {
    pub common: CommonFields,
    pub vault: Pubkey,
    pub question: Pubkey,
    pub underlying_token_mint: Pubkey,
    pub vault_underlying_token_account: Pubkey,
    pub conditional_token_mints: Vec<Pubkey>,
    pub pda_bump: u8,
    pub seq_num: u64,
}

#[event]
pub struct InitializeQuestionEvent {
    pub common: CommonFields,
    pub question_id: [u8; 32],
    pub oracle: Pubkey,
    pub num_outcomes: u8,
    pub question: Pubkey,
}

#[event]
pub struct MergeTokensEvent {
    pub common: CommonFields,
    pub user: Pubkey,
    pub vault: Pubkey,
    pub amount: u64,
    pub post_user_underlying_balance: u64,
    pub post_vault_underlying_balance: u64,
    pub post_user_conditional_token_balances: Vec<u64>,
    pub post_conditional_token_supplies: Vec<u64>,
    pub seq_num: u64,
}

#[event]
pub struct RedeemTokensEvent {
    pub common: CommonFields,
    pub user: Pubkey,
    pub vault: Pubkey,
    pub amount: u64,
    pub post_user_underlying_balance: u64,
    pub post_vault_underlying_balance: u64,
    pub post_conditional_token_supplies: Vec<u64>,
    pub seq_num: u64,
}

#[event]
pub struct ResolveQuestionEvent {
    pub common: CommonFields,
    pub question: Pubkey,
    pub payout_numerators: Vec<u32>,
}

#[event]
pub struct SplitTokensEvent {
    pub common: CommonFields,
    pub user: Pubkey,
    pub vault: Pubkey,
    pub amount: u64,
    pub post_user_underlying_balance: u64,
    pub post_vault_underlying_balance: u64,
    pub post_user_conditional_token_balances: Vec<u64>,
    pub post_conditional_token_supplies: Vec<u64>,
    pub seq_num: u64,
}
use super::*;

#[error_code]
pub enum VaultError {
    #[msg("An assertion failed")]
    AssertFailed,
    #[msg("Insufficient underlying token balance to mint this amount of conditional tokens")]
    InsufficientUnderlyingTokens,
    #[msg("Insufficient conditional token balance to merge this `amount`")]
    InsufficientConditionalTokens,
    #[msg("This `vault_underlying_token_account` is not this vault's `underlying_token_account`")]
    InvalidVaultUnderlyingTokenAccount,
    #[msg("This conditional token mint is not this vault's conditional token mint")]
    InvalidConditionalTokenMint,
    #[msg("Question needs to be resolved before users can redeem conditional tokens for underlying tokens")]
    CantRedeemConditionalTokens,
    #[msg("Questions need 2 or more conditions")]
    InsufficientNumConditions,
    #[msg("Invalid number of payout numerators")]
    InvalidNumPayoutNumerators,
    #[msg("Client needs to pass in the list of conditional mints for a vault followed by the user's token accounts for those tokens")]
    InvalidConditionals,
    #[msg("Conditional mint not in vault")]
    ConditionalMintMismatch,
    #[msg("Unable to deserialize a conditional token mint")]
    BadConditionalMint,
    #[msg("Unable to deserialize a conditional token account")]
    BadConditionalTokenAccount,
    #[msg("User conditional token account mint does not match conditional mint")]
    ConditionalTokenMintMismatch,
    #[msg("Payouts must sum to 1 or more")]
    PayoutZero,
    #[msg("Question already resolved")]
    QuestionAlreadyResolved,
    #[msg("Conditional token metadata already set")]
    ConditionalTokenMetadataAlreadySet,
    #[msg("Conditional token account is not owned by the authority")]
    UnauthorizedConditionalTokenAccount,
}
use anchor_lang::prelude::*;
use anchor_spl::metadata::{
    create_metadata_accounts_v3, mpl_token_metadata::types::DataV2, CreateMetadataAccountsV3,
    Metadata,
};
use anchor_spl::{
    associated_token::AssociatedToken,
    token::{self, Burn, Mint, MintTo, Token, TokenAccount, Transfer},
};

pub mod error;
pub mod events;
pub mod instructions;
pub mod state;

pub use error::VaultError;
pub use events::*;
pub use instructions::*;
pub use state::*;

#[cfg(not(feature = "no-entrypoint"))]
use solana_security_txt::security_txt;

#[cfg(not(feature = "no-entrypoint"))]
security_txt! {
    name: "conditional_vault",
    project_url: "https://metadao.fi",
    contacts: "email:metaproph3t@protonmail.com",
    policy: "The market will decide whether we pay a bug bounty.",
    source_code: "https://github.com/metaDAOproject/programs",
    source_release: "v0.4",
    auditors: "Neodyme (v0.3)",
    acknowledgements: "DCF = (CF1 / (1 + r)^1) + (CF2 / (1 + r)^2) + ... (CFn / (1 + r)^n)"
}

declare_id!("VLTX1ishMBbcX3rdBWGssxawAo1Q2X2qxYFYqiGodVg");

#[program]
pub mod conditional_vault {
    use super::*;

    pub fn initialize_question(
        ctx: Context<InitializeQuestion>,
        args: InitializeQuestionArgs,
    ) -> Result<()> {
        InitializeQuestion::handle(ctx, args)
    }

    pub fn resolve_question(
        ctx: Context<ResolveQuestion>,
        args: ResolveQuestionArgs,
    ) -> Result<()> {
        ResolveQuestion::handle(ctx, args)
    }

    pub fn initialize_conditional_vault<'c: 'info, 'info>(
        ctx: Context<'_, '_, 'c, 'info, InitializeConditionalVault<'info>>,
    ) -> Result<()> {
        InitializeConditionalVault::handle(ctx)
    }

    pub fn split_tokens<'c: 'info, 'info>(
        ctx: Context<'_, '_, 'c, 'info, InteractWithVault<'info>>,
        amount: u64,
    ) -> Result<()> {
        InteractWithVault::handle_split_tokens(ctx, amount)
    }

    pub fn merge_tokens<'c: 'info, 'info>(
        ctx: Context<'_, '_, 'c, 'info, InteractWithVault<'info>>,
        amount: u64,
    ) -> Result<()> {
        InteractWithVault::handle_merge_tokens(ctx, amount)
    }

    #[access_control(ctx.accounts.validate_redeem_tokens())]
    pub fn redeem_tokens<'c: 'info, 'info>(
        ctx: Context<'_, '_, 'c, 'info, InteractWithVault<'info>>,
    ) -> Result<()> {
        InteractWithVault::handle_redeem_tokens(ctx)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn add_metadata_to_conditional_tokens(
        ctx: Context<AddMetadataToConditionalTokens>,
        args: AddMetadataToConditionalTokensArgs,
    ) -> Result<()> {
        AddMetadataToConditionalTokens::handle(ctx, args)
    }
}
use super::*;

/// Questions represent statements about future events.
///
/// These statements include:
/// - "Will this proposal pass?"
/// - "Who, if anyone, will be hired?"
/// - "How effective will the grant committee deem this grant?"
///
/// Questions have 2 or more possible outcomes. For a question like "will this
/// proposal pass," the outcomes are "yes" and "no." For a question like "who
/// will be hired," the outcomes could be "Alice," "Bob," and "neither."
///
/// Outcomes resolve to a number between 0 and 1. Binary questions like "will
/// this proposal pass" have outcomes that resolve to exactly 0 or 1. You can
/// also have questions with scalar outcomes. For example, the question "how
/// effective will the grant committee deem this grant" could have two outcomes:
/// "ineffective" and "effective." If the grant committee deems the grant 70%
/// effective, the "effective" outcome would resolve to 0.7 and the "ineffective"
/// outcome would resolve to 0.3.
///
/// Once resolved, the sum of all outcome resolutions is exactly 1.
#[account]
#[derive(InitSpace)]
pub struct Question {
    pub question_id: [u8; 32],
    pub oracle: Pubkey,
    #[max_len(0)]
    pub payout_numerators: Vec<u32>,
    pub payout_denominator: u32,
}

impl Question {
    pub fn num_outcomes(&self) -> usize {
        self.payout_numerators.len()
    }

    pub fn is_resolved(&self) -> bool {
        self.payout_denominator != 0
    }
}
use super::*;

pub mod conditional_vault;
pub mod question;

pub use conditional_vault::*;
pub use question::*;
use super::*;

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq)]
pub enum VaultStatus {
    Active,
    Finalized,
    Reverted,
}

#[account]
#[derive(InitSpace)]
pub struct ConditionalVault {
    pub question: Pubkey,
    pub underlying_token_mint: Pubkey,
    pub underlying_token_account: Pubkey,
    #[max_len(0)]
    pub conditional_token_mints: Vec<Pubkey>,
    pub pda_bump: u8,
    pub decimals: u8,
    pub seq_num: u64,
}

impl ConditionalVault {
    /// Checks that the vault's assets are always greater than its potential
    /// liabilities. Should be called anytime you mint or burn conditional
    /// tokens.
    ///
    /// `conditional_token_supplies` should be in the same order as
    /// `vault.conditional_token_mints`.
    pub fn invariant(
        &self,
        question: &Question,
        conditional_token_supplies: Vec<u64>,
        vault_underlying_balance: u64,
    ) -> Result<()> {
        // if the question isn't resolved, the vault should have more underlying
        // tokens than ANY conditional token mint's supply

        // if the question is resolved, the vault should have more underlying
        // tokens than the sum of the conditional token mint's supplies multiplied
        // by their respective payouts

        let max_possible_liability = if !question.is_resolved() {
            // safe because conditional_token_supplies is non-empty
            *conditional_token_supplies.iter().max().unwrap()
        } else {
            // Sum all numerators first, then divide once
            let total_numerator: u128 = conditional_token_supplies
                .iter()
                .enumerate()
                .map(|(i, supply)| *supply as u128 * question.payout_numerators[i] as u128)
                .sum();

            (total_numerator / question.payout_denominator as u128) as u64
        };

        require_gte!(
            vault_underlying_balance,
            max_possible_liability,
            VaultError::AssertFailed
        );

        Ok(())
    }
}

#[macro_export]
macro_rules! generate_vault_seeds {
    ($vault:expr) => {{
        &[
            b"conditional_vault",
            $vault.question.as_ref(),
            $vault.underlying_token_mint.as_ref(),
            &[$vault.pda_bump],
        ]
    }};
}
use crate::{
    ChangeProposed, ChangeRequest, ChangeType, PerformancePackage,
    PriceBasedPerformancePackageError, ProposerType,
};
use anchor_lang::prelude::*;

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct ProposeChangeParams {
    pub change_type: ChangeType,
    pub pda_nonce: u32,
}

#[derive(Accounts)]
#[instruction(params: ProposeChangeParams)]
#[event_cpi]
pub struct ProposeChange<'info> {
    #[account(
        init,
        payer = payer,
        space = 8 + ChangeRequest::INIT_SPACE,
        seeds = [
            b"change_request",
            performance_package.key().as_ref(),
            proposer.key().as_ref(),
            params.pda_nonce.to_le_bytes().as_ref()
        ],
        bump
    )]
    pub change_request: Account<'info, ChangeRequest>,
    #[account(mut)]
    pub performance_package: Account<'info, PerformancePackage>,
    pub proposer: Signer<'info>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}

impl<'info> ProposeChange<'info> {
    pub fn validate(&self) -> Result<()> {
        if self.proposer.key() != self.performance_package.recipient
            && self.proposer.key() != self.performance_package.performance_package_authority
        {
            msg!("proposer ({}) is not the token recipient ({}) or performance package authority ({})", self.proposer.key(), self.performance_package.recipient, self.performance_package.performance_package_authority);
            return Err(PriceBasedPerformancePackageError::UnauthorizedChangeRequest.into());
        }

        Ok(())
    }

    pub fn handle(ctx: Context<Self>, params: ProposeChangeParams) -> Result<()> {
        let Self {
            change_request,
            performance_package,
            proposer,
            payer: _,
            system_program: _,
            event_authority: _,
            program: _,
        } = ctx.accounts;

        let ProposeChangeParams {
            change_type,
            pda_nonce,
        } = params;

        let proposer_type = if proposer.key() == performance_package.recipient {
            ProposerType::Recipient
        } else if proposer.key() == performance_package.performance_package_authority {
            ProposerType::Authority
        } else {
            unreachable!()
        };

        let clock = Clock::get()?;

        change_request.set_inner(ChangeRequest {
            performance_package: performance_package.key(),
            change_type: change_type.clone(),
            proposed_at: clock.unix_timestamp,
            proposer_type,
            pda_nonce: pda_nonce,
            pda_bump: ctx.bumps.change_request,
        });

        // Emit event
        emit!(ChangeProposed {
            locker: performance_package.key(),
            change_request: change_request.key(),
            proposer: proposer.key(),
            change_type,
        });

        Ok(())
    }
}
use crate::{
    ChangeExecuted, ChangeRequest, ChangeType, CommonFields, PerformancePackage,
    PriceBasedPerformancePackageError, ProposerType,
};
use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct ExecuteChange<'info> {
    #[account(
        mut,
        has_one = performance_package @ PriceBasedPerformancePackageError::InvalidChangeRequest,
        close = executor
    )]
    pub change_request: Account<'info, ChangeRequest>,

    #[account(mut)]
    pub performance_package: Account<'info, PerformancePackage>,

    /// The party executing the change (must be opposite of proposer)
    #[account(mut)]
    pub executor: Signer<'info>,
}

impl<'info> ExecuteChange<'info> {
    pub fn validate(&self) -> Result<()> {
        if self.change_request.proposer_type == ProposerType::Recipient {
            // If recipient proposed, locker authority must execute
            require_keys_eq!(
                self.executor.key(),
                self.performance_package.performance_package_authority,
                PriceBasedPerformancePackageError::UnauthorizedLockerAuthority
            );
        } else if self.change_request.proposer_type == ProposerType::Authority {
            // If authority proposed, recipient must execute
            require_keys_eq!(
                self.executor.key(),
                self.performance_package.recipient,
                PriceBasedPerformancePackageError::UnauthorizedChangeRequest
            );
        } else {
            // Proposer was neither valid party - should not happen due to proposal constraints
            return Err(PriceBasedPerformancePackageError::UnauthorizedChangeRequest.into());
        }

        Ok(())
    }

    pub fn handle(ctx: Context<Self>) -> Result<()> {
        let performance_package = &mut ctx.accounts.performance_package;
        let change_request = &ctx.accounts.change_request;

        // Apply the change based on type
        match &change_request.change_type {
            ChangeType::Oracle { new_oracle_config } => {
                performance_package.oracle_config = *new_oracle_config;
            }
            ChangeType::Recipient { new_recipient } => {
                performance_package.recipient = *new_recipient;
            }
        }

        performance_package.seq_num += 1;
        // Emit event
        let clock = Clock::get()?;
        emit!(ChangeExecuted {
            common: CommonFields::new(&clock, performance_package.seq_num),
            performance_package: performance_package.key(),
            change_request: change_request.key(),
            executor: ctx.accounts.executor.key(),
            change_type: change_request.change_type.clone(),
        });

        Ok(())
    }
}
use anchor_lang::prelude::*;
use anchor_spl::{
    associated_token::AssociatedToken,
    token::{self, Mint, Token, TokenAccount},
};

use super::*;

#[derive(Accounts)]
#[event_cpi]
pub struct CompleteUnlock<'info> {
    #[account(mut, has_one = token_mint, has_one = performance_package_token_vault)]
    pub performance_package: Box<Account<'info, PerformancePackage>>,

    /// CHECK: We will read the aggregator value from this account
    #[account(address = performance_package.oracle_config.oracle_account)]
    pub oracle_account: UncheckedAccount<'info>,

    /// The token account where locked tokens are stored
    #[account(mut)]
    pub performance_package_token_vault: Box<Account<'info, TokenAccount>>,

    /// The token mint - validated via has_one constraint on locker
    pub token_mint: Account<'info, Mint>,

    /// The recipient's ATA where tokens will be sent - created if needed
    #[account(
        init_if_needed,
        payer = payer,
        associated_token::mint = token_mint,
        associated_token::authority = token_recipient
    )]
    pub recipient_token_account: Box<Account<'info, TokenAccount>>,

    /// CHECK: validated to match locker.token_recipient  
    #[account(address = performance_package.recipient @ PriceBasedPerformancePackageError::UnauthorizedChangeRequest)]
    pub token_recipient: UncheckedAccount<'info>,

    /// Payer for creating the ATA if needed
    #[account(mut)]
    pub payer: Signer<'info>,

    pub system_program: Program<'info, System>,

    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
}

impl CompleteUnlock<'_> {
    pub fn validate(&self) -> Result<()> {
        if !matches!(
            self.performance_package.state,
            PerformancePackageState::Unlocking { .. }
        ) {
            msg!(
                "package state: {}",
                self.performance_package.state.to_string()
            );
            return Err(PriceBasedPerformancePackageError::InvalidPerformancePackageState.into());
        }

        Ok(())
    }

    pub fn handle(ctx: Context<Self>) -> Result<()> {
        let Self {
            performance_package,
            oracle_account,
            performance_package_token_vault,
            token_mint: _,
            recipient_token_account,
            token_recipient: _,
            payer: _,
            system_program: _,
            token_program,
            associated_token_program: _,
            event_authority: _,
            program: _,
        } = ctx.accounts;

        let clock = Clock::get()?;

        // Get the start values from the Unlocking state
        let (start_aggregator, start_timestamp) = match &performance_package.state {
            PerformancePackageState::Unlocking {
                start_aggregator,
                start_timestamp,
            } => (*start_aggregator, *start_timestamp),
            _ => unreachable!(),
        };

        // Read the current aggregator value from the oracle account
        let oracle_data = oracle_account.try_borrow_data()?;
        let offset = performance_package.oracle_config.byte_offset as usize;

        // Ensure we have enough data to read 16 bytes (u128)
        require_gte!(
            oracle_data.len(),
            offset + 24,
            PriceBasedPerformancePackageError::InvalidOracleData
        );

        // Read the current aggregator value
        let current_aggregator =
            u128::from_le_bytes(oracle_data[offset..offset + 16].try_into().unwrap());

        let last_updated_timestamp = i64::from_le_bytes(
            oracle_data[offset + 16..offset + 16 + 8]
                .try_into()
                .unwrap(),
        );

        require_gte!(
            clock.unix_timestamp,
            last_updated_timestamp,
            PriceBasedPerformancePackageError::InvalidOracleData
        );

        let time_passed = last_updated_timestamp - start_timestamp;

        require_gte!(
            time_passed,
            performance_package.twap_length_seconds as i64,
            PriceBasedPerformancePackageError::TwapPeriodNotElapsed
        );

        // Calculate TWAP: (current_aggregator - start_aggregator) / time_passed
        let aggregator_change = current_aggregator.saturating_sub(start_aggregator);
        let twap_price = aggregator_change / time_passed as u128;

        let mut tokens_to_unlock = 0;

        for tranche in performance_package.tranches.iter_mut() {
            if tranche.is_unlocked {
                continue;
            }

            if twap_price >= tranche.price_threshold {
                tokens_to_unlock += tranche.token_amount;
                tranche.is_unlocked = true;
            } else {
                // tranches are sorted by price threshold, so if the price is less than the threshold, we can break
                break;
            }
        }

        // Only transfer if there are tokens to unlock
        if tokens_to_unlock > 0 {
            // Transfer tokens to recipient using PDA signature
            let seeds = &[
                b"performance_package",
                performance_package.create_key.as_ref(),
                &[performance_package.pda_bump],
            ];
            let signer = &[&seeds[..]];

            let transfer_ctx = CpiContext::new_with_signer(
                token_program.to_account_info(),
                token::Transfer {
                    from: performance_package_token_vault.to_account_info(),
                    to: recipient_token_account.to_account_info(),
                    authority: performance_package.to_account_info(),
                },
                signer,
            );

            token::transfer(transfer_ctx, tokens_to_unlock)?;

            performance_package.already_unlocked_amount += tokens_to_unlock;
        }

        require_gte!(
            performance_package.total_token_amount,
            performance_package.already_unlocked_amount,
            PriceBasedPerformancePackageError::InvariantViolated
        );

        // Reset locker state back to Locked for next unlock cycle
        performance_package.state = PerformancePackageState::Locked;
        performance_package.seq_num += 1;

        emit_cpi!(UnlockCompleted {
            common: CommonFields::new(&clock, performance_package.seq_num),
            performance_package: performance_package.key(),
            token_amount: tokens_to_unlock,
            recipient: performance_package.recipient,
            twap_price,
        });

        Ok(())
    }
}
use crate::{
    CommonFields, PerformancePackage, PerformancePackageAuthorityChanged,
    PriceBasedPerformancePackageError,
};
use anchor_lang::prelude::*;

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct ChangePerformancePackageAuthorityParams {
    pub new_performance_package_authority: Pubkey,
}

#[derive(Accounts)]
pub struct ChangePerformancePackageAuthority<'info> {
    #[account(mut)]
    pub performance_package: Account<'info, PerformancePackage>,

    #[account(address = performance_package.performance_package_authority @ PriceBasedPerformancePackageError::UnauthorizedLockerAuthority)]
    pub current_authority: Signer<'info>,
}

impl<'info> ChangePerformancePackageAuthority<'info> {
    pub fn handle(
        ctx: Context<Self>,
        params: ChangePerformancePackageAuthorityParams,
    ) -> Result<()> {
        let Self {
            performance_package,
            current_authority: _,
        } = ctx.accounts;

        let ChangePerformancePackageAuthorityParams {
            new_performance_package_authority: new_locker_authority,
        } = params;

        let clock = Clock::get()?;
        let old_authority = performance_package.performance_package_authority;

        // Update the locker authority
        performance_package.performance_package_authority = new_locker_authority;

        performance_package.seq_num += 1;

        // Emit event
        emit!(PerformancePackageAuthorityChanged {
            common: CommonFields::new(&clock, performance_package.seq_num),
            locker: performance_package.key(),
            old_authority,
            new_authority: new_locker_authority,
        });

        Ok(())
    }
}
use super::*;

pub mod change_performance_package_authority;
pub mod complete_unlock;
pub mod execute_change;
pub mod initialize_performance_package;
pub mod propose_change;
pub mod start_unlock;

pub use change_performance_package_authority::*;
pub use complete_unlock::*;
pub use execute_change::*;
pub use initialize_performance_package::*;
pub use propose_change::*;
pub use start_unlock::*;
use anchor_lang::prelude::*;

use super::*;

#[derive(Accounts)]
#[event_cpi]
pub struct StartUnlock<'info> {
    #[account(mut, has_one = recipient)]
    pub performance_package: Account<'info, PerformancePackage>,

    /// CHECK: We will read the aggregator value from this account
    #[account(address = performance_package.oracle_config.oracle_account)]
    pub oracle_account: UncheckedAccount<'info>,

    /// Only the token recipient can start unlock
    pub recipient: Signer<'info>,
}

impl StartUnlock<'_> {
    pub fn validate(&self) -> Result<()> {
        require_eq!(
            self.performance_package.state,
            PerformancePackageState::Locked,
            PriceBasedPerformancePackageError::InvalidPerformancePackageState
        );

        Ok(())
    }

    pub fn handle(ctx: Context<Self>) -> Result<()> {
        let Self {
            performance_package,
            oracle_account: _,
            recipient: _,
            event_authority: _,
            program: _,
        } = ctx.accounts;

        let clock = Clock::get()?;

        // Verify that the current time is past the unlock timestamp
        require_gte!(
            clock.unix_timestamp,
            performance_package.min_unlock_timestamp,
            PriceBasedPerformancePackageError::UnlockTimestampNotReached
        );

        // Read the current aggregator value from the oracle account
        let oracle_data = ctx.accounts.oracle_account.try_borrow_data()?;
        let offset = performance_package.oracle_config.byte_offset as usize;

        // Ensure we have enough data to read 24 bytes (16 bytes for aggregator, 8 bytes for last updated slot)
        require_gte!(
            oracle_data.len(),
            offset + 16 + 8,
            PriceBasedPerformancePackageError::InvalidOracleData
        );

        // Read the aggregator value (assuming it's stored as u128)
        let start_aggregator =
            u128::from_le_bytes(oracle_data[offset..offset + 16].try_into().unwrap());

        let last_updated_timestamp = i64::from_le_bytes(
            oracle_data[offset + 16..offset + 16 + 8]
                .try_into()
                .unwrap(),
        );

        // The last updated timestamp should be greater than or equal to the unlock timestamp
        // and less than or equal to the current time
        require_gte!(
            last_updated_timestamp,
            performance_package.min_unlock_timestamp,
            PriceBasedPerformancePackageError::InvalidOracleData
        );
        require_gte!(
            clock.unix_timestamp,
            last_updated_timestamp,
            PriceBasedPerformancePackageError::InvalidOracleData
        );

        performance_package.state = PerformancePackageState::Unlocking {
            start_aggregator,
            // We use the last updated timestamp to keep the aggregator and timestamp in sync
            start_timestamp: last_updated_timestamp,
        };

        performance_package.seq_num += 1;

        emit_cpi!(UnlockStarted {
            common: CommonFields::new(&clock, performance_package.seq_num),
            performance_package: performance_package.key(),
            start_aggregator,
            start_timestamp: last_updated_timestamp,
        });

        Ok(())
    }
}
use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token::{self, Mint, Token, TokenAccount};

use super::*;

#[derive(Debug, Clone, AnchorSerialize, AnchorDeserialize, PartialEq, Eq)]
pub struct InitializePerformancePackageParams {
    pub tranches: Vec<Tranche>,
    pub min_unlock_timestamp: i64,
    pub oracle_config: OracleConfig,
    pub twap_length_seconds: u32,
    pub grantee: Pubkey,
    pub performance_package_authority: Pubkey,
}

#[derive(Accounts)]
#[instruction(params: InitializePerformancePackageParams)]
#[event_cpi]
pub struct InitializePerformancePackage<'info> {
    #[account(
        init,
        payer = payer,
        seeds = [b"performance_package", create_key.key().as_ref()],
        bump,
        space = 8 + PerformancePackage::INIT_SPACE,
    )]
    pub performance_package: Account<'info, PerformancePackage>,
    /// Used to derive the PDA
    pub create_key: Signer<'info>,

    /// The mint of the tokens to be locked
    pub token_mint: Account<'info, Mint>,

    /// The token account containing the tokens to be locked
    #[account(mut, token::authority = grantor, token::mint = token_mint)]
    pub grantor_token_account: Box<Account<'info, TokenAccount>>,

    /// The authority of the token account
    pub grantor: Signer<'info>,

    /// The locker's token account where tokens will be stored
    #[account(
        init_if_needed,
        payer = payer,
        associated_token::mint = token_mint,
        associated_token::authority = performance_package,
    )]
    pub performance_package_token_vault: Box<Account<'info, TokenAccount>>,

    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
}

impl InitializePerformancePackage<'_> {
    pub fn handle(ctx: Context<Self>, params: InitializePerformancePackageParams) -> Result<()> {
        let Self {
            performance_package,
            create_key,
            token_mint,
            grantor_token_account,
            grantor,
            performance_package_token_vault,
            payer: _,
            system_program: _,
            token_program,
            associated_token_program: _,
            event_authority: _,
            program: _,
        } = ctx.accounts;

        let InitializePerformancePackageParams {
            tranches,
            min_unlock_timestamp,
            oracle_config,
            twap_length_seconds,
            grantee,
            performance_package_authority,
        } = params;

        require_neq!(tranches.len(), 0);

        require_gte!(MAX_TRANCHES, tranches.len());

        // validate that the tranches are sorted by price threshold
        for i in 1..tranches.len() {
            require_gt!(
                tranches[i].price_threshold,
                tranches[i - 1].price_threshold,
                PriceBasedPerformancePackageError::TranchePriceThresholdsNotMonotonic
            );
        }

        for tranche in tranches.iter() {
            require_gt!(
                tranche.token_amount,
                0,
                PriceBasedPerformancePackageError::TrancheTokenAmountZero
            );
        }

        require_gte!(
            twap_length_seconds,
            60 * 60 * 24,
            PriceBasedPerformancePackageError::InvalidTwapLength
        );

        require_gte!(
            60 * 60 * 24 * 365,
            twap_length_seconds,
            PriceBasedPerformancePackageError::InvalidTwapLength
        );

        let clock = Clock::get()?;

        // Validate that unlock timestamp is in the future
        require_gt!(
            min_unlock_timestamp,
            clock.unix_timestamp,
            PriceBasedPerformancePackageError::UnlockTimestampInThePast
        );

        let total_token_amount = tranches.iter().map(|tranche| tranche.token_amount).sum();

        require_gt!(total_token_amount, 0);

        require_gte!(grantor_token_account.amount, total_token_amount);

        // Transfer tokens from user to locker
        let transfer_ctx = CpiContext::new(
            token_program.to_account_info(),
            token::Transfer {
                from: grantor_token_account.to_account_info(),
                to: performance_package_token_vault.to_account_info(),
                authority: grantor.to_account_info(),
            },
        );

        token::transfer(transfer_ctx, total_token_amount)?;

        performance_package.set_inner(PerformancePackage {
            tranches: tranches.into_iter().map(|tranche| tranche.into()).collect(),
            min_unlock_timestamp,
            oracle_config,
            twap_length_seconds,
            recipient: grantee,
            state: PerformancePackageState::Locked,
            create_key: create_key.key(),
            pda_bump: ctx.bumps.performance_package,
            performance_package_authority,
            token_mint: token_mint.key(),
            total_token_amount,
            already_unlocked_amount: 0,
            performance_package_token_vault: performance_package_token_vault.key(),
            seq_num: 0,
        });

        emit_cpi!(PerformancePackageInitialized {
            common: CommonFields::new(&clock, performance_package.seq_num),
            performance_package: performance_package.key(),
            // performance_package_data: performance_package.clone().into_inner(),
        });

        Ok(())
    }
}
use crate::ChangeType;
use anchor_lang::prelude::*;

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct CommonFields {
    pub slot: u64,
    pub unix_timestamp: i64,
    pub performance_package_seq_num: u64,
}

impl CommonFields {
    pub fn new(clock: &Clock, performance_package_seq_num: u64) -> Self {
        Self {
            slot: clock.slot,
            unix_timestamp: clock.unix_timestamp,
            performance_package_seq_num,
        }
    }
}

#[event]
pub struct PerformancePackageInitialized {
    pub common: CommonFields,
    pub performance_package: Pubkey,
    // TODO: see CU gain of not including this
    // pub performance_package_data: PerformancePackage,
}

#[event]
pub struct UnlockStarted {
    pub common: CommonFields,
    pub performance_package: Pubkey,
    pub start_aggregator: u128,
    pub start_timestamp: i64,
}

#[event]
pub struct UnlockCompleted {
    pub common: CommonFields,
    pub performance_package: Pubkey,
    pub token_amount: u64,
    pub recipient: Pubkey,
    pub twap_price: u128,
}

#[event]
pub struct ChangeProposed {
    pub locker: Pubkey,
    pub change_request: Pubkey,
    pub proposer: Pubkey,
    pub change_type: ChangeType,
}

#[event]
pub struct ChangeExecuted {
    pub common: CommonFields,
    pub performance_package: Pubkey,
    pub change_request: Pubkey,
    pub executor: Pubkey,
    pub change_type: ChangeType,
}

#[event]
pub struct PerformancePackageAuthorityChanged {
    pub common: CommonFields,
    pub locker: Pubkey,
    pub old_authority: Pubkey,
    pub new_authority: Pubkey,
}
use anchor_lang::prelude::*;

#[constant]
pub const MAX_TRANCHES: usize = 10;
use anchor_lang::prelude::*;

#[error_code]
pub enum PriceBasedPerformancePackageError {
    #[msg("Unlock timestamp has not been reached yet")]
    UnlockTimestampNotReached,
    #[msg("Unlock timestamp must be in the future")]
    UnlockTimestampInThePast,
    #[msg("Performance package is not in the expected state")]
    InvalidPerformancePackageState,
    #[msg("TWAP calculation failed")]
    TwapPeriodNotElapsed,
    #[msg("Price threshold not met")]
    PriceThresholdNotMet,
    #[msg("Invalid oracle account data")]
    InvalidOracleData,
    #[msg("Unauthorized to create or execute change request")]
    UnauthorizedChangeRequest,
    #[msg("Change request does not match locker")]
    InvalidChangeRequest,
    #[msg("Unauthorized locker authority")]
    UnauthorizedLockerAuthority,
    #[msg("An invariant was violated. You should get in contact with the MetaDAO team if you see this")]
    InvariantViolated,
    #[msg("Tranche price thresholds must be monotonically increasing")]
    TranchePriceThresholdsNotMonotonic,
    #[msg("Tranche token amount must be greater than 0")]
    TrancheTokenAmountZero,
    #[msg("TWAP length must be greater than or equal to 1 day and less than 1 year")]
    InvalidTwapLength,
}
//! Price-Based Performance Package
//!
//! This program allows organizations to lock tokens that are unlocked to
//! recipients when those prices hit certain price thresholds.
//!
//! These tokens are split into up to 10 tranches, each of which is unlocked at a
//! different price threshold.
pub mod constants;
pub mod error;
pub mod events;
pub mod instructions;
pub mod state;

use anchor_lang::prelude::*;

pub use constants::*;
pub use error::*;
pub use events::*;
pub use instructions::*;
pub use state::*;

declare_id!("pbPPQH7jyKoSLu8QYs3rSY3YkDRXEBojKbTgnUg7NDS");

#[program]
pub mod price_based_performance_package {
    use super::*;

    pub fn initialize_performance_package(
        ctx: Context<InitializePerformancePackage>,
        params: InitializePerformancePackageParams,
    ) -> Result<()> {
        InitializePerformancePackage::handle(ctx, params)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn start_unlock(ctx: Context<StartUnlock>) -> Result<()> {
        StartUnlock::handle(ctx)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn complete_unlock(ctx: Context<CompleteUnlock>) -> Result<()> {
        CompleteUnlock::handle(ctx)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn propose_change(ctx: Context<ProposeChange>, params: ProposeChangeParams) -> Result<()> {
        ProposeChange::handle(ctx, params)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn execute_change(ctx: Context<ExecuteChange>) -> Result<()> {
        ExecuteChange::handle(ctx)
    }

    pub fn change_performance_package_authority(
        ctx: Context<ChangePerformancePackageAuthority>,
        params: ChangePerformancePackageAuthorityParams,
    ) -> Result<()> {
        ChangePerformancePackageAuthority::handle(ctx, params)
    }
}
use anchor_lang::prelude::*;

use crate::MAX_TRANCHES;

/// Starting at `byte_offset` in `oracle_account`, this program expects to read:
/// - 16 bytes for the aggregator, stored as a little endian u128
/// - 8 bytes for the slot that the aggregator was last updated, stored as a
///   little endian u64
///
/// The aggregator should be a weighted sum of prices, where the weight is the
/// number of seconds between prices. Here's an example:
/// - at second 0, the aggregator is 0
/// - at second 1, the price is 10 and the aggregator is 10 (10 * 1)
/// - at second 4, the price is 11 and 3 seconds have passed, so the aggregator is
///   10 + 11 * 3 = 43
///
/// This allows our program to read a TWAP over a time period by reading the
/// aggregator value at the beginning and at the end, and dividing the difference
/// by the number of seconds between the two.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug, PartialEq, Eq, InitSpace, Copy)]
pub struct OracleConfig {
    pub oracle_account: Pubkey,
    pub byte_offset: u32,
}

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, PartialEq, Eq, InitSpace)]
pub struct Tranche {
    /// The price at which this tranch unlocks
    pub price_threshold: u128,
    /// The amount of tokens in this tranch
    pub token_amount: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, PartialEq, Eq, InitSpace)]
pub struct StoredTranche {
    pub price_threshold: u128,
    pub token_amount: u64,
    pub is_unlocked: bool,
}

impl From<Tranche> for StoredTranche {
    fn from(tranche: Tranche) -> Self {
        Self {
            price_threshold: tranche.price_threshold,
            token_amount: tranche.token_amount,
            is_unlocked: false,
        }
    }
}

#[account]
#[derive(InitSpace, Debug)]
pub struct PerformancePackage {
    /// The tranches that make up the performance package
    #[max_len(MAX_TRANCHES)]
    pub tranches: Vec<StoredTranche>,
    /// Total amount of tokens in the performance package
    pub total_token_amount: u64,
    /// Amount of tokens already unlocked
    pub already_unlocked_amount: u64,
    /// The timestamp when unlocking can begin
    pub min_unlock_timestamp: i64,
    /// Where to pull price data from
    pub oracle_config: OracleConfig,
    /// Length of time in seconds for TWAP calculation, between 1 day and 1 year
    pub twap_length_seconds: u32,
    /// The recipient of the tokens when unlocked
    pub recipient: Pubkey,
    /// The current state of the locker
    pub state: PerformancePackageState,
    /// Used to derive the PDA
    pub create_key: Pubkey,
    /// The PDA bump
    pub pda_bump: u8,
    /// The authorized locker authority that can execute changes, usually the organization
    pub performance_package_authority: Pubkey,
    /// The mint of the locked tokens
    pub token_mint: Pubkey,
    /// The sequence number of the performance package, used for indexing events
    pub seq_num: u64,
    /// The vault that stores the tokens
    pub performance_package_token_vault: Pubkey,
}

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, Copy, PartialEq, Eq, InitSpace)]
pub enum PerformancePackageState {
    /// Initial state - waiting for unlock timestamp
    Locked,
    /// Unlocking has started - tracking TWAP
    Unlocking {
        /// The aggregator value when unlocking started
        start_aggregator: u128,
        /// The timestamp when unlocking started
        start_timestamp: i64,
    },
    /// Tokens have been unlocked and sent to recipient
    Unlocked,
}

impl ToString for PerformancePackageState {
    fn to_string(&self) -> String {
        match self {
            PerformancePackageState::Locked => "Locked".to_string(),
            PerformancePackageState::Unlocking {
                start_aggregator,
                start_timestamp,
            } => format!(
                "Unlocking (start_aggregator: {}, start_timestamp: {})",
                start_aggregator, start_timestamp
            ),
            PerformancePackageState::Unlocked => "Unlocked".to_string(),
        }
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, PartialEq, Eq, InitSpace)]
pub enum ChangeType {
    /// Change the oracle configuration
    Oracle { new_oracle_config: OracleConfig },
    /// Change the token recipient
    Recipient { new_recipient: Pubkey },
}

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, PartialEq, Eq, InitSpace)]
pub enum ProposerType {
    Recipient,
    Authority,
}

#[account]
#[derive(InitSpace)]
pub struct ChangeRequest {
    /// The performance package this change applies to
    pub performance_package: Pubkey,
    /// What is being changed
    pub change_type: ChangeType,
    /// When the change was proposed
    pub proposed_at: i64,
    /// Who proposed this change (either token_recipient or locker_authority)
    pub proposer_type: ProposerType,
    /// Used to derive the PDA along with the proposer
    pub pda_nonce: u32,
    /// The PDA bump
    pub pda_bump: u8,
}
pub mod performance_package;

pub use performance_package::*;
use crate::error::LaunchpadError;
use crate::events::{CommonFields, LaunchCloseEvent};
use crate::state::{Launch, LaunchState};
use anchor_lang::prelude::*;

#[event_cpi]
#[derive(Accounts)]
pub struct CloseLaunch<'info> {
    #[account(mut)]
    pub launch: Account<'info, Launch>,
}

impl CloseLaunch<'_> {
    pub fn validate(&self) -> Result<()> {
        require_eq!(
            self.launch.state,
            LaunchState::Live,
            LaunchpadError::LaunchNotLive
        );

        let clock = Clock::get()?;

        require_gte!(
            clock.unix_timestamp,
            self.launch
                .unix_timestamp_started
                .unwrap()
                .saturating_add(self.launch.seconds_for_launch.try_into().unwrap()),
            LaunchpadError::LaunchPeriodNotOver
        );

        Ok(())
    }

    pub fn handle(ctx: Context<Self>) -> Result<()> {
        let launch = &mut ctx.accounts.launch;
        let clock = Clock::get()?;

        if launch.minimum_raise_amount > launch.total_committed_amount {
            launch.state = LaunchState::Refunding;
            launch.unix_timestamp_closed = Some(clock.unix_timestamp);
        } else {
            launch.state = LaunchState::Closed;
            launch.unix_timestamp_closed = Some(clock.unix_timestamp);
        }

        launch.seq_num += 1;

        emit_cpi!(LaunchCloseEvent {
            common: CommonFields::new(&clock, launch.seq_num),
            launch: launch.key(),
            new_state: launch.state,
        });

        Ok(())
    }
}
use crate::error::LaunchpadError;
use crate::events::{CommonFields, LaunchStartedEvent};
use crate::state::{Launch, LaunchState};
use anchor_lang::prelude::*;

#[event_cpi]
#[derive(Accounts)]
pub struct StartLaunch<'info> {
    #[account(
        mut,
        has_one = launch_authority,
    )]
    pub launch: Account<'info, Launch>,

    pub launch_authority: Signer<'info>,
}

impl StartLaunch<'_> {
    pub fn validate(&self) -> Result<()> {
        require!(
            self.launch.state == LaunchState::Initialized,
            LaunchpadError::LaunchNotInitialized
        );

        Ok(())
    }

    pub fn handle(ctx: Context<Self>) -> Result<()> {
        let launch = &mut ctx.accounts.launch;
        let clock = Clock::get()?;

        launch.state = LaunchState::Live;
        launch.unix_timestamp_started = Some(clock.unix_timestamp);

        launch.seq_num += 1;

        emit_cpi!(LaunchStartedEvent {
            common: CommonFields::new(&clock, launch.seq_num),
            launch: ctx.accounts.launch.key(),
            launch_authority: ctx.accounts.launch_authority.key(),
            slot_started: clock.slot,
        });

        Ok(())
    }
}
use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token::{self, Mint, MintTo, Token, TokenAccount};

use crate::error::LaunchpadError;
use crate::events::{CommonFields, LaunchInitializedEvent};
use crate::state::{Launch, LaunchState};
use crate::MAX_PREMINE;
use crate::{
    usdc_mint, TOKENS_TO_DAMM_V2_LIQUIDITY, TOKENS_TO_FUTARCHY_LIQUIDITY, TOKENS_TO_PARTICIPANTS,
    TOKEN_SCALE,
};
use anchor_spl::metadata::{
    create_metadata_accounts_v3, mpl_token_metadata::types::DataV2,
    mpl_token_metadata::ID as MPL_TOKEN_METADATA_PROGRAM_ID, CreateMetadataAccountsV3, Metadata,
};

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct InitializeLaunchArgs {
    pub minimum_raise_amount: u64,
    pub monthly_spending_limit_amount: u64,
    pub monthly_spending_limit_members: Vec<Pubkey>,
    pub seconds_for_launch: u32,
    pub token_name: String,
    pub token_symbol: String,
    pub token_uri: String,
    pub performance_package_grantee: Pubkey,
    pub performance_package_token_amount: u64,
    pub months_until_insiders_can_unlock: u8,
}

#[event_cpi]
#[derive(Accounts)]
pub struct InitializeLaunch<'info> {
    #[account(
        init,
        payer = payer,
        space = 8 + Launch::INIT_SPACE,
        seeds = [b"launch", base_mint.key().as_ref()],
        bump
    )]
    pub launch: Account<'info, Launch>,

    #[account(
        mut,
        mint::decimals = 6,
        mint::authority = launch_signer,
    )]
    pub base_mint: Account<'info, Mint>,

    /// CHECK: This is the token metadata
    #[account(
        mut,
        seeds = [b"metadata", MPL_TOKEN_METADATA_PROGRAM_ID.as_ref(), base_mint.key().as_ref()],
        seeds::program = MPL_TOKEN_METADATA_PROGRAM_ID,
        bump
    )]
    pub token_metadata: UncheckedAccount<'info>,

    /// CHECK: This is the launch signer
    #[account(
        seeds = [b"launch_signer", launch.key().as_ref()],
        bump
    )]
    pub launch_signer: UncheckedAccount<'info>,

    #[account(
        init_if_needed,
        payer = payer,
        associated_token::mint = quote_mint,
        associated_token::authority = launch_signer
    )]
    pub quote_vault: Account<'info, TokenAccount>,

    #[account(
        init_if_needed,
        payer = payer,
        associated_token::mint = base_mint,
        associated_token::authority = launch_signer
    )]
    pub base_vault: Account<'info, TokenAccount>,

    #[account(mut)]
    pub payer: Signer<'info>,
    /// CHECK: account not used, just for constraints
    pub launch_authority: UncheckedAccount<'info>,

    #[account(mint::decimals = 6, address = usdc_mint::id())]
    pub quote_mint: Account<'info, Mint>,

    pub rent: Sysvar<'info, Rent>,

    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
    pub token_metadata_program: Program<'info, Metadata>,
}

impl InitializeLaunch<'_> {
    pub fn validate(&self, args: &InitializeLaunchArgs) -> Result<()> {
        // #[cfg(not(feature = "devnet"))]
        // require_gte!(
        //     args.seconds_for_launch,
        //     60 * 60,
        //     LaunchpadError::InvalidSecondsForLaunch
        // );

        require_gte!(
            60 * 60 * 24 * 14,
            args.seconds_for_launch,
            LaunchpadError::InvalidSecondsForLaunch
        );

        require!(
            self.base_mint.freeze_authority.is_none(),
            LaunchpadError::FreezeAuthoritySet
        );

        require_gte!(
            args.minimum_raise_amount,
            args.monthly_spending_limit_amount * 6,
            LaunchpadError::InvalidMonthlySpendingLimit
        );

        require_gte!(
            args.minimum_raise_amount,
            futarchy::MIN_QUOTE_LIQUIDITY * 5,
            LaunchpadError::InvalidMinimumRaiseAmount
        );

        require_neq!(
            args.monthly_spending_limit_amount,
            0,
            LaunchpadError::InvalidMonthlySpendingLimit
        );

        require_gte!(
            futarchy::MAX_SPENDING_LIMIT_MEMBERS,
            args.monthly_spending_limit_members.len(),
            LaunchpadError::InvalidMonthlySpendingLimitMembers
        );

        require_gte!(
            MAX_PREMINE * TOKEN_SCALE,
            args.performance_package_token_amount,
            LaunchpadError::InvalidPriceBasedPremineAmount
        );

        require_gte!(
            args.months_until_insiders_can_unlock,
            18,
            LaunchpadError::InvalidPerformancePackageMinUnlockTime
        );

        require!(self.base_mint.supply == 0, LaunchpadError::SupplyNonZero);

        // #[cfg(feature = "production")]
        // {
        //     let base_token_key: String = self.base_mint.key().to_string();
        //     let last_4_chars = &base_token_key[base_token_key.len() - 4..];
        //     require_eq!("meta", last_4_chars, LaunchpadError::InvalidTokenKey);
        // }

        Ok(())
    }

    pub fn handle(ctx: Context<Self>, args: InitializeLaunchArgs) -> Result<()> {
        ctx.accounts.launch.set_inner(Launch {
            minimum_raise_amount: args.minimum_raise_amount,
            monthly_spending_limit_amount: args.monthly_spending_limit_amount,
            monthly_spending_limit_members: args.monthly_spending_limit_members,
            launch_authority: ctx.accounts.launch_authority.key(),
            launch_signer: ctx.accounts.launch_signer.key(),
            launch_signer_pda_bump: ctx.bumps.launch_signer,
            launch_quote_vault: ctx.accounts.quote_vault.key(),
            launch_base_vault: ctx.accounts.base_vault.key(),
            total_committed_amount: 0,
            base_mint: ctx.accounts.base_mint.key(),
            quote_mint: ctx.accounts.quote_mint.key(),
            pda_bump: ctx.bumps.launch,
            seq_num: 0,
            state: LaunchState::Initialized,
            unix_timestamp_started: None,
            unix_timestamp_closed: None,
            final_raise_amount: None,
            seconds_for_launch: args.seconds_for_launch,
            dao: None,
            dao_vault: None,
            performance_package_grantee: args.performance_package_grantee,
            performance_package_token_amount: args.performance_package_token_amount,
            months_until_insiders_can_unlock: args.months_until_insiders_can_unlock,
        });

        let clock = Clock::get()?;
        emit_cpi!(LaunchInitializedEvent {
            common: CommonFields::new(&clock, 0),
            launch: ctx.accounts.launch.key(),
            minimum_raise_amount: args.minimum_raise_amount,
            launch_authority: ctx.accounts.launch_authority.key(),
            launch_signer: ctx.accounts.launch_signer.key(),
            launch_signer_pda_bump: ctx.bumps.launch_signer,
            launch_usdc_vault: ctx.accounts.quote_vault.key(),
            launch_token_vault: ctx.accounts.base_vault.key(),
            base_mint: ctx.accounts.base_mint.key(),
            quote_mint: ctx.accounts.quote_mint.key(),
            pda_bump: ctx.bumps.launch,
            seconds_for_launch: args.seconds_for_launch,
        });

        let launch_key = ctx.accounts.launch.key();

        let seeds = &[
            b"launch_signer",
            launch_key.as_ref(),
            &[ctx.bumps.launch_signer],
        ];
        let signer = &[&seeds[..]];

        let cpi_program = ctx.accounts.token_metadata_program.to_account_info();

        let cpi_accounts = CreateMetadataAccountsV3 {
            metadata: ctx.accounts.token_metadata.to_account_info(),
            mint: ctx.accounts.base_mint.to_account_info(),
            mint_authority: ctx.accounts.launch_signer.to_account_info(),
            payer: ctx.accounts.payer.to_account_info(),
            update_authority: ctx.accounts.launch_signer.to_account_info(),
            system_program: ctx.accounts.system_program.to_account_info(),
            rent: ctx.accounts.rent.to_account_info(),
        };

        create_metadata_accounts_v3(
            CpiContext::new(cpi_program, cpi_accounts).with_signer(signer),
            DataV2 {
                name: args.token_name.clone(),
                symbol: args.token_symbol.clone(),
                uri: args.token_uri.clone(),
                seller_fee_basis_points: 0,
                creators: None,
                collection: None,
                uses: None,
            },
            true,
            true,
            None,
        )?;

        // Mint total tokens to launch token vault
        // Include premine amount since complete_launch will transfer it to price-based unlock
        token::mint_to(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                MintTo {
                    mint: ctx.accounts.base_mint.to_account_info(),
                    to: ctx.accounts.base_vault.to_account_info(),
                    authority: ctx.accounts.launch_signer.to_account_info(),
                },
                signer,
            ),
            args.performance_package_token_amount
                + TOKENS_TO_PARTICIPANTS
                + TOKENS_TO_FUTARCHY_LIQUIDITY
                + TOKENS_TO_DAMM_V2_LIQUIDITY,
        )?;

        Ok(())
    }
}
use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Transfer};

use crate::error::LaunchpadError;
use crate::events::{CommonFields, LaunchFundedEvent};
use crate::state::{FundingRecord, Launch, LaunchState};

#[event_cpi]
#[derive(Accounts)]
pub struct Fund<'info> {
    #[account(
        mut,
        has_one = launch_signer,
        has_one = launch_quote_vault,
    )]
    pub launch: Account<'info, Launch>,

    #[account(
        init_if_needed,
        payer = payer,
        space = 8 + FundingRecord::INIT_SPACE,
        seeds = [b"funding_record", launch.key().as_ref(), funder.key().as_ref()],
        bump
    )]
    pub funding_record: Account<'info, FundingRecord>,

    /// CHECK: just a signer
    pub launch_signer: UncheckedAccount<'info>,

    #[account(mut)]
    pub launch_quote_vault: Account<'info, TokenAccount>,

    pub funder: Signer<'info>,
    #[account(mut)]
    pub payer: Signer<'info>,

    #[account(
        mut,
        token::mint = launch.quote_mint,
        token::authority = funder
    )]
    pub funder_quote_account: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

impl Fund<'_> {
    pub fn validate(&self, amount: u64) -> Result<()> {
        require!(amount > 0, LaunchpadError::InvalidAmount);

        require_gte!(
            self.funder_quote_account.amount,
            amount,
            LaunchpadError::InsufficientFunds
        );

        require!(
            self.launch.state == LaunchState::Live,
            LaunchpadError::InvalidLaunchState
        );

        let clock = Clock::get()?;

        require_gte!(
            self.launch.unix_timestamp_started.unwrap() + self.launch.seconds_for_launch as i64,
            clock.unix_timestamp,
            LaunchpadError::LaunchExpired
        );

        Ok(())
    }

    pub fn handle(ctx: Context<Self>, amount: u64) -> Result<()> {
        // Transfer quote tokens from funder to vault
        token::transfer(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.funder_quote_account.to_account_info(),
                    to: ctx.accounts.launch_quote_vault.to_account_info(),
                    authority: ctx.accounts.funder.to_account_info(),
                },
            ),
            amount,
        )?;

        let funding_record = &mut ctx.accounts.funding_record;

        if funding_record.funder == ctx.accounts.funder.key() {
            funding_record.committed_amount += amount;
        } else {
            funding_record.set_inner(FundingRecord {
                pda_bump: ctx.bumps.funding_record,
                funder: ctx.accounts.funder.key(),
                launch: ctx.accounts.launch.key(),
                committed_amount: amount,
                is_tokens_claimed: false,
                is_usdc_refunded: false,
            });
        }

        // Update committed amount
        ctx.accounts.launch.total_committed_amount += amount;

        ctx.accounts.launch.seq_num += 1;

        let clock = Clock::get()?;
        emit_cpi!(LaunchFundedEvent {
            common: CommonFields::new(&clock, ctx.accounts.launch.seq_num),
            launch: ctx.accounts.launch.key(),
            funder: ctx.accounts.funder.key(),
            amount,
            total_committed: ctx.accounts.launch.total_committed_amount,
            funding_record: funding_record.key(),
            total_committed_by_funder: funding_record.committed_amount,
        });

        Ok(())
    }
}
use anchor_lang::prelude::*;
use anchor_spl::token::{self, Token, TokenAccount, Transfer};

use crate::error::LaunchpadError;
use crate::events::{CommonFields, LaunchRefundedEvent};
use crate::state::{FundingRecord, Launch, LaunchState};

#[event_cpi]
#[derive(Accounts)]
pub struct Refund<'info> {
    #[account(
        mut,
        has_one = launch_quote_vault,
        has_one = launch_signer,
    )]
    pub launch: Account<'info, Launch>,

    #[account(
        mut,
        has_one = funder,
        seeds = [b"funding_record", launch.key().as_ref(), funder.key().as_ref()],
        bump = funding_record.pda_bump
    )]
    pub funding_record: Account<'info, FundingRecord>,

    #[account(mut)]
    pub launch_quote_vault: Account<'info, TokenAccount>,

    /// CHECK: just a signer
    pub launch_signer: UncheckedAccount<'info>,

    /// CHECK: not used, just for constraints
    pub funder: UncheckedAccount<'info>,

    #[account(mut, associated_token::mint = launch.quote_mint, associated_token::authority = funder)]
    pub funder_quote_account: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

impl Refund<'_> {
    pub fn validate(&self) -> Result<()> {
        require!(
            self.launch.state == LaunchState::Refunding
                || (self.launch.state == LaunchState::Complete
                    && self.launch.final_raise_amount.unwrap()
                        < self.launch.total_committed_amount),
            LaunchpadError::LaunchNotRefunding
        );

        require!(
            !self.funding_record.is_usdc_refunded,
            LaunchpadError::MoneyAlreadyRefunded
        );

        Ok(())
    }

    pub fn handle(ctx: Context<Self>) -> Result<()> {
        let launch = &mut ctx.accounts.launch;
        let launch_key = launch.key();
        let funding_record = &mut ctx.accounts.funding_record;

        let amount_to_refund = match launch.state {
            LaunchState::Refunding => funding_record.committed_amount,
            LaunchState::Complete => {
                let amount_used_to_buy = ((launch.final_raise_amount.unwrap() as u128)
                    * funding_record.committed_amount as u128
                    / launch.total_committed_amount as u128)
                    as u64;

                funding_record.committed_amount - amount_used_to_buy
            }
            _ => unreachable!(),
        };

        let seeds = &[
            b"launch_signer",
            launch_key.as_ref(),
            &[launch.launch_signer_pda_bump],
        ];
        let signer = &[&seeds[..]];

        funding_record.is_usdc_refunded = true;

        // Transfer USDC back to the user
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.launch_quote_vault.to_account_info(),
                    to: ctx.accounts.funder_quote_account.to_account_info(),
                    authority: ctx.accounts.launch_signer.to_account_info(),
                },
                signer,
            ),
            amount_to_refund,
        )?;

        launch.seq_num += 1;

        let clock = Clock::get()?;
        emit_cpi!(LaunchRefundedEvent {
            common: CommonFields::new(&clock, launch.seq_num),
            launch: ctx.accounts.launch.key(),
            funder: ctx.accounts.funder.key(),
            usdc_refunded: amount_to_refund,
            funding_record: ctx.accounts.funding_record.key(),
        });

        Ok(())
    }
}
pub mod claim;
pub mod close_launch;
pub mod complete_launch;
pub mod fund;
pub mod initialize_launch;
pub mod refund;
pub mod start_launch;

pub use claim::*;
pub use close_launch::*;
pub use complete_launch::*;
pub use fund::*;
pub use initialize_launch::*;
pub use refund::*;
pub use start_launch::*;
use anchor_lang::{prelude::*, system_program};
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::metadata::UpdateMetadataAccountsV2;
use anchor_spl::token::spl_token::instruction::AuthorityType;
use anchor_spl::token::{self, Mint, SetAuthority, Token, TokenAccount, Transfer};
use anchor_spl::token_2022::Token2022;
use anchor_spl::token_interface;
use damm_v2_cpi::constants::seeds::{
    POOL_AUTHORITY_PREFIX, POOL_PREFIX, POSITION_NFT_ACCOUNT_PREFIX, POSITION_PREFIX,
    TOKEN_VAULT_PREFIX,
};
use damm_v2_cpi::constants::MAX_SQRT_PRICE;
use damm_v2_cpi::BaseFeeParameters;

use crate::error::LaunchpadError;
use crate::events::{CommonFields, LaunchCompletedEvent};
use crate::state::{Launch, LaunchState};
use crate::{
    TOKENS_TO_DAMM_V2_LIQUIDITY_UNSCALED, TOKENS_TO_FUTARCHY_LIQUIDITY, TOKENS_TO_PARTICIPANTS,
    TOKEN_SCALE,
};
use anchor_spl::metadata::{
    mpl_token_metadata::ID as MPL_TOKEN_METADATA_PROGRAM_ID, update_metadata_accounts_v2, Metadata,
};

use futarchy::program::Futarchy;
use futarchy::{InitialSpendingLimit, InitializeDaoParams, ProvideLiquidityParams};

use price_based_performance_package::program::PriceBasedPerformancePackage;
use price_based_performance_package::{InitializePerformancePackageParams, OracleConfig, Tranche};

use damm_v2_cpi::program::DammV2Cpi;

pub const PRICE_SCALE: u128 = 1_000_000_000_000;

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy)]
pub struct CompleteLaunchArgs {
    pub final_raise_amount: Option<u64>,
}

/// Static accounts for completing a launch, used to reduce code duplication
/// and conserve stack space.
#[derive(Accounts)]
pub struct StaticCompleteLaunchAccounts<'info> {
    pub futarchy_program: Program<'info, Futarchy>,
    pub token_metadata_program: Program<'info, Metadata>,
    /// CHECK: checked by autocrat program
    pub autocrat_event_authority: UncheckedAccount<'info>,
    pub squads_program: Program<'info, squads_multisig_program::program::SquadsMultisigProgram>,
    /// CHECK: checked by squads multisig program
    #[account(seeds = [squads_multisig_program::SEED_PREFIX, squads_multisig_program::SEED_PROGRAM_CONFIG], bump, seeds::program = squads_program)]
    pub squads_program_config: UncheckedAccount<'info>,
    /// CHECK: checked by squads multisig program
    #[account(mut)]
    pub squads_program_config_treasury: UncheckedAccount<'info>,
    pub price_based_performance_package_program: Program<'info, PriceBasedPerformancePackage>,
    /// CHECK: checked by price based performance package program
    pub price_based_performance_package_event_authority: UncheckedAccount<'info>,
}

pub fn max_key(left: &Pubkey, right: &Pubkey) -> [u8; 32] {
    std::cmp::max(left, right).to_bytes()
}

pub fn min_key(left: &Pubkey, right: &Pubkey) -> [u8; 32] {
    std::cmp::min(left, right).to_bytes()
}

#[derive(Accounts)]
pub struct MeteoraAccounts<'info> {
    pub damm_v2_program: Program<'info, DammV2Cpi>,
    /// CHECK: checked by damm v2 program, there should only be one config that works for us
    pub config: UncheckedAccount<'info>,

    pub token_2022_program: Program<'info, Token2022>,

    /// CHECK: checked by damm v2 program
    #[account(mut, seeds = [POSITION_NFT_ACCOUNT_PREFIX.as_ref(), position_nft_mint.key().as_ref()], bump, seeds::program = damm_v2_program)]
    pub position_nft_account: UncheckedAccount<'info>,

    /// CHECK: checked by damm v2 program
    #[account(mut, seeds = [
        POOL_PREFIX.as_ref(),
        config.key().as_ref(),
        &max_key(&base_mint.key(), &quote_mint.key()),
        &min_key(&base_mint.key(), &quote_mint.key()),
    ], bump, seeds::program = damm_v2_program)]
    pub pool: UncheckedAccount<'info>,

    /// CHECK: checked by damm v2 program
    #[account(mut, seeds = [POSITION_PREFIX.as_ref(), position_nft_mint.key().as_ref()], bump, seeds::program = damm_v2_program)]
    pub position: UncheckedAccount<'info>,

    /// CHECK: checked by damm v2 program
    #[account(mut, seeds = [b"position_nft_mint", base_mint.key().as_ref()], bump)]
    pub position_nft_mint: UncheckedAccount<'info>,

    /// CHECK: checked by root struct
    pub base_mint: UncheckedAccount<'info>,
    /// CHECK: checked by root struct
    pub quote_mint: UncheckedAccount<'info>,

    /// CHECK: checked by damm v2 program
    #[account(mut, seeds = [
        TOKEN_VAULT_PREFIX.as_ref(),
        base_mint.key().as_ref(),
        pool.key().as_ref(),
    ], bump, seeds::program = damm_v2_program)]
    pub token_a_vault: UncheckedAccount<'info>,

    /// CHECK: checked by damm v2 program
    #[account(mut, seeds = [
        TOKEN_VAULT_PREFIX.as_ref(),
        quote_mint.key().as_ref(),
        pool.key().as_ref(),
    ], bump, seeds::program = damm_v2_program)]
    pub token_b_vault: UncheckedAccount<'info>,

    /// CHECK: checked by damm v2 program
    #[account(seeds = [b"damm_pool_creator_authority"], bump)]
    pub pool_creator_authority: UncheckedAccount<'info>,

    /// CHECK: checked by damm v2 program
    #[account(seeds = [POOL_AUTHORITY_PREFIX.as_ref()], bump, seeds::program = damm_v2_program)]
    pub pool_authority: UncheckedAccount<'info>,

    /// CHECK: checked by damm v2 program
    pub damm_v2_event_authority: UncheckedAccount<'info>,
}

#[event_cpi]
#[derive(Accounts)]
pub struct CompleteLaunch<'info> {
    #[account(
        mut,
        has_one = launch_quote_vault,
        has_one = launch_base_vault,
        has_one = launch_signer,
        has_one = base_mint,
        has_one = quote_mint,
    )]
    pub launch: Box<Account<'info, Launch>>,

    pub launch_authority: Option<Signer<'info>>,

    /// CHECK: Token metadata
    #[account(
        mut,
        seeds = [b"metadata", MPL_TOKEN_METADATA_PROGRAM_ID.as_ref(), base_mint.key().as_ref()],
        seeds::program = MPL_TOKEN_METADATA_PROGRAM_ID,
        bump
    )]
    pub token_metadata: UncheckedAccount<'info>,

    #[account(mut)]
    pub payer: Signer<'info>,

    /// CHECK: just a signer
    #[account(mut)]
    pub launch_signer: UncheckedAccount<'info>,

    #[account(
        mut,
        associated_token::mint = quote_mint,
        associated_token::authority = launch_signer,
    )]
    pub launch_quote_vault: Box<Account<'info, TokenAccount>>,

    #[account(
        mut,
        associated_token::mint = base_mint,
        associated_token::authority = launch_signer,
    )]
    pub launch_base_vault: Box<Account<'info, TokenAccount>>,

    #[account(
        init_if_needed,
        payer = payer,
        associated_token::mint = quote_mint,
        associated_token::authority = squads_multisig_vault,
    )]
    pub treasury_quote_account: Box<Account<'info, TokenAccount>>,

    #[account(mut, address = meteora_accounts.base_mint.key())]
    pub base_mint: Box<Account<'info, Mint>>,

    #[account(address = meteora_accounts.quote_mint.key())]
    pub quote_mint: Box<Account<'info, Mint>>,

    /// CHECK: init by autocrat
    #[account(mut, seeds = [b"amm_position", dao.key().as_ref(), squads_multisig_vault.key().as_ref()], bump, seeds::program = static_accounts.futarchy_program)]
    pub dao_owned_lp_position: UncheckedAccount<'info>,

    /// CHECK: checked by autocrat
    #[account(mut)]
    pub futarchy_amm_base_vault: UncheckedAccount<'info>,

    /// CHECK: checked by autocrat
    #[account(mut)]
    pub futarchy_amm_quote_vault: UncheckedAccount<'info>,

    /// CHECK: this is the DAO account, init by autocrat
    #[account(mut)]
    pub dao: UncheckedAccount<'info>,

    /// CHECK: checked by autocrat program
    #[account(mut, seeds = [squads_multisig_program::SEED_PREFIX, squads_multisig_program::SEED_MULTISIG, dao.key().as_ref()], bump, seeds::program = static_accounts.squads_program)]
    pub squads_multisig: UncheckedAccount<'info>,
    /// CHECK: just a signer
    #[account(seeds = [squads_multisig_program::SEED_PREFIX, squads_multisig.key().as_ref(), squads_multisig_program::SEED_VAULT, 0_u8.to_le_bytes().as_ref()], bump, seeds::program = static_accounts.squads_program)]
    pub squads_multisig_vault: UncheckedAccount<'info>,
    /// CHECK: initialized by squads
    #[account(mut, seeds = [squads_multisig_program::SEED_PREFIX, squads_multisig.key().as_ref(), squads_multisig_program::SEED_SPENDING_LIMIT, dao.key().as_ref()], bump, seeds::program = static_accounts.squads_program)]
    pub spending_limit: UncheckedAccount<'info>,

    /// CHECK: initialized by price based performance package program
    // #[account(mut, seeds = [b"performance_package", launch_signer.key().as_ref()], bump, seeds::program = static_accounts.price_based_performance_package_program)]
    #[account(mut)]
    pub performance_package: UncheckedAccount<'info>,

    /// CHECK: initialized by price based performance package program
    #[account(mut)]
    pub performance_package_token_account: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub static_accounts: StaticCompleteLaunchAccounts<'info>,
    pub meteora_accounts: MeteoraAccounts<'info>,
}

impl CompleteLaunch<'_> {
    pub fn validate(&self) -> Result<()> {
        let clock = Clock::get()?;

        require_eq!(
            self.launch.state,
            LaunchState::Closed,
            LaunchpadError::InvalidLaunchState
        );

        // if the launch was closed within 2 days, the launch authority must be the one
        // to complete the launch
        let two_days_after_close = self.launch.unix_timestamp_closed.unwrap() + 60 * 60 * 24 * 2;
        if two_days_after_close > clock.unix_timestamp {
            if self.launch_authority.is_none() {
                msg!("Launch authority must complete launch until unix timestamp {}. Current time is {}.", two_days_after_close, clock.unix_timestamp);
                return Err(LaunchpadError::LaunchAuthorityNotSet.into());
            }
        }

        if self.launch_authority.is_some() {
            require_keys_eq!(
                self.launch_authority.as_ref().unwrap().key(),
                self.launch.launch_authority,
                LaunchpadError::LaunchAuthorityNotSet
            );
        }

        Ok(())
    }

    pub fn handle(ctx: Context<Self>, args: CompleteLaunchArgs) -> Result<()> {
        let CompleteLaunchArgs { final_raise_amount } = args;

        // if the launch authority has provided a final raise amount, use it.
        // else, if either they haven't provided a final raise amount or it was
        // completed permissionlessly, use the total committed amount
        let final_raise_amount =
            if final_raise_amount.is_some() && ctx.accounts.launch_authority.is_some() {
                final_raise_amount.unwrap()
            } else {
                ctx.accounts.launch.total_committed_amount
            };

        require_gte!(
            final_raise_amount,
            ctx.accounts.launch.minimum_raise_amount,
            LaunchpadError::FinalRaiseAmountTooLow
        );

        let launch_key = ctx.accounts.launch.key();
        let launch_signer_seeds = &[
            b"launch_signer",
            launch_key.as_ref(),
            &[ctx.accounts.launch.launch_signer_pda_bump],
        ];
        let launch_signer = &[&launch_signer_seeds[..]];

        // For the DAO, we want proposals to start at the price of the launch,
        // for the lagging TWAP to be able to move its latest observation by 5%
        // per update (300% per hour), and for proposers to need to lock up 1%
        // of the supply and an equivalent value of USDC.

        let price_1e12 =
            ((final_raise_amount as u128) * PRICE_SCALE) / (TOKENS_TO_PARTICIPANTS as u128);

        let usdc_to_lp = final_raise_amount.saturating_div(5);
        let usdc_to_dao = final_raise_amount.saturating_sub(usdc_to_lp);

        let clock = Clock::get()?;

        ctx.accounts.initialize_dao(launch_signer, price_1e12)?;

        ctx.accounts.initialize_performance_package(
            price_1e12,
            clock.unix_timestamp,
            launch_signer,
        )?;

        ctx.accounts.provide_futarchy_amm_liquidity(
            usdc_to_lp,
            TOKENS_TO_FUTARCHY_LIQUIDITY,
            launch_signer,
        )?;

        ctx.accounts.provide_single_sided_meteora_liquidity(
            final_raise_amount,
            ctx.bumps.meteora_accounts.position_nft_mint,
            ctx.bumps.meteora_accounts.pool_creator_authority,
            launch_signer_seeds,
        )?;

        ctx.accounts.send_usdc_to_dao(usdc_to_dao, launch_signer)?;

        ctx.accounts.transfer_mint_authority_to_dao(launch_signer)?;

        ctx.accounts
            .transfer_metadata_authority_to_dao(launch_signer)?;

        let launch = &mut ctx.accounts.launch;

        launch.dao = Some(ctx.accounts.dao.key());
        launch.dao_vault = Some(ctx.accounts.squads_multisig_vault.key());
        launch.state = LaunchState::Complete;
        launch.final_raise_amount = Some(final_raise_amount);
        launch.seq_num += 1;

        emit_cpi!(LaunchCompletedEvent {
            common: CommonFields::new(&clock, launch.seq_num),
            launch: launch.key(),
            final_state: launch.state,
            total_committed: launch.total_committed_amount,
            dao: launch.dao,
            dao_treasury: launch.dao_vault,
        });

        let refundable_usdc = launch.total_committed_amount - final_raise_amount;

        ctx.accounts.verify_position_nft()?;
        ctx.accounts.verify_vaults(refundable_usdc)?;

        Ok(())
    }

    #[inline(never)]
    fn initialize_dao(&self, launch_signer: &[&[&[u8]]], launch_price_1e12: u128) -> Result<()> {
        futarchy::cpi::initialize_dao(
            CpiContext::new_with_signer(
                self.static_accounts.futarchy_program.to_account_info(),
                futarchy::cpi::accounts::InitializeDao {
                    dao: self.dao.to_account_info(),
                    dao_creator: self.launch_signer.to_account_info(),
                    payer: self.payer.to_account_info(),
                    system_program: self.system_program.to_account_info(),
                    base_mint: self.base_mint.to_account_info(),
                    quote_mint: self.quote_mint.to_account_info(),
                    event_authority: self
                        .static_accounts
                        .autocrat_event_authority
                        .to_account_info(),
                    program: self.static_accounts.futarchy_program.to_account_info(),
                    squads_multisig: self.squads_multisig.to_account_info(),
                    squads_multisig_vault: self.squads_multisig_vault.to_account_info(),
                    squads_program: self.static_accounts.squads_program.to_account_info(),
                    squads_program_config: self
                        .static_accounts
                        .squads_program_config
                        .to_account_info(),
                    squads_program_config_treasury: self
                        .static_accounts
                        .squads_program_config_treasury
                        .to_account_info(),
                    spending_limit: self.spending_limit.to_account_info(),
                    futarchy_amm_base_vault: self.futarchy_amm_base_vault.to_account_info(),
                    futarchy_amm_quote_vault: self.futarchy_amm_quote_vault.to_account_info(),
                    associated_token_program: self.associated_token_program.to_account_info(),
                    token_program: self.token_program.to_account_info(),
                },
                launch_signer,
            ),
            InitializeDaoParams {
                twap_initial_observation: launch_price_1e12,
                twap_max_observation_change_per_update: launch_price_1e12 / 20,
                // We're providing liquidity, so that can be used for proposals
                min_quote_futarchic_liquidity: 0,
                min_base_futarchic_liquidity: 0,
                pass_threshold_bps: 150,
                base_to_stake: TOKENS_TO_PARTICIPANTS / 100,
                seconds_per_proposal: 3 * 24 * 60 * 60,
                twap_start_delay_seconds: 24 * 60 * 60,
                nonce: 0,
                initial_spending_limit: Some(InitialSpendingLimit {
                    amount_per_month: self.launch.monthly_spending_limit_amount,
                    members: self.launch.monthly_spending_limit_members.clone(),
                }),
            },
        )
    }

    #[inline(never)]
    fn initialize_performance_package(
        &self,
        launch_price_1e12: u128,
        current_unix_timestamp: i64,
        launch_signer: &[&[&[u8]]],
    ) -> Result<()> {
        price_based_performance_package::cpi::initialize_performance_package(
            CpiContext::new_with_signer(
                self.static_accounts
                    .price_based_performance_package_program
                    .to_account_info(),
                price_based_performance_package::cpi::accounts::InitializePerformancePackage {
                    performance_package: self.performance_package.to_account_info(),
                    create_key: self.launch_signer.to_account_info(),
                    token_mint: self.base_mint.to_account_info(),
                    grantor_token_account: self.launch_base_vault.to_account_info(),
                    grantor: self.launch_signer.to_account_info(),
                    payer: self.payer.to_account_info(),
                    system_program: self.system_program.to_account_info(),
                    token_program: self.token_program.to_account_info(),
                    associated_token_program: self.associated_token_program.to_account_info(),
                    event_authority: self
                        .static_accounts
                        .price_based_performance_package_event_authority
                        .to_account_info(),
                    program: self
                        .static_accounts
                        .price_based_performance_package_program
                        .to_account_info(),
                    performance_package_token_vault: self
                        .performance_package_token_account
                        .to_account_info(),
                },
                launch_signer,
            ),
            InitializePerformancePackageParams {
                tranches: vec![
                    Tranche {
                        price_threshold: launch_price_1e12 * 2,
                        token_amount: self.launch.performance_package_token_amount / 5,
                    },
                    Tranche {
                        price_threshold: launch_price_1e12 * 4,
                        token_amount: self.launch.performance_package_token_amount / 5,
                    },
                    Tranche {
                        price_threshold: launch_price_1e12 * 8,
                        token_amount: self.launch.performance_package_token_amount / 5,
                    },
                    Tranche {
                        price_threshold: launch_price_1e12 * 16,
                        token_amount: self.launch.performance_package_token_amount / 5,
                    },
                    Tranche {
                        price_threshold: launch_price_1e12 * 32,
                        token_amount: self.launch.performance_package_token_amount / 5,
                    },
                ],
                min_unlock_timestamp: current_unix_timestamp
                    + (self.launch.months_until_insiders_can_unlock as i64 * 30 * 24 * 60 * 60),
                oracle_config: OracleConfig {
                    oracle_account: self.dao.key(),
                    // 8 bytes for `Dao` discriminator, 1 byte for `PoolState` enum discriminator
                    // spot `Pool` is always first and has the TWAP oracle
                    byte_offset: 8 + 1,
                },
                // 3 month TWAP
                twap_length_seconds: 3 * 30 * 24 * 60 * 60,
                grantee: self.launch.performance_package_grantee,
                performance_package_authority: self.squads_multisig_vault.key(),
            },
        )
    }

    #[inline(never)]
    fn provide_futarchy_amm_liquidity(
        &self,
        usdc_to_lp: u64,
        tokens_to_lp: u64,
        launch_signer: &[&[&[u8]]],
    ) -> Result<()> {
        futarchy::cpi::provide_liquidity(
            CpiContext::new_with_signer(
                self.static_accounts.futarchy_program.to_account_info(),
                futarchy::cpi::accounts::ProvideLiquidity {
                    dao: self.dao.to_account_info(),
                    liquidity_provider: self.launch_signer.to_account_info(),
                    liquidity_provider_base_account: self.launch_base_vault.to_account_info(),
                    liquidity_provider_quote_account: self.launch_quote_vault.to_account_info(),
                    payer: self.payer.to_account_info(),
                    system_program: self.system_program.to_account_info(),
                    amm_base_vault: self.futarchy_amm_base_vault.to_account_info(),
                    amm_quote_vault: self.futarchy_amm_quote_vault.to_account_info(),
                    amm_position: self.dao_owned_lp_position.to_account_info(),
                    token_program: self.token_program.to_account_info(),
                    program: self.static_accounts.futarchy_program.to_account_info(),
                    event_authority: self
                        .static_accounts
                        .autocrat_event_authority
                        .to_account_info(),
                },
                launch_signer,
            ),
            ProvideLiquidityParams {
                max_base_amount: tokens_to_lp,
                quote_amount: usdc_to_lp,
                min_liquidity: 0,
                position_authority: self.squads_multisig_vault.key(),
            },
        )
    }

    fn provide_single_sided_meteora_liquidity(
        &self,
        final_raise_amount: u64,
        position_nft_mint_bump: u8,
        pool_creator_authority_bump: u8,
        launch_signer_seeds: &[&[u8]],
    ) -> Result<()> {
        system_program::transfer(
            CpiContext::new(
                self.system_program.to_account_info(),
                system_program::Transfer {
                    from: self.payer.to_account_info(),
                    to: self.launch_signer.to_account_info(),
                },
            ),
            5e7 as u64,
        )?;

        let base_mint_key = self.base_mint.key();
        let position_nft_mint_signer_seeds = &[
            b"position_nft_mint".as_ref(),
            base_mint_key.as_ref(),
            &[position_nft_mint_bump],
        ];

        let pool_creator_authority_signer_seeds = &[
            b"damm_pool_creator_authority".as_ref(),
            &[pool_creator_authority_bump],
        ];

        let pool_init_signer = &[
            &launch_signer_seeds[..],
            &position_nft_mint_signer_seeds[..],
            &pool_creator_authority_signer_seeds[..],
        ];

        // system_program::transfer(
        //     CpiContext::new(
        //         ctx.accounts.system_program.to_account_info(),
        //         system_program::Transfer {
        //             from: ctx.accounts.payer.to_account_info(),
        //             to: ctx.accounts.launch_signer.to_account_info(),
        //         },
        //     ),
        //     50_000_000,
        // )?;

        require_eq!(
            self.base_mint.decimals,
            6,
            LaunchpadError::InvariantViolated
        );
        require_eq!(
            self.quote_mint.decimals,
            6,
            LaunchpadError::InvariantViolated
        );

        // ref: https://github.com/MeteoraAg/damm-v2-sdk/blob/3d740ea8434af20a024d5d6fd08d60792dca9ca4/src/helpers/utils.ts#L121-L133
        let float_price = final_raise_amount as f64 / TOKENS_TO_PARTICIPANTS as f64;
        let sqrt_price = (float_price.sqrt() * 2_f64.powf(64.0)) as u128;

        // ref: https://github.com/MeteoraAg/damm-v2-sdk/blob/3d740ea8434af20a024d5d6fd08d60792dca9ca4/src/helpers/curve.ts#L36-L45
        // do it this way to avoid overflow
        let liquidity = ((MAX_SQRT_PRICE * TOKENS_TO_DAMM_V2_LIQUIDITY_UNSCALED as u128)
            / (MAX_SQRT_PRICE - sqrt_price))
            * TOKEN_SCALE as u128
            * sqrt_price;

        damm_v2_cpi::cpi::initialize_pool_with_dynamic_config(
            CpiContext::new_with_signer(
                self.meteora_accounts.damm_v2_program.to_account_info(),
                damm_v2_cpi::cpi::accounts::InitializePoolWithDynamicConfigCtx {
                    creator: self.squads_multisig_vault.to_account_info(),
                    position_nft_mint: self.meteora_accounts.position_nft_mint.to_account_info(),
                    position_nft_account: self
                        .meteora_accounts
                        .position_nft_account
                        .to_account_info(),
                    payer: self.launch_signer.to_account_info(),
                    pool_creator_authority: self
                        .meteora_accounts
                        .pool_creator_authority
                        .to_account_info(),
                    config: self.meteora_accounts.config.to_account_info(),
                    pool_authority: self.meteora_accounts.pool_authority.to_account_info(),
                    token_a_vault: self.meteora_accounts.token_a_vault.to_account_info(),
                    token_b_vault: self.meteora_accounts.token_b_vault.to_account_info(),
                    payer_token_a: self.launch_base_vault.to_account_info(),
                    payer_token_b: self.launch_quote_vault.to_account_info(),
                    token_a_program: self.token_program.to_account_info(),
                    token_b_program: self.token_program.to_account_info(),
                    token_2022_program: self.meteora_accounts.token_2022_program.to_account_info(),
                    system_program: self.system_program.to_account_info(),
                    pool: self.meteora_accounts.pool.to_account_info(),
                    position: self.meteora_accounts.position.to_account_info(),
                    token_a_mint: self.base_mint.to_account_info(),
                    token_b_mint: self.quote_mint.to_account_info(),
                    event_authority: self
                        .meteora_accounts
                        .damm_v2_event_authority
                        .to_account_info(),
                    program: self.meteora_accounts.damm_v2_program.to_account_info(),
                },
                pool_init_signer,
            ),
            damm_v2_cpi::InitializeCustomizablePoolParameters {
                pool_fees: damm_v2_cpi::PoolFeeParameters {
                    base_fee: BaseFeeParameters {
                        cliff_fee_numerator: 5000000,
                        number_of_period: 0,
                        period_frequency: 0,
                        reduction_factor: 0,
                        fee_scheduler_mode: 0,
                    },
                    padding: [0; 3],
                    dynamic_fee: None,
                },
                activation_point: None,
                activation_type: 0,
                collect_fee_mode: 0,
                sqrt_min_price: sqrt_price,
                sqrt_max_price: MAX_SQRT_PRICE,
                has_alpha_vault: false,
                liquidity,
                sqrt_price,
            },
        )
    }

    fn transfer_mint_authority_to_dao(&self, launch_signer: &[&[&[u8]]]) -> Result<()> {
        token::set_authority(
            CpiContext::new_with_signer(
                self.token_program.to_account_info(),
                SetAuthority {
                    account_or_mint: self.base_mint.to_account_info(),
                    current_authority: self.launch_signer.to_account_info(),
                },
                launch_signer,
            ),
            AuthorityType::MintTokens,
            Some(self.squads_multisig_vault.key()),
        )
    }

    fn transfer_metadata_authority_to_dao(&self, launch_signer: &[&[&[u8]]]) -> Result<()> {
        update_metadata_accounts_v2(
            CpiContext::new_with_signer(
                self.static_accounts
                    .token_metadata_program
                    .to_account_info(),
                UpdateMetadataAccountsV2 {
                    metadata: self.token_metadata.to_account_info(),
                    update_authority: self.launch_signer.to_account_info(),
                },
                launch_signer,
            ),
            Some(self.squads_multisig_vault.key()),
            None,
            None,
            None,
        )
    }

    fn send_usdc_to_dao(&self, usdc_to_send: u64, launch_signer: &[&[&[u8]]]) -> Result<()> {
        token::transfer(
            CpiContext::new_with_signer(
                self.token_program.to_account_info(),
                Transfer {
                    from: self.launch_quote_vault.to_account_info(),
                    to: self.treasury_quote_account.to_account_info(),
                    authority: self.launch_signer.to_account_info(),
                },
                launch_signer,
            ),
            usdc_to_send,
        )
    }

    // otherwise we can run out of stack space
    #[inline(never)]
    fn verify_vaults(&mut self, refundable_usdc: u64) -> Result<()> {
        self.launch_base_vault.reload()?;
        self.launch_quote_vault.reload()?;

        require_gte!(
            self.launch_base_vault.amount,
            TOKENS_TO_PARTICIPANTS,
            LaunchpadError::InvariantViolated
        );
        require_gte!(
            self.launch_quote_vault.amount,
            refundable_usdc,
            LaunchpadError::InvariantViolated
        );

        Ok(())
    }

    // otherwise we can run out of stack space
    #[inline(never)]
    fn verify_position_nft(&self) -> Result<()> {
        let position_nft_account = token_interface::TokenAccount::try_deserialize(
            &mut &self.meteora_accounts.position_nft_account.data.borrow()[..],
        )?;
        require_eq!(
            position_nft_account.amount,
            1,
            LaunchpadError::InvariantViolated
        );
        require_keys_eq!(
            position_nft_account.owner,
            self.squads_multisig_vault.key(),
            LaunchpadError::InvariantViolated
        );
        Ok(())
    }
}
use anchor_lang::prelude::*;
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};

use crate::error::LaunchpadError;
use crate::events::{CommonFields, LaunchClaimEvent};
use crate::state::{FundingRecord, Launch, LaunchState};
use crate::TOKENS_TO_PARTICIPANTS;

#[event_cpi]
#[derive(Accounts)]
pub struct Claim<'info> {
    #[account(
        mut,
        has_one = launch_signer,
        has_one = base_mint,
        has_one = launch_base_vault,
    )]
    pub launch: Account<'info, Launch>,

    #[account(
        mut,
        has_one = funder,
        seeds = [b"funding_record", launch.key().as_ref(), funder.key().as_ref()],
        bump = funding_record.pda_bump
    )]
    pub funding_record: Account<'info, FundingRecord>,

    /// CHECK: just a signer
    pub launch_signer: UncheckedAccount<'info>,

    #[account(mut)]
    pub base_mint: Account<'info, Mint>,

    #[account(mut)]
    pub launch_base_vault: Account<'info, TokenAccount>,

    /// CHECK: not used, just for constraints
    pub funder: UncheckedAccount<'info>,

    #[account(
        mut,
        associated_token::mint = base_mint,
        associated_token::authority = funder
    )]
    pub funder_token_account: Account<'info, TokenAccount>,

    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

impl Claim<'_> {
    pub fn validate(&self) -> Result<()> {
        require!(
            self.launch.state == LaunchState::Complete,
            LaunchpadError::InvalidLaunchState
        );

        require!(
            !self.funding_record.is_tokens_claimed,
            LaunchpadError::TokensAlreadyClaimed
        );

        Ok(())
    }

    pub fn handle(ctx: Context<Self>) -> Result<()> {
        let launch = &mut ctx.accounts.launch;
        let funding_record = &mut ctx.accounts.funding_record;
        let launch_key = launch.key();

        // Calculate tokens to transfer based on contribution percentage
        let token_amount = (funding_record.committed_amount as u128)
            .checked_mul(TOKENS_TO_PARTICIPANTS as u128)
            .unwrap()
            .checked_div(launch.total_committed_amount as u128)
            .unwrap() as u64;

        let seeds = &[
            b"launch_signer",
            launch_key.as_ref(),
            &[launch.launch_signer_pda_bump],
        ];
        let signer = &[&seeds[..]];

        funding_record.is_tokens_claimed = true;

        // Transfer tokens from vault to funder
        token::transfer(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.to_account_info(),
                Transfer {
                    from: ctx.accounts.launch_base_vault.to_account_info(),
                    to: ctx.accounts.funder_token_account.to_account_info(),
                    authority: ctx.accounts.launch_signer.to_account_info(),
                },
                signer,
            ),
            token_amount,
        )?;

        launch.seq_num += 1;

        let clock = Clock::get()?;
        emit_cpi!(LaunchClaimEvent {
            common: CommonFields::new(&clock, launch.seq_num),
            launch: launch.key(),
            funder: ctx.accounts.funder.key(),
            tokens_claimed: token_amount,
            funding_record: funding_record.key(),
        });

        Ok(())
    }
}
use crate::state::LaunchState;
use anchor_lang::prelude::*;

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct CommonFields {
    pub slot: u64,
    pub unix_timestamp: i64,
    pub launch_seq_num: u64,
}

impl CommonFields {
    pub fn new(clock: &Clock, launch_seq_num: u64) -> Self {
        Self {
            slot: clock.slot,
            unix_timestamp: clock.unix_timestamp,
            launch_seq_num,
        }
    }
}

#[event]
pub struct LaunchInitializedEvent {
    pub common: CommonFields,
    pub launch: Pubkey,
    pub minimum_raise_amount: u64,
    pub launch_authority: Pubkey,
    pub launch_signer: Pubkey,
    pub launch_signer_pda_bump: u8,
    pub launch_usdc_vault: Pubkey,
    pub launch_token_vault: Pubkey,
    pub base_mint: Pubkey,
    pub quote_mint: Pubkey,
    pub pda_bump: u8,
    pub seconds_for_launch: u32,
}

#[event]
pub struct LaunchStartedEvent {
    pub common: CommonFields,
    pub launch: Pubkey,
    pub launch_authority: Pubkey,
    pub slot_started: u64,
}

#[event]
pub struct LaunchFundedEvent {
    pub common: CommonFields,
    pub funding_record: Pubkey,
    pub launch: Pubkey,
    pub funder: Pubkey,
    pub amount: u64,
    pub total_committed_by_funder: u64,
    pub total_committed: u64,
}

#[event]
pub struct LaunchCompletedEvent {
    pub common: CommonFields,
    pub launch: Pubkey,
    pub final_state: LaunchState,
    pub total_committed: u64,
    pub dao: Option<Pubkey>,
    pub dao_treasury: Option<Pubkey>,
}

#[event]
pub struct LaunchRefundedEvent {
    pub common: CommonFields,
    pub launch: Pubkey,
    pub funder: Pubkey,
    pub usdc_refunded: u64,
    pub funding_record: Pubkey,
}

#[event]
pub struct LaunchClaimEvent {
    pub common: CommonFields,
    pub launch: Pubkey,
    pub funder: Pubkey,
    pub tokens_claimed: u64,
    pub funding_record: Pubkey,
}

#[event]
pub struct LaunchCloseEvent {
    pub common: CommonFields,
    pub launch: Pubkey,
    pub new_state: LaunchState,
}
use anchor_lang::prelude::*;

#[error_code]
pub enum LaunchpadError {
    #[msg("Invalid amount")]
    InvalidAmount,
    #[msg("Supply must be zero")]
    SupplyNonZero,
    #[msg("Launch period must be between 1 hour and 2 weeks")]
    InvalidSecondsForLaunch,
    #[msg("Insufficient funds")]
    InsufficientFunds,
    #[msg("Token mint key must end in 'meta'")]
    InvalidTokenKey,
    #[msg("Invalid launch state")]
    InvalidLaunchState,
    #[msg("Launch period not over")]
    LaunchPeriodNotOver,
    #[msg("Launch is complete, no more funding allowed")]
    LaunchExpired,
    #[msg("For you to get a refund, either the launch needs to be in a refunding state or the launch must have been over-committed")]
    LaunchNotRefunding,
    #[msg("Launch must be initialized to be started")]
    LaunchNotInitialized,
    #[msg("Freeze authority can't be set on launchpad tokens")]
    FreezeAuthoritySet,
    #[msg("Monthly spending limit must be less than 1/6th of the minimum raise amount and cannot be 0")]
    InvalidMonthlySpendingLimit,
    #[msg("There can only be at most 10 monthly spending limit members")]
    InvalidMonthlySpendingLimitMembers,
    #[msg("Cannot do more than a 50% premine")]
    InvalidPriceBasedPremineAmount,
    #[msg("Insiders must be forced to wait at least 18 months before unlocking their tokens")]
    InvalidPerformancePackageMinUnlockTime,
    #[msg("Launch authority must be set to complete the launch until 2 days after closing")]
    LaunchAuthorityNotSet,
    #[msg("The final amount raised must be greater than or equal to the minimum raise amount")]
    FinalRaiseAmountTooLow,
    #[msg("Tokens already claimed")]
    TokensAlreadyClaimed,
    #[msg("Money already refunded")]
    MoneyAlreadyRefunded,
    #[msg("An invariant was violated. You should get in contact with the MetaDAO team if you see this")]
    InvariantViolated,
    #[msg("Launch must be live to be closed")]
    LaunchNotLive,
    #[msg("Minimum raise amount must be greater than or equal to $0.5 so that there's enough liquidity for the launch")]
    InvalidMinimumRaiseAmount,
}
//! A smart contract that facilitates the creation of new futarchic DAOs.
use anchor_lang::prelude::*;

pub mod allocator;
pub mod error;
pub mod events;
pub mod instructions;
pub mod state;

use instructions::*;

#[cfg(not(feature = "no-entrypoint"))]
use solana_security_txt::security_txt;

#[cfg(not(feature = "no-entrypoint"))]
security_txt! {
    name: "launchpad",
    project_url: "https://metadao.fi",
    contacts: "telegram:metaproph3t,telegram:kollan_house",
    source_code: "https://github.com/metaDAOproject/programs",
    source_release: "v0.6.0",
    policy: "The market will decide whether we pay a bug bounty.",
    acknowledgements: "DCF = (CF1 / (1 + r)^1) + (CF2 / (1 + r)^2) + ... (CFn / (1 + r)^n)"
}

declare_id!("MooNyh4CBUYEKyXVnjGYQ8mEiJDpGvJMdvrZx1iGeHV");

pub const TOKEN_SCALE: u64 = 1_000_000;

/// 10M tokens with 6 decimals
pub const TOKENS_TO_PARTICIPANTS: u64 = 10_000_000 * TOKEN_SCALE;
/// 20% to liquidity
pub const TOKENS_TO_FUTARCHY_LIQUIDITY: u64 = 2_000_000 * TOKEN_SCALE;
/// 3M tokens to single-sided DammV2 liquidity
pub const TOKENS_TO_DAMM_V2_LIQUIDITY: u64 = TOKENS_TO_DAMM_V2_LIQUIDITY_UNSCALED * TOKEN_SCALE;
/// we need this to prevent overflow
pub const TOKENS_TO_DAMM_V2_LIQUIDITY_UNSCALED: u64 = 3_000_000;

/// Max 50% premine
pub const MAX_PREMINE: u64 = 10_000_000 * TOKEN_SCALE;

pub mod usdc_mint {
    use anchor_lang::prelude::declare_id;

    #[cfg(feature = "devnet")]
    declare_id!("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU");

    #[cfg(not(feature = "devnet"))]
    declare_id!("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v");
}

#[program]
pub mod launchpad {
    use super::*;

    #[access_control(ctx.accounts.validate(&args))]
    pub fn initialize_launch(
        ctx: Context<InitializeLaunch>,
        args: InitializeLaunchArgs,
    ) -> Result<()> {
        InitializeLaunch::handle(ctx, args)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn start_launch(ctx: Context<StartLaunch>) -> Result<()> {
        StartLaunch::handle(ctx)
    }

    #[access_control(ctx.accounts.validate(amount))]
    pub fn fund(ctx: Context<Fund>, amount: u64) -> Result<()> {
        Fund::handle(ctx, amount)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn complete_launch(ctx: Context<CompleteLaunch>, args: CompleteLaunchArgs) -> Result<()> {
        CompleteLaunch::handle(ctx, args)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn refund(ctx: Context<Refund>) -> Result<()> {
        Refund::handle(ctx)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn claim(ctx: Context<Claim>) -> Result<()> {
        Claim::handle(ctx)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn close_launch(ctx: Context<CloseLaunch>) -> Result<()> {
        CloseLaunch::handle(ctx)
    }
}
use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct FundingRecord {
    /// The PDA bump.
    pub pda_bump: u8,
    /// The funder.
    pub funder: Pubkey,
    /// The launch.
    pub launch: Pubkey,
    /// The amount of USDC that has been committed by the funder.
    pub committed_amount: u64,
    /// Whether the tokens have been claimed.
    pub is_tokens_claimed: bool,
    /// Whether the USDC has been refunded.
    pub is_usdc_refunded: bool,
}
pub mod funding_record;
pub mod launch;

pub use funding_record::*;
pub use launch::*;
use anchor_lang::prelude::*;

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, PartialEq, Eq, InitSpace)]
pub enum LaunchState {
    Initialized,
    Live,
    Closed,
    Complete,
    Refunding,
}

impl ToString for LaunchState {
    fn to_string(&self) -> String {
        match self {
            LaunchState::Initialized => "Initialized",
            LaunchState::Live => "Live",
            LaunchState::Closed => "Closed",
            LaunchState::Complete => "Complete",
            LaunchState::Refunding => "Refunding",
        }
        .to_string()
    }
}

#[account]
#[derive(InitSpace)]
pub struct Launch {
    /// The PDA bump.
    pub pda_bump: u8,
    /// The minimum amount of USDC that must be raised, otherwise
    /// everyone can get their USDC back.
    pub minimum_raise_amount: u64,
    /// The monthly spending limit the DAO allocates to the team. Must be
    /// less than 1/6th of the minimum raise amount (so 6 months of burn).
    pub monthly_spending_limit_amount: u64,
    /// The wallets that have access to the monthly spending limit.
    #[max_len(10)]
    pub monthly_spending_limit_members: Vec<Pubkey>,
    /// The account that can start the launch.
    pub launch_authority: Pubkey,
    /// The launch signer address. Needed because Raydium pools need a SOL payer and this PDA can't hold SOL.
    pub launch_signer: Pubkey,
    /// The PDA bump for the launch signer.
    pub launch_signer_pda_bump: u8,
    /// The USDC vault that will hold the USDC raised until the launch is over.
    pub launch_quote_vault: Pubkey,
    /// The token vault, used to send tokens to Raydium.
    pub launch_base_vault: Pubkey,
    /// The token that will be minted to funders and that will control the DAO.
    pub base_mint: Pubkey,
    /// The USDC mint.
    pub quote_mint: Pubkey,
    /// The unix timestamp when the launch was started.
    pub unix_timestamp_started: Option<i64>,
    /// The unix timestamp when the launch stopped taking new contributions.
    pub unix_timestamp_closed: Option<i64>,
    /// The amount of USDC that has been committed by the users.
    pub total_committed_amount: u64,
    /// The final raise amount.
    pub final_raise_amount: Option<u64>,
    /// The state of the launch.
    pub state: LaunchState,
    /// The sequence number of this launch. Useful for sorting events.
    pub seq_num: u64,
    /// The number of seconds that the launch will be live for.
    pub seconds_for_launch: u32,
    /// The DAO, if the launch is complete.
    pub dao: Option<Pubkey>,
    /// The DAO treasury that USDC / LP is sent to, if the launch is complete.
    pub dao_vault: Option<Pubkey>,
    /// The address that will receive the performance package tokens.
    pub performance_package_grantee: Pubkey,
    /// The amount of tokens to be granted to the performance package grantee.
    pub performance_package_token_amount: u64,
    /// The number of months that insiders must wait before unlocking their tokens.
    pub months_until_insiders_can_unlock: u8,
}
// THIS COMES DIRECTLY FROM SQUADS V4, WHICH HAS BEEN AUDITED 10 TIMES:
// https://github.com/Squads-Protocol/v4/blob/8a5642853b3dda9817477c9b540d0f84d67ede13/programs/squads_multisig_program/src/allocator.rs#L1

/*
Optimizing Bump Heap Allocation

Objective: Increase available heap memory while maintaining flexibility in program invocation.

1. Initial State: Default 32 KiB Heap

Memory Layout:
0x300000000           0x300008000
      |                    |
      v                    v
      [--------------------]
      ^                    ^
      |                    |
 VM Lower              VM Upper
 Boundary              Boundary

Default Allocator (Allocates Backwards / Top Down) (Default 32 KiB):
0x300000000           0x300008000
      |                    |
      [--------------------]
                           ^
                           |
                  Allocation starts here (SAFE)

2. Naive Approach: Increase HEAP_LENGTH to 8 * 32 KiB + Default Allocator

Memory Layout with Increased HEAP_LENGTH:
0x300000000           0x300008000                          0x300040000
      |                    |                                     |
      v                    v                                     v
      [--------------------|------------------------------------|]
      ^                    ^                                     ^
      |                    |                                     |
 VM Lower              VM Upper                         Allocation starts here
 Boundary              Boundary                         (ACCESS VIOLATION!)

Issue: Access violation occurs without requestHeapFrame, requiring it for every transaction.

3. Optimized Solution: Forward Allocation with Flexible Heap Usage

Memory Layout (Same as Naive Approach):
0x300000000           0x300008000                          0x300040000
      |                    |                                     |
      v                    v                                     v
      [--------------------|------------------------------------|]
      ^                    ^                                     ^
      |                    |                                     |
 VM Lower              VM Upper                             Allocator & VM
 Boundary              Boundary                             Heap Limit

Forward Allocator Behavior:

a) Without requestHeapFrame:
0x300000000           0x300008000
      |                    |
      [--------------------]
      ^                    ^
      |                    |
 VM Lower               VM Upper
 Boundary               Boundary
 Allocation
 starts here (SAFE)

b) With requestHeapFrame:
0x300000000           0x300008000                          0x300040000
      |                    |                                     |
      [--------------------|------------------------------------|]
      ^                    ^                                     ^
      |                    |                                     |
 VM Lower                  |                                VM Upper
 Boundary                                                   Boundary
 Allocation        Allocation continues              Maximum allocation
 starts here       with requestHeapFrame             with requestHeapFrame
(SAFE)

Key Advantages:
1. Compatibility: Functions without requestHeapFrame for allocations ≤32 KiB.
2. Extensibility: Supports larger allocations when requestHeapFrame is invoked.
3. Efficiency: Eliminates mandatory requestHeapFrame calls for all transactions.

Conclusion:
The forward allocation strategy offers a robust solution, providing both backward
compatibility for smaller heap requirements and the flexibility to utilize extended
heap space when necessary.

The following allocator is a copy of the bump allocator found in
solana_program::entrypoint and
https://github.com/solana-labs/solana-program-library/blob/master/examples/rust/custom-heap/src/entrypoint.rs

but with changes to its HEAP_LENGTH and its
starting allocation address.
*/

use solana_program::entrypoint::HEAP_START_ADDRESS;
use std::{alloc::Layout, mem::size_of, ptr::null_mut};

/// Length of the memory region used for program heap.
pub const HEAP_LENGTH: usize = 8 * 32 * 1024;

struct BumpAllocator;

unsafe impl std::alloc::GlobalAlloc for BumpAllocator {
    #[inline]
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        const POS_PTR: *mut usize = HEAP_START_ADDRESS as *mut usize;
        const TOP_ADDRESS: usize = HEAP_START_ADDRESS as usize + HEAP_LENGTH;
        const BOTTOM_ADDRESS: usize = HEAP_START_ADDRESS as usize + size_of::<*mut u8>();
        let mut pos = *POS_PTR;
        if pos == 0 {
            // First time, set starting position to bottom address
            pos = BOTTOM_ADDRESS;
        }
        // Align the position upwards
        pos = (pos + layout.align() - 1) & !(layout.align() - 1);
        let next_pos = pos.saturating_add(layout.size());
        if next_pos > TOP_ADDRESS {
            return null_mut();
        }
        *POS_PTR = next_pos;
        pos as *mut u8
    }

    #[inline]
    unsafe fn dealloc(&self, _: *mut u8, _: Layout) {
        // I'm a bump allocator, I don't free
    }
}

// Only use the allocator if we're not in a no-entrypoint context
#[cfg(not(feature = "no-entrypoint"))]
#[global_allocator]
static A: BumpAllocator = BumpAllocator;
use super::*;

#[derive(Accounts)]
#[event_cpi]
pub struct InitializeProposal<'info> {
    #[account(
        init,
        payer = payer,
        space = 8 + Proposal::INIT_SPACE,
        seeds = [b"proposal", squads_proposal.key().as_ref()],
        bump
    )]
    pub proposal: Box<Account<'info, Proposal>>,
    pub squads_proposal: Box<Account<'info, squads_multisig_program::Proposal>>,
    #[account(mut)]
    pub dao: Box<Account<'info, Dao>>,
    #[account(
        constraint = question.oracle == proposal.key()
    )]
    pub question: Box<Account<'info, Question>>,
    #[account(
        constraint = quote_vault.underlying_token_mint == dao.quote_mint,
        has_one = question,
    )]
    pub quote_vault: Box<Account<'info, ConditionalVault>>,
    #[account(
        constraint = base_vault.underlying_token_mint == dao.base_mint,
        has_one = question,
    )]
    pub base_vault: Box<Account<'info, ConditionalVault>>,
    pub proposer: Signer<'info>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
}

impl InitializeProposal<'_> {
    pub fn validate(&self) -> Result<()> {
        require_eq!(
            self.question.num_outcomes(),
            2,
            FutarchyError::QuestionMustBeBinary
        );

        require_keys_eq!(self.squads_proposal.multisig, self.dao.squads_multisig);

        match self.squads_proposal.status {
            squads_multisig_program::ProposalStatus::Active { timestamp: _ } => {}
            _ => {
                msg!("squads proposal status: {:?}", self.squads_proposal.status);
                return Err(FutarchyError::InvalidSquadsProposalStatus.into());
            }
        }

        // Should never be the case because the oracle is the proposal account, and you can't re-initialize a proposal
        assert!(!self.question.is_resolved());

        Ok(())
    }

    pub fn handle(ctx: Context<Self>) -> Result<()> {
        let Self {
            base_vault,
            quote_vault,
            question,
            proposal,
            squads_proposal,
            dao,
            proposer,
            payer: _,
            system_program: _,
            event_authority: _,
            program: _,
        } = ctx.accounts;

        let clock = Clock::get()?;

        dao.proposal_count += 1;

        proposal.set_inner(Proposal {
            number: dao.proposal_count,
            squads_proposal: squads_proposal.key(),
            proposer: proposer.key(),
            timestamp_enqueued: clock.unix_timestamp,
            state: ProposalState::Draft { amount_staked: 0 },
            base_vault: base_vault.key(),
            quote_vault: quote_vault.key(),
            dao: dao.key(),
            pda_bump: ctx.bumps.proposal,
            question: question.key(),
            duration_in_seconds: dao.seconds_per_proposal,
            pass_base_mint: base_vault.conditional_token_mints[1],
            fail_base_mint: base_vault.conditional_token_mints[0],
            pass_quote_mint: quote_vault.conditional_token_mints[1],
            fail_quote_mint: quote_vault.conditional_token_mints[0],
        });

        dao.seq_num += 1;

        emit_cpi!(InitializeProposalEvent {
            common: CommonFields::new(&clock, dao.seq_num),
            proposal: proposal.key(),
            dao: dao.key(),
            question: question.key(),
            base_vault: base_vault.key(),
            quote_vault: quote_vault.key(),
            proposer: proposer.key(),
            number: dao.proposal_count,
            pda_bump: ctx.bumps.proposal,
            duration_in_seconds: proposal.duration_in_seconds,
            squads_proposal: squads_proposal.key(),
            squads_multisig: dao.squads_multisig,
            squads_multisig_vault: dao.squads_multisig_vault,
        });

        Ok(())
    }
}
use super::*;

#[derive(Debug, Clone, AnchorSerialize, AnchorDeserialize)]
pub struct StakeToProposalParams {
    pub amount: u64,
}

#[derive(Accounts)]
#[instruction(args: StakeToProposalParams)]
#[event_cpi]
pub struct StakeToProposal<'info> {
    #[account(mut)]
    pub proposal: Box<Account<'info, Proposal>>,
    #[account(mut)]
    pub dao: Box<Account<'info, Dao>>,
    #[account(
        mut,
        associated_token::mint = dao.base_mint,
        associated_token::authority = staker,
    )]
    pub staker_base_account: Box<Account<'info, TokenAccount>>,
    #[account(
        mut,
        associated_token::mint = dao.base_mint,
        associated_token::authority = proposal,
    )]
    pub proposal_base_account: Box<Account<'info, TokenAccount>>,
    #[account(
        init_if_needed,
        payer = payer,
        seeds = [b"stake", proposal.key().as_ref(), staker.key().as_ref()],
        bump,
        space = 8 + StakeAccount::INIT_SPACE,
    )]
    pub stake_account: Box<Account<'info, StakeAccount>>,
    pub staker: Signer<'info>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

impl StakeToProposal<'_> {
    pub fn validate(&self, params: &StakeToProposalParams) -> Result<()> {
        require!(
            matches!(self.proposal.state, ProposalState::Draft { .. }),
            FutarchyError::ProposalNotInDraftState
        );

        require_keys_eq!(self.proposal.dao, self.dao.key());

        require_gte!(
            self.staker_base_account.amount,
            params.amount,
            FutarchyError::InsufficientTokenBalance
        );

        require_gt!(params.amount, 0, FutarchyError::InvalidAmount);

        Ok(())
    }

    pub fn handle(ctx: Context<Self>, params: StakeToProposalParams) -> Result<()> {
        let Self {
            proposal,
            dao,
            staker_base_account,
            proposal_base_account,
            stake_account,
            staker,
            payer: _,
            token_program,
            associated_token_program: _,
            system_program: _,
            event_authority: _,
            program: _,
        } = ctx.accounts;

        let StakeToProposalParams { amount } = params;

        // Transfer tokens from staker to proposal
        let transfer_ctx = CpiContext::new(
            token_program.to_account_info(),
            Transfer {
                from: staker_base_account.to_account_info(),
                to: proposal_base_account.to_account_info(),
                authority: staker.to_account_info(),
            },
        );
        token::transfer(transfer_ctx, amount)?;

        // Update proposal state
        if let ProposalState::Draft { mut amount_staked } = proposal.state {
            amount_staked += amount;
            proposal.state = ProposalState::Draft { amount_staked };
        }

        // Update stake account
        if stake_account.proposal == Pubkey::default() {
            // Initialize the stake account
            stake_account.proposal = proposal.key();
            stake_account.staker = staker.key();
            stake_account.amount = amount;
            stake_account.bump = ctx.bumps.stake_account;
        } else {
            // Add to existing stake
            stake_account.amount += amount;
        }

        dao.seq_num += 1;

        let clock = Clock::get()?;

        emit_cpi!(StakeToProposalEvent {
            common: CommonFields::new(&clock, dao.seq_num),
            proposal: proposal.key(),
            staker: staker.key(),
            amount,
            total_staked: match proposal.state {
                ProposalState::Draft { amount_staked } => amount_staked,
                _ => unreachable!(),
            },
        });

        Ok(())
    }
}
use super::*;

#[derive(Accounts)]
#[event_cpi]
pub struct LaunchProposal<'info> {
    #[account(mut, has_one = dao, has_one = quote_vault, has_one = base_vault)]
    pub proposal: Box<Account<'info, Proposal>>,
    pub base_vault: Box<Account<'info, ConditionalVault>>,
    pub quote_vault: Box<Account<'info, ConditionalVault>>,
    #[account(address = base_vault.conditional_token_mints[1])]
    pub pass_base_mint: Box<Account<'info, Mint>>,
    #[account(address = quote_vault.conditional_token_mints[1])]
    pub pass_quote_mint: Box<Account<'info, Mint>>,
    #[account(address = base_vault.conditional_token_mints[0])]
    pub fail_base_mint: Box<Account<'info, Mint>>,
    #[account(address = quote_vault.conditional_token_mints[0])]
    pub fail_quote_mint: Box<Account<'info, Mint>>,
    #[account(mut)]
    pub dao: Box<Account<'info, Dao>>,
    #[account(mut)]
    pub payer: Signer<'info>,
    #[account(init_if_needed, payer = payer, associated_token::mint = pass_base_mint, associated_token::authority = dao)]
    pub amm_pass_base_vault: Box<Account<'info, TokenAccount>>,
    #[account(init_if_needed, payer = payer, associated_token::mint = pass_quote_mint, associated_token::authority = dao)]
    pub amm_pass_quote_vault: Box<Account<'info, TokenAccount>>,
    #[account(init_if_needed, payer = payer, associated_token::mint = fail_base_mint, associated_token::authority = dao)]
    pub amm_fail_base_vault: Box<Account<'info, TokenAccount>>,
    #[account(init_if_needed, payer = payer, associated_token::mint = fail_quote_mint, associated_token::authority = dao)]
    pub amm_fail_quote_vault: Box<Account<'info, TokenAccount>>,
    pub system_program: Program<'info, System>,
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
}

impl LaunchProposal<'_> {
    pub fn validate(&self) -> Result<()> {
        msg!("proposal state: {:?}", self.proposal.state);
        require!(
            matches!(self.proposal.state, ProposalState::Draft { .. }),
            FutarchyError::ProposalNotInDraftState
        );

        require_keys_eq!(self.proposal.dao, self.dao.key());

        // Check if sufficient stake has been accumulated
        if let ProposalState::Draft { amount_staked } = self.proposal.state {
            require_gte!(
                amount_staked,
                self.dao.base_to_stake,
                FutarchyError::InsufficientStakeToLaunch
            );
        }

        Ok(())
    }

    pub fn handle(ctx: Context<Self>) -> Result<()> {
        let Self {
            proposal,
            dao,
            payer: _,
            event_authority: _,
            program: _,
            // Below accounts are just so we can be sure they're initialized
            base_vault: _,
            quote_vault: _,
            pass_base_mint: _,
            pass_quote_mint: _,
            fail_base_mint: _,
            fail_quote_mint: _,
            amm_pass_base_vault: _,
            amm_pass_quote_vault: _,
            amm_fail_base_vault: _,
            amm_fail_quote_vault: _,
            system_program: _,
            token_program: _,
            associated_token_program: _,
        } = ctx.accounts;

        // Get the total staked amount
        let total_staked = match proposal.state {
            ProposalState::Draft { amount_staked } => amount_staked,
            _ => unreachable!(),
        };

        // Set up the futarchy AMM by splitting the spot pool reserves
        let PoolState::Spot { mut spot } = dao.amm.state.to_owned() else {
            return Err(FutarchyError::PoolNotInSpotState.into());
        };

        let base_to_lp = spot.base_reserves / 2;
        let quote_to_lp = spot.quote_reserves / 2;

        spot.base_reserves -= base_to_lp;
        spot.quote_reserves -= quote_to_lp;

        require_gte!(
            base_to_lp,
            dao.min_base_futarchic_liquidity,
            FutarchyError::InsufficientLiquidity
        );
        require_gte!(
            quote_to_lp,
            dao.min_quote_futarchic_liquidity,
            FutarchyError::InsufficientLiquidity
        );

        let clock = Clock::get()?;

        dao.amm.state = PoolState::Futarchy {
            spot,
            pass: Pool {
                base_reserves: base_to_lp,
                quote_reserves: quote_to_lp,
                quote_protocol_fee_balance: 0,
                base_protocol_fee_balance: 0,
                oracle: TwapOracle::new(
                    clock.unix_timestamp,
                    dao.twap_initial_observation,
                    dao.twap_max_observation_change_per_update,
                    dao.twap_start_delay_seconds,
                ),
            },
            fail: Pool {
                base_reserves: base_to_lp,
                quote_reserves: quote_to_lp,
                quote_protocol_fee_balance: 0,
                base_protocol_fee_balance: 0,
                oracle: TwapOracle::new(
                    clock.unix_timestamp,
                    dao.twap_initial_observation,
                    dao.twap_max_observation_change_per_update,
                    dao.twap_start_delay_seconds,
                ),
            },
        };

        // Update proposal state to Pending
        proposal.state = ProposalState::Pending;

        dao.seq_num += 1;

        emit_cpi!(LaunchProposalEvent {
            common: CommonFields::new(&clock, dao.seq_num),
            proposal: proposal.key(),
            dao: dao.key(),
            total_staked,
            post_amm_state: dao.amm.clone(),
        });

        Ok(())
    }
}
use super::*;

#[derive(Debug, Clone, Copy, AnchorSerialize, AnchorDeserialize, PartialEq, Eq)]
pub struct UpdateDaoParams {
    pub pass_threshold_bps: Option<u16>,
    pub seconds_per_proposal: Option<u32>,
    pub twap_initial_observation: Option<u128>,
    pub twap_max_observation_change_per_update: Option<u128>,
    pub min_quote_futarchic_liquidity: Option<u64>,
    pub min_base_futarchic_liquidity: Option<u64>,
    pub base_to_stake: Option<u64>,
}

#[derive(Accounts)]
#[event_cpi]
pub struct UpdateDao<'info> {
    #[account(mut, has_one = squads_multisig_vault)]
    pub dao: Account<'info, Dao>,
    pub squads_multisig_vault: Signer<'info>,
}

impl UpdateDao<'_> {
    pub fn handle(ctx: Context<Self>, dao_params: UpdateDaoParams) -> Result<()> {
        let dao = &mut ctx.accounts.dao;

        macro_rules! update_dao_if_passed {
            ($field:ident) => {
                if let Some(value) = dao_params.$field {
                    dao.$field = value;
                }
            };
        }

        update_dao_if_passed!(pass_threshold_bps);
        update_dao_if_passed!(seconds_per_proposal);
        update_dao_if_passed!(twap_initial_observation);
        update_dao_if_passed!(twap_max_observation_change_per_update);
        update_dao_if_passed!(min_quote_futarchic_liquidity);
        update_dao_if_passed!(min_base_futarchic_liquidity);
        update_dao_if_passed!(base_to_stake);

        dao.seq_num += 1;

        dao.invariant()?;

        let clock = Clock::get()?;
        emit_cpi!(UpdateDaoEvent {
            common: CommonFields::new(&clock, dao.seq_num),
            dao: dao.key(),
            pass_threshold_bps: dao.pass_threshold_bps,
            seconds_per_proposal: dao.seconds_per_proposal,
            twap_initial_observation: dao.twap_initial_observation,
            twap_max_observation_change_per_update: dao.twap_max_observation_change_per_update,
            min_quote_futarchic_liquidity: dao.min_quote_futarchic_liquidity,
            min_base_futarchic_liquidity: dao.min_base_futarchic_liquidity,
            base_to_stake: dao.base_to_stake,
        });

        Ok(())
    }
}
use super::*;

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone)]
pub struct ConditionalSwapParams {
    pub market: Market,
    pub swap_type: SwapType,
    pub input_amount: u64,
    pub min_output_amount: u64,
}

#[derive(Accounts)]
#[event_cpi]
pub struct ConditionalSwap<'info> {
    #[account(mut)]
    pub dao: Box<Account<'info, Dao>>,
    #[account(mut, associated_token::mint = dao.base_mint, associated_token::authority = dao)]
    pub amm_base_vault: Box<Account<'info, TokenAccount>>,
    #[account(mut, associated_token::mint = dao.quote_mint, associated_token::authority = dao)]
    pub amm_quote_vault: Box<Account<'info, TokenAccount>>,

    #[account(
        has_one = dao, has_one = base_vault, has_one = quote_vault,
        has_one = pass_base_mint, has_one = pass_quote_mint,
        has_one = fail_base_mint, has_one = fail_quote_mint,
        has_one = question
    )]
    pub proposal: Box<Account<'info, Proposal>>,

    // These are checked in `validate`
    #[account(mut, associated_token::mint = proposal.pass_base_mint, associated_token::authority = dao)]
    pub amm_pass_base_vault: Box<Account<'info, TokenAccount>>,
    #[account(mut, associated_token::mint = proposal.pass_quote_mint, associated_token::authority = dao)]
    pub amm_pass_quote_vault: Box<Account<'info, TokenAccount>>,
    #[account(mut, associated_token::mint = proposal.fail_base_mint, associated_token::authority = dao)]
    pub amm_fail_base_vault: Box<Account<'info, TokenAccount>>,
    #[account(mut, associated_token::mint = proposal.fail_quote_mint, associated_token::authority = dao)]
    pub amm_fail_quote_vault: Box<Account<'info, TokenAccount>>,

    pub trader: Signer<'info>,
    #[account(mut, token::authority = trader)]
    pub user_input_account: Account<'info, TokenAccount>,
    #[account(mut)]
    pub user_output_account: Account<'info, TokenAccount>,

    #[account(mut)]
    pub base_vault: Box<Account<'info, ConditionalVault>>,
    #[account(mut, address = base_vault.underlying_token_account)]
    pub base_vault_underlying_token_account: Box<Account<'info, TokenAccount>>,

    #[account(mut)]
    pub quote_vault: Box<Account<'info, ConditionalVault>>,
    #[account(mut, address = quote_vault.underlying_token_account)]
    pub quote_vault_underlying_token_account: Box<Account<'info, TokenAccount>>,

    #[account(mut)]
    pub pass_base_mint: Box<Account<'info, Mint>>,
    #[account(mut)]
    pub fail_base_mint: Box<Account<'info, Mint>>,
    #[account(mut)]
    pub pass_quote_mint: Box<Account<'info, Mint>>,
    #[account(mut)]
    pub fail_quote_mint: Box<Account<'info, Mint>>,

    pub conditional_vault_program: Program<'info, ConditionalVaultProgram>,
    /// CHECK: checked by conditional vault program
    pub vault_event_authority: UncheckedAccount<'info>,

    pub question: Box<Account<'info, Question>>,

    pub token_program: Program<'info, Token>,
}

impl ConditionalSwap<'_> {
    pub fn validate(&self, params: &ConditionalSwapParams) -> Result<()> {
        require_neq!(params.market, Market::Spot);

        require_gte!(
            self.user_input_account.amount,
            params.input_amount,
            FutarchyError::InsufficientBalance
        );

        require_eq!(
            self.proposal.state,
            ProposalState::Pending,
            FutarchyError::ProposalNotActive
        );

        require_eq!(self.dao.proposal_count, self.proposal.number);

        Ok(())
    }

    pub fn handle(ctx: Context<Self>, params: ConditionalSwapParams) -> Result<()> {
        let Self {
            dao,
            amm_base_vault,
            amm_quote_vault,
            proposal,
            amm_pass_base_vault,
            amm_pass_quote_vault,
            amm_fail_base_vault,
            amm_fail_quote_vault,
            trader,
            user_input_account,
            user_output_account,
            base_vault,
            base_vault_underlying_token_account,
            quote_vault,
            quote_vault_underlying_token_account,
            pass_base_mint,
            fail_base_mint,
            pass_quote_mint,
            fail_quote_mint,
            conditional_vault_program,
            vault_event_authority,
            question,
            token_program,
            event_authority: _,
            program: _,
        } = ctx.accounts;

        let ConditionalSwapParams {
            market,
            swap_type,
            input_amount,
            min_output_amount,
        } = params;

        let output_amount = dao.amm.state.swap(input_amount, swap_type, market)?;

        require_gte!(
            output_amount,
            min_output_amount,
            FutarchyError::SwapSlippageExceeded
        );

        // You need to transfer in before you can do merges of in
        // You need to do split of out before you can do transfers of out

        let amm_input_account = match (swap_type, market) {
            (SwapType::Buy, Market::Pass) => &amm_pass_quote_vault,
            (SwapType::Sell, Market::Pass) => &amm_pass_base_vault,
            (SwapType::Buy, Market::Fail) => &amm_fail_quote_vault,
            (SwapType::Sell, Market::Fail) => &amm_fail_base_vault,
            (_, Market::Spot) => unreachable!(),
        };

        token::transfer(
            CpiContext::new(
                token_program.to_account_info(),
                token::Transfer {
                    from: user_input_account.to_account_info(),
                    to: amm_input_account.to_account_info(),
                    authority: trader.to_account_info(),
                },
            ),
            input_amount,
        )?;

        // We reload these to ensure that `quote_mergeable` and `base_mergeable` are accurate
        amm_pass_base_vault.reload()?;
        amm_pass_quote_vault.reload()?;
        amm_fail_base_vault.reload()?;
        amm_fail_quote_vault.reload()?;

        let dao_creator = dao.dao_creator;
        let nonce = dao.nonce.to_le_bytes();
        let signer_seeds = &[
            b"dao".as_ref(),
            dao_creator.as_ref(),
            nonce.as_ref(),
            &[dao.pda_bump],
        ];
        let signer = &[&signer_seeds[..]];

        let quote_cpi_context = CpiContext::new_with_signer(
            conditional_vault_program.to_account_info(),
            conditional_vault::cpi::accounts::InteractWithVault {
                question: question.to_account_info(),
                vault: quote_vault.to_account_info(),
                vault_underlying_token_account: quote_vault_underlying_token_account
                    .to_account_info(),
                authority: dao.to_account_info(),
                user_underlying_token_account: amm_quote_vault.to_account_info(),
                event_authority: vault_event_authority.to_account_info(),
                program: conditional_vault_program.to_account_info(),
                token_program: token_program.to_account_info(),
            },
            signer,
        )
        .with_remaining_accounts(vec![
            fail_quote_mint.to_account_info(),
            pass_quote_mint.to_account_info(),
            amm_fail_quote_vault.to_account_info(),
            amm_pass_quote_vault.to_account_info(),
        ]);

        let amm_output_account = match (swap_type, market) {
            (SwapType::Buy, Market::Pass) => &amm_pass_base_vault,
            (SwapType::Sell, Market::Pass) => &amm_pass_quote_vault,
            (SwapType::Buy, Market::Fail) => &amm_fail_base_vault,
            (SwapType::Sell, Market::Fail) => &amm_fail_quote_vault,
            (_, Market::Spot) => unreachable!(),
        };

        // If the user is buying, we should have just received some quote to merge
        // If they're selling, we might need to split some quote
        match swap_type {
            SwapType::Buy => {
                let quote_mergeable =
                    std::cmp::min(amm_fail_quote_vault.amount, amm_pass_quote_vault.amount);

                if quote_mergeable > 0 {
                    conditional_vault::cpi::merge_tokens(quote_cpi_context, quote_mergeable)?
                }
            }
            SwapType::Sell => {
                let amount_to_split = output_amount.saturating_sub(amm_output_account.amount);

                if amount_to_split > 0 {
                    conditional_vault::cpi::split_tokens(quote_cpi_context, amount_to_split)?
                }
            }
        }

        let base_cpi_context = CpiContext::new_with_signer(
            conditional_vault_program.to_account_info(),
            conditional_vault::cpi::accounts::InteractWithVault {
                question: question.to_account_info(),
                vault: base_vault.to_account_info(),
                vault_underlying_token_account: base_vault_underlying_token_account
                    .to_account_info(),
                authority: dao.to_account_info(),
                user_underlying_token_account: amm_base_vault.to_account_info(),
                event_authority: vault_event_authority.to_account_info(),
                program: conditional_vault_program.to_account_info(),
                token_program: token_program.to_account_info(),
            },
            signer,
        )
        .with_remaining_accounts(vec![
            fail_base_mint.to_account_info(),
            pass_base_mint.to_account_info(),
            amm_fail_base_vault.to_account_info(),
            amm_pass_base_vault.to_account_info(),
        ]);

        match swap_type {
            SwapType::Buy => {
                let amount_to_split = output_amount.saturating_sub(amm_output_account.amount);

                if amount_to_split > 0 {
                    conditional_vault::cpi::split_tokens(base_cpi_context, amount_to_split)?
                }
            }
            SwapType::Sell => {
                let base_mergeable =
                    std::cmp::min(amm_fail_base_vault.amount, amm_pass_base_vault.amount);

                if base_mergeable > 0 {
                    conditional_vault::cpi::merge_tokens(base_cpi_context, base_mergeable)?
                }
            }
        }

        token::transfer(
            CpiContext::new_with_signer(
                token_program.to_account_info(),
                token::Transfer {
                    from: amm_output_account.to_account_info(),
                    to: user_output_account.to_account_info(),
                    authority: dao.to_account_info(),
                },
                signer,
            ),
            output_amount,
        )?;

        let clock = Clock::get()?;

        dao.seq_num += 1;

        emit_cpi!(ConditionalSwapEvent {
            common: CommonFields::new(&clock, dao.seq_num),
            dao: dao.key(),
            proposal: proposal.key(),
            trader: trader.key(),
            market,
            swap_type,
            input_amount,
            output_amount,
            min_output_amount,
            post_amm_state: dao.amm.clone(),
        });

        Ok(())
    }
}
use super::*;

pub mod admin {
    use anchor_lang::prelude::declare_id;

    // MetaDAO multisig
    declare_id!("6awyHMshBGVjJ3ozdSJdyyDE1CTAXUwrpNMaRGMsb4sf");
}

#[derive(Accounts)]
#[event_cpi]
pub struct CollectFees<'info> {
    #[account(mut)]
    pub dao: Account<'info, Dao>,
    pub admin: Signer<'info>,
    #[account(mut, token::mint = dao.base_mint)]
    pub base_token_account: Account<'info, TokenAccount>,
    #[account(mut, token::mint = dao.quote_mint)]
    pub quote_token_account: Account<'info, TokenAccount>,
    #[account(mut, associated_token::mint = dao.base_mint, associated_token::authority = dao)]
    pub amm_base_vault: Account<'info, TokenAccount>,
    #[account(mut, associated_token::mint = dao.quote_mint, associated_token::authority = dao)]
    pub amm_quote_vault: Account<'info, TokenAccount>,
    pub token_program: Program<'info, Token>,
}

impl CollectFees<'_> {
    pub fn validate(&self) -> Result<()> {
        #[cfg(feature = "production")]
        require_keys_eq!(self.admin.key(), admin::ID, FutarchyError::InvalidAdmin);

        Ok(())
    }

    pub fn handle(ctx: Context<Self>) -> Result<()> {
        let Self {
            dao,
            admin: _,
            base_token_account,
            quote_token_account,
            amm_base_vault,
            amm_quote_vault,
            token_program,
            event_authority: _,
            program: _,
        } = ctx.accounts;

        let PoolState::Spot { ref mut spot } = dao.amm.state else {
            return err!(FutarchyError::PoolNotInSpotState);
        };

        let base_fee_balance = spot.base_protocol_fee_balance;
        let quote_fee_balance = spot.quote_protocol_fee_balance;

        spot.base_protocol_fee_balance = 0;
        spot.quote_protocol_fee_balance = 0;

        let dao_creator = dao.dao_creator;
        let nonce = dao.nonce.to_le_bytes();
        let signer_seeds = &[
            b"dao".as_ref(),
            dao_creator.as_ref(),
            nonce.as_ref(),
            &[dao.pda_bump],
        ];

        for (amount_to_send, from, to) in [
            (base_fee_balance, &amm_base_vault, &base_token_account),
            (quote_fee_balance, &amm_quote_vault, &quote_token_account),
        ] {
            token::transfer(
                CpiContext::new_with_signer(
                    token_program.to_account_info(),
                    Transfer {
                        from: from.to_account_info(),
                        to: to.to_account_info(),
                        authority: dao.to_account_info(),
                    },
                    &[&signer_seeds[..]],
                ),
                amount_to_send,
            )?;
        }

        let clock = Clock::get()?;

        dao.seq_num += 1;

        emit_cpi!(CollectFeesEvent {
            common: CommonFields::new(&clock, dao.seq_num),
            dao: dao.key(),
            base_token_account: base_token_account.key(),
            quote_token_account: quote_token_account.key(),
            amm_base_vault: amm_base_vault.key(),
            amm_quote_vault: amm_quote_vault.key(),
            quote_mint: dao.quote_mint,
            base_mint: dao.base_mint,
            quote_fees_collected: quote_fee_balance,
            base_fees_collected: base_fee_balance,
            post_amm_state: dao.amm.clone(),
        });

        Ok(())
    }
}
use super::*;

use conditional_vault::{cpi::accounts::ResolveQuestion, ResolveQuestionArgs};
use squads_multisig_program::program::SquadsMultisigProgram;

#[derive(Accounts)]
#[event_cpi]
pub struct FinalizeProposal<'info> {
    #[account(
        mut, has_one = question, has_one = dao, has_one = squads_proposal,
        has_one = base_vault, has_one = quote_vault,
        has_one = pass_base_mint, has_one = pass_quote_mint,
        has_one = fail_base_mint, has_one = fail_quote_mint
    )]
    pub proposal: Box<Account<'info, Proposal>>,
    #[account(mut, has_one = squads_multisig)]
    pub dao: Box<Account<'info, Dao>>,
    #[account(mut)]
    pub question: Box<Account<'info, Question>>,
    /// CHECK: checked by squads multisig program
    #[account(mut)]
    pub squads_proposal: UncheckedAccount<'info>,
    /// CHECK: checked by squads multisig program
    pub squads_multisig: UncheckedAccount<'info>,
    pub squads_multisig_program: Program<'info, SquadsMultisigProgram>,

    #[account(mut, associated_token::mint = proposal.pass_base_mint, associated_token::authority = dao)]
    pub amm_pass_base_vault: Box<Account<'info, TokenAccount>>,
    #[account(mut, associated_token::mint = proposal.pass_quote_mint, associated_token::authority = dao)]
    pub amm_pass_quote_vault: Box<Account<'info, TokenAccount>>,
    #[account(mut, associated_token::mint = proposal.fail_base_mint, associated_token::authority = dao)]
    pub amm_fail_base_vault: Box<Account<'info, TokenAccount>>,
    #[account(mut, associated_token::mint = proposal.fail_quote_mint, associated_token::authority = dao)]
    pub amm_fail_quote_vault: Box<Account<'info, TokenAccount>>,

    #[account(mut, associated_token::mint = dao.base_mint, associated_token::authority = dao)]
    pub amm_base_vault: Account<'info, TokenAccount>,
    #[account(mut, associated_token::mint = dao.quote_mint, associated_token::authority = dao)]
    pub amm_quote_vault: Account<'info, TokenAccount>,

    pub vault_program: Program<'info, ConditionalVaultProgram>,
    /// CHECK: checked by vault program
    pub vault_event_authority: UncheckedAccount<'info>,
    pub token_program: Program<'info, Token>,
    #[account(mut)]
    pub quote_vault: Box<Account<'info, ConditionalVault>>,
    #[account(mut, address = quote_vault.underlying_token_account)]
    pub quote_vault_underlying_token_account: Box<Account<'info, TokenAccount>>,
    #[account(mut)]
    pub pass_quote_mint: Box<Account<'info, Mint>>,
    #[account(mut)]
    pub fail_quote_mint: Box<Account<'info, Mint>>,
    #[account(mut)]
    pub pass_base_mint: Box<Account<'info, Mint>>,
    #[account(mut)]
    pub fail_base_mint: Box<Account<'info, Mint>>,
    #[account(mut)]
    pub base_vault: Box<Account<'info, ConditionalVault>>,
    #[account(mut, address = base_vault.underlying_token_account)]
    pub base_vault_underlying_token_account: Box<Account<'info, TokenAccount>>,
}

impl FinalizeProposal<'_> {
    pub fn validate(&self) -> Result<()> {
        let clock = Clock::get()?;

        require_gte!(
            clock.unix_timestamp,
            self.proposal.timestamp_enqueued + self.proposal.duration_in_seconds as i64,
            FutarchyError::ProposalTooYoung
        );

        require!(
            self.proposal.state == ProposalState::Pending,
            FutarchyError::ProposalAlreadyFinalized
        );

        Ok(())
    }

    pub fn handle(ctx: Context<Self>) -> Result<()> {
        let Self {
            proposal,
            dao,
            question,
            squads_proposal,
            squads_multisig,
            squads_multisig_program,
            vault_program,
            quote_vault,
            token_program,
            event_authority: _,
            vault_event_authority,
            program: _,
            quote_vault_underlying_token_account,
            pass_quote_mint,
            fail_quote_mint,
            amm_pass_quote_vault,
            amm_fail_quote_vault,
            pass_base_mint,
            fail_base_mint,
            amm_quote_vault,
            amm_pass_base_vault,
            amm_fail_base_vault,
            amm_base_vault,
            base_vault,
            base_vault_underlying_token_account,
        } = ctx.accounts;

        let squads_proposal_key = squads_proposal.key();
        let proposal_seeds = &[
            b"proposal",
            squads_proposal_key.as_ref(),
            &[proposal.pda_bump],
        ];
        let proposal_signer = &[&proposal_seeds[..]];

        let calculate_twap = |amm: &Pool| -> Result<u128> {
            let seconds_passed = amm.oracle.last_updated_timestamp - proposal.timestamp_enqueued;

            require_gte!(
                seconds_passed,
                proposal.duration_in_seconds as i64,
                FutarchyError::MarketsTooYoung
            );

            amm.get_twap()
        };

        let PoolState::Futarchy {
            pass,
            fail,
            mut spot,
        } = dao.amm.state.to_owned()
        else {
            unreachable!();
        };

        let pass_market_twap = calculate_twap(&pass)?;
        let fail_market_twap = calculate_twap(&fail)?;

        // this can't overflow because each twap can only be MAX_PRICE (~1e31),
        // MAX_BPS + pass_threshold_bps is at most 1e5, and a u128 can hold
        // 1e38. still, saturate
        let threshold = fail_market_twap
            .saturating_mul(MAX_BPS.saturating_add(dao.pass_threshold_bps).into())
            / MAX_BPS as u128;

        let (new_proposal_state, payout_numerators) = if pass_market_twap > threshold {
            (ProposalState::Passed, vec![0, 1])
        } else {
            (ProposalState::Failed, vec![1, 0])
        };

        proposal.state = new_proposal_state;

        let cpi_accounts = ResolveQuestion {
            question: question.to_account_info(),
            oracle: proposal.to_account_info(),
            event_authority: vault_event_authority.to_account_info(),
            program: vault_program.to_account_info(),
        };
        let cpi_ctx = CpiContext::new(vault_program.to_account_info(), cpi_accounts)
            .with_signer(proposal_signer);
        conditional_vault::cpi::resolve_question(
            cpi_ctx,
            ResolveQuestionArgs { payout_numerators },
        )?;

        let dao_nonce = &dao.nonce.to_le_bytes();
        let dao_creator_key = &dao.dao_creator.as_ref();
        let dao_seeds = &[b"dao".as_ref(), dao_creator_key, dao_nonce, &[dao.pda_bump]];
        let dao_signer = &[&dao_seeds[..]];

        if new_proposal_state == ProposalState::Passed {
            squads_multisig_program::cpi::proposal_approve(
                CpiContext::new_with_signer(
                    squads_multisig_program.to_account_info(),
                    squads_multisig_program::cpi::accounts::ProposalVote {
                        proposal: squads_proposal.to_account_info(),
                        multisig: squads_multisig.to_account_info(),
                        member: dao.to_account_info(),
                    },
                    dao_signer,
                ),
                squads_multisig_program::ProposalVoteArgs { memo: None },
            )?;

            spot.base_reserves += pass.base_reserves;
            spot.quote_reserves += pass.quote_reserves;
            spot.base_protocol_fee_balance += pass.base_protocol_fee_balance;
            spot.quote_protocol_fee_balance += pass.quote_protocol_fee_balance;
        } else {
            spot.base_reserves += fail.base_reserves;
            spot.quote_reserves += fail.quote_reserves;
            spot.base_protocol_fee_balance += fail.base_protocol_fee_balance;
            spot.quote_protocol_fee_balance += fail.quote_protocol_fee_balance;
        }

        let quote_cpi_context = CpiContext::new_with_signer(
            vault_program.to_account_info(),
            conditional_vault::cpi::accounts::InteractWithVault {
                question: question.to_account_info(),
                vault: quote_vault.to_account_info(),
                vault_underlying_token_account: quote_vault_underlying_token_account
                    .to_account_info(),
                authority: dao.to_account_info(),
                user_underlying_token_account: amm_quote_vault.to_account_info(),
                event_authority: vault_event_authority.to_account_info(),
                program: vault_program.to_account_info(),
                token_program: token_program.to_account_info(),
            },
            dao_signer,
        )
        .with_remaining_accounts(vec![
            fail_quote_mint.to_account_info(),
            pass_quote_mint.to_account_info(),
            amm_fail_quote_vault.to_account_info(),
            amm_pass_quote_vault.to_account_info(),
        ]);

        conditional_vault::cpi::redeem_tokens(quote_cpi_context)?;

        let base_cpi_context = CpiContext::new_with_signer(
            vault_program.to_account_info(),
            conditional_vault::cpi::accounts::InteractWithVault {
                question: question.to_account_info(),
                vault: base_vault.to_account_info(),
                vault_underlying_token_account: base_vault_underlying_token_account
                    .to_account_info(),
                authority: dao.to_account_info(),
                user_underlying_token_account: amm_base_vault.to_account_info(),
                event_authority: vault_event_authority.to_account_info(),
                program: vault_program.to_account_info(),
                token_program: token_program.to_account_info(),
            },
            dao_signer,
        )
        .with_remaining_accounts(vec![
            fail_base_mint.to_account_info(),
            pass_base_mint.to_account_info(),
            amm_fail_base_vault.to_account_info(),
            amm_pass_base_vault.to_account_info(),
        ]);

        conditional_vault::cpi::redeem_tokens(base_cpi_context)?;

        dao.amm.state = PoolState::Spot { spot };

        dao.seq_num += 1;

        let clock = Clock::get()?;

        emit_cpi!(FinalizeProposalEvent {
            common: CommonFields::new(&clock, dao.seq_num),
            proposal: proposal.key(),
            dao: dao.key(),
            pass_market_twap,
            fail_market_twap,
            threshold,
            state: new_proposal_state,
            squads_proposal: squads_proposal.key(),
            squads_multisig: dao.squads_multisig,
            post_amm_state: dao.amm.clone(),
        });

        Ok(())
    }
}
use super::*;

pub mod collect_fees;
pub mod conditional_swap;
pub mod execute_spending_limit_change;
pub mod finalize_proposal;
pub mod initialize_dao;
pub mod initialize_proposal;
pub mod launch_proposal;
pub mod provide_liquidity;
pub mod spot_swap;
pub mod stake_to_proposal;
pub mod unstake_from_proposal;
pub mod update_dao;
pub mod withdraw_liquidity;

pub use collect_fees::*;
pub use conditional_swap::*;
pub use execute_spending_limit_change::*;
pub use finalize_proposal::*;
pub use initialize_dao::*;
pub use initialize_proposal::*;
pub use launch_proposal::*;
pub use provide_liquidity::*;
pub use spot_swap::*;
pub use stake_to_proposal::*;
pub use unstake_from_proposal::*;
pub use update_dao::*;
pub use withdraw_liquidity::*;
use super::*;

use anchor_lang::Discriminator;
use squads_multisig_program::program::SquadsMultisigProgram;

#[derive(Accounts)]
#[event_cpi]
pub struct ExecuteSpendingLimitChange<'info> {
    #[account(
        mut, has_one = dao, has_one = squads_proposal,
    )]
    pub proposal: Box<Account<'info, Proposal>>,
    #[account(mut, has_one = squads_multisig)]
    pub dao: Box<Account<'info, Dao>>,
    /// CHECK: checked by squads multisig program
    #[account(mut)]
    pub squads_proposal: Account<'info, squads_multisig_program::Proposal>,
    #[account(address = vault_transaction.multisig)]
    pub squads_multisig: Account<'info, squads_multisig_program::Multisig>,
    pub squads_multisig_program: Program<'info, SquadsMultisigProgram>,
    pub vault_transaction: Account<'info, squads_multisig_program::VaultTransaction>,
}

impl<'info, 'c: 'info> ExecuteSpendingLimitChange<'info> {
    pub fn validate(&self) -> Result<()> {
        require_eq!(self.proposal.state, ProposalState::Passed);

        Ok(())
    }

    pub fn handle(ctx: Context<'_, '_, 'c, 'info, Self>) -> Result<()> {
        let Self {
            proposal: _,
            dao,
            squads_proposal,
            squads_multisig,
            squads_multisig_program,
            vault_transaction,
            event_authority: _,
            program: _,
        } = ctx.accounts;

        let message = &vault_transaction.message;

        // it would be bad if we signed with the Dao and then they ran off and did something else
        // with it. so we verify that the only instructions are calls to update spending limits on
        // the squads program
        let squads_program_key_index: u8 = message
            .account_keys
            .iter()
            .position(|key| key == &squads_multisig_program.key())
            .ok_or(error!(FutarchyError::InvalidTransaction))?
            .try_into()
            .or_else(|_| Err(error!(FutarchyError::InvalidTransaction)))?;

        for instruction in message.instructions.iter() {
            require_eq!(
                instruction.program_id_index,
                squads_program_key_index,
                FutarchyError::InvalidTransaction
            );

            let discriminator: [u8; 8] = instruction.data[0..8].try_into().unwrap();
            if discriminator != squads_multisig_program::instruction::MultisigAddSpendingLimit::DISCRIMINATOR &&
                discriminator != squads_multisig_program::instruction::MultisigRemoveSpendingLimit::DISCRIMINATOR {
                return Err(error!(FutarchyError::InvalidTransaction));
            }
        }

        let dao_nonce = &dao.nonce.to_le_bytes();
        let dao_creator_key = &dao.dao_creator.as_ref();
        let dao_seeds = &[b"dao".as_ref(), dao_creator_key, dao_nonce, &[dao.pda_bump]];
        let dao_signer = &[&dao_seeds[..]];

        squads_multisig_program::cpi::vault_transaction_execute(
            CpiContext::new_with_signer(
                squads_multisig_program.to_account_info(),
                squads_multisig_program::cpi::accounts::VaultTransactionExecute {
                    multisig: squads_multisig.to_account_info(),
                    proposal: squads_proposal.to_account_info(),
                    transaction: vault_transaction.to_account_info(),
                    member: dao.to_account_info(),
                },
                dao_signer,
            )
            .with_remaining_accounts((&ctx.remaining_accounts).to_vec()),
        )?;

        Ok(())
    }
}
use super::*;

#[derive(Debug, Clone, AnchorSerialize, AnchorDeserialize)]
pub struct UnstakeFromProposalParams {
    pub amount: u64,
}

#[derive(Accounts)]
#[instruction(args: UnstakeFromProposalParams)]
#[event_cpi]
pub struct UnstakeFromProposal<'info> {
    #[account(mut)]
    pub proposal: Box<Account<'info, Proposal>>,
    #[account(mut)]
    pub dao: Box<Account<'info, Dao>>,
    #[account(
        mut,
        associated_token::mint = dao.base_mint,
        associated_token::authority = staker,
    )]
    pub staker_base_account: Box<Account<'info, TokenAccount>>,
    #[account(
        mut,
        associated_token::mint = dao.base_mint,
        associated_token::authority = proposal,
    )]
    pub proposal_base_account: Box<Account<'info, TokenAccount>>,
    #[account(
        mut,
        seeds = [b"stake", proposal.key().as_ref(), staker.key().as_ref()],
        bump = stake_account.bump,
    )]
    pub stake_account: Box<Account<'info, StakeAccount>>,
    pub staker: Signer<'info>,
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
}

impl UnstakeFromProposal<'_> {
    pub fn validate(&self, params: &UnstakeFromProposalParams) -> Result<()> {
        require_keys_eq!(self.proposal.dao, self.dao.key());

        require_gt!(params.amount, 0, FutarchyError::InvalidAmount);

        // Check if staker has enough staked
        require_gte!(
            self.stake_account.amount,
            params.amount,
            FutarchyError::InsufficientTokenBalance
        );

        Ok(())
    }

    pub fn handle(ctx: Context<Self>, params: UnstakeFromProposalParams) -> Result<()> {
        let Self {
            proposal,
            dao,
            staker_base_account,
            proposal_base_account,
            stake_account,
            staker,
            token_program,
            associated_token_program: _,
            event_authority: _,
            program: _,
        } = ctx.accounts;

        let UnstakeFromProposalParams { amount } = params;

        // Transfer tokens from proposal back to staker
        let seeds = &[
            b"proposal",
            proposal.squads_proposal.as_ref(),
            &[proposal.pda_bump],
        ];
        let signer_seeds = &[&seeds[..]];

        let transfer_ctx = CpiContext::new_with_signer(
            token_program.to_account_info(),
            Transfer {
                from: proposal_base_account.to_account_info(),
                to: staker_base_account.to_account_info(),
                authority: proposal.to_account_info(),
            },
            signer_seeds,
        );
        token::transfer(transfer_ctx, amount)?;

        // Update proposal state if in draft
        if let ProposalState::Draft { mut amount_staked } = proposal.state {
            amount_staked = amount_staked.saturating_sub(amount);
            proposal.state = ProposalState::Draft { amount_staked };
        }

        // Update stake account
        stake_account.amount = stake_account.amount.saturating_sub(amount);

        dao.seq_num += 1;

        let clock = Clock::get()?;

        emit_cpi!(UnstakeFromProposalEvent {
            common: CommonFields::new(&clock, dao.seq_num),
            proposal: proposal.key(),
            staker: staker.key(),
            amount,
            total_staked: match proposal.state {
                ProposalState::Draft { amount_staked } => amount_staked,
                _ => 0, // Not in draft state, so no stake
            },
        });

        Ok(())
    }
}
use super::*;

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone)]
pub struct ProvideLiquidityParams {
    /// How much quote token you will deposit to the pool
    pub quote_amount: u64,
    /// The maximum base token you will deposit to the pool
    pub max_base_amount: u64,
    /// The minimum liquidity you will be assigned
    pub min_liquidity: u128,
    /// The account that will own the LP position, usually the same as the
    /// liquidity provider
    pub position_authority: Pubkey,
}

#[derive(Accounts)]
#[instruction(params: ProvideLiquidityParams)]
#[event_cpi]
pub struct ProvideLiquidity<'info> {
    #[account(mut)]
    pub dao: Box<Account<'info, Dao>>,
    pub liquidity_provider: Signer<'info>,
    #[account(
        mut,
        token::mint = dao.base_mint,
        token::authority = liquidity_provider,
    )]
    pub liquidity_provider_base_account: Account<'info, TokenAccount>,
    #[account(
        mut,
        token::mint = dao.quote_mint,
        token::authority = liquidity_provider,
    )]
    pub liquidity_provider_quote_account: Account<'info, TokenAccount>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
    #[account(
        mut,
        associated_token::mint = dao.base_mint,
        associated_token::authority = dao,
    )]
    pub amm_base_vault: Account<'info, TokenAccount>,
    #[account(
        mut,
        associated_token::mint = dao.quote_mint,
        associated_token::authority = dao,
    )]
    pub amm_quote_vault: Account<'info, TokenAccount>,
    #[account(
        init_if_needed,
        payer = payer,
        seeds = [b"amm_position", dao.key().as_ref(), params.position_authority.key().as_ref()],
        bump,
        space = 8 + AmmPosition::INIT_SPACE,
    )]
    pub amm_position: Account<'info, AmmPosition>,
    pub token_program: Program<'info, Token>,
}

impl ProvideLiquidity<'_> {
    pub fn handle(ctx: Context<Self>, params: ProvideLiquidityParams) -> Result<()> {
        let Self {
            dao,
            liquidity_provider,
            liquidity_provider_base_account,
            liquidity_provider_quote_account,
            payer: _,
            system_program: _,
            amm_base_vault,
            amm_quote_vault,
            amm_position,
            token_program,
            event_authority: _,
            program: _,
        } = ctx.accounts;

        let ProvideLiquidityParams {
            quote_amount,
            max_base_amount,
            min_liquidity,
            position_authority: _,
        } = params;

        let total_liquidity = dao.amm.total_liquidity;
        let PoolState::Spot { ref mut spot } = dao.amm.state else {
            // TODO: check that pool is already in right state
            unreachable!();
        };

        let (liquidity_to_mint, base_amount) = if total_liquidity > 0 {
            // require!(min_lp_tokens > 0, AmmError::ZeroMinLpTokens);
            require_gt!(min_liquidity, 0);

            let quote_reserves = spot.quote_reserves as u128;
            let base_reserves = spot.base_reserves as u128;

            // this should only panic in an extreme scenario: when (quote_amount * base_reserve) / quote_reserve > u64::MAX
            let base_amount: u64 = (((quote_amount as u128 * base_reserves) / quote_reserves) + 1)
                .try_into()
                .map_err(|_| FutarchyError::CastingOverflow)?;

            let liquidity_to_mint = (quote_amount as u128 * total_liquidity) / quote_reserves;

            require_gte!(
                max_base_amount,
                base_amount,
                // AmmError::AddLiquidityMaxBaseExceeded
            );
            require_gte!(
                liquidity_to_mint,
                min_liquidity,
                // AmmError::AddLiquiditySlippageExceeded
            );

            (liquidity_to_mint, base_amount)
        } else {
            // equivalent to $0.1 if the quote is USDC, here for rounding
            require_gte!(quote_amount, MIN_QUOTE_LIQUIDITY);

            let base_amount = max_base_amount;

            let initial_liquidity = quote_amount as u128 * 1_000_000_000;

            (initial_liquidity, base_amount)
        };

        spot.base_reserves += base_amount;
        spot.quote_reserves += quote_amount;

        amm_position.set_inner(AmmPosition {
            dao: dao.key(),
            position_authority: liquidity_provider.key(),
            liquidity: amm_position.liquidity + liquidity_to_mint,
        });

        dao.amm.total_liquidity += liquidity_to_mint;

        token::transfer(
            CpiContext::new(
                token_program.to_account_info(),
                token::Transfer {
                    from: liquidity_provider_base_account.to_account_info(),
                    to: amm_base_vault.to_account_info(),
                    authority: liquidity_provider.to_account_info(),
                },
            ),
            base_amount,
        )?;

        token::transfer(
            CpiContext::new(
                token_program.to_account_info(),
                token::Transfer {
                    from: liquidity_provider_quote_account.to_account_info(),
                    to: amm_quote_vault.to_account_info(),
                    authority: liquidity_provider.to_account_info(),
                },
            ),
            quote_amount,
        )?;

        dao.seq_num += 1;

        let clock = Clock::get()?;

        emit_cpi!(ProvideLiquidityEvent {
            common: CommonFields::new(&clock, dao.seq_num),
            dao: dao.key(),
            liquidity_provider: liquidity_provider.key(),
            position_authority: params.position_authority,
            quote_amount,
            base_amount,
            liquidity_minted: liquidity_to_mint,
            min_liquidity,
            post_amm_state: dao.amm.clone(),
        });

        Ok(())
    }
}
use super::*;

#[derive(Debug, Clone, AnchorSerialize, AnchorDeserialize)]
pub struct SpotSwapParams {
    pub input_amount: u64,
    pub swap_type: SwapType,
    pub min_output_amount: u64,
}

#[derive(Accounts)]
#[event_cpi]
pub struct SpotSwap<'info> {
    #[account(mut)]
    pub dao: Box<Account<'info, Dao>>,
    #[account(
        mut,
        token::mint = dao.base_mint,
        token::authority = user,
    )]
    pub user_base_account: Box<Account<'info, TokenAccount>>,
    #[account(
        mut,
        token::mint = dao.quote_mint,
        token::authority = user,
    )]
    pub user_quote_account: Box<Account<'info, TokenAccount>>,
    #[account(
        mut,
        associated_token::mint = dao.base_mint,
        associated_token::authority = dao,
    )]
    pub amm_base_vault: Box<Account<'info, TokenAccount>>,
    #[account(
        mut,
        associated_token::mint = dao.quote_mint,
        associated_token::authority = dao,
    )]
    pub amm_quote_vault: Box<Account<'info, TokenAccount>>,
    pub user: Signer<'info>,
    pub token_program: Program<'info, Token>,
}

impl SpotSwap<'_> {
    pub fn handle(ctx: Context<Self>, params: SpotSwapParams) -> Result<()> {
        let SpotSwapParams {
            swap_type,
            input_amount,
            min_output_amount,
        } = params;

        let Self {
            dao,
            user_base_account,
            user_quote_account,
            amm_base_vault,
            amm_quote_vault,
            user,
            token_program,
            event_authority: _,
            program: _,
        } = ctx.accounts;

        let (user_input_account, amm_input_account, user_output_account, amm_output_account) =
            match swap_type {
                SwapType::Buy => (
                    user_quote_account,
                    amm_quote_vault,
                    user_base_account,
                    amm_base_vault,
                ),
                SwapType::Sell => (
                    user_base_account,
                    amm_base_vault,
                    user_quote_account,
                    amm_quote_vault,
                ),
            };

        require_gte!(
            user_input_account.amount,
            input_amount,
            FutarchyError::InsufficientBalance
        );

        let output_amount = dao.amm.state.swap(input_amount, swap_type, Market::Spot)?;

        require_gte!(output_amount, min_output_amount);

        token::transfer(
            CpiContext::new(
                token_program.to_account_info(),
                token::Transfer {
                    from: user_input_account.to_account_info(),
                    to: amm_input_account.to_account_info(),
                    authority: user.to_account_info(),
                },
            ),
            input_amount,
        )?;

        // let dao_key = dao.key();
        // let dao_creator = dao.dao_creator;
        // let nonce = dao.nonce;
        // let signer_seeds = &[b"dao".as_ref(), dao_creator.as_ref(), nonce.to_le_bytes().as_ref(), &[dao.pda_bump]];
        let dao_nonce = &dao.nonce.to_le_bytes();
        let dao_creator_key = &dao.dao_creator.as_ref();
        let dao_seeds = &[b"dao".as_ref(), dao_creator_key, dao_nonce, &[dao.pda_bump]];

        token::transfer(
            CpiContext::new_with_signer(
                token_program.to_account_info(),
                token::Transfer {
                    from: amm_output_account.to_account_info(),
                    to: user_output_account.to_account_info(),
                    authority: dao.to_account_info(),
                },
                &[&dao_seeds[..]],
            ),
            output_amount,
        )?;

        dao.seq_num += 1;

        let clock = Clock::get()?;

        emit_cpi!(SpotSwapEvent {
            common: CommonFields::new(&clock, dao.seq_num),
            dao: dao.key(),
            user: user.key(),
            swap_type,
            input_amount,
            output_amount,
            min_output_amount,
            post_amm_state: dao.amm.clone(),
        });

        Ok(())
    }
}
use super::*;

// TODO: allow users to close their `AmmPosition` account for the 0.0015 SOL

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone)]
pub struct WithdrawLiquidityParams {
    /// How much liquidity to withdraw
    pub liquidity_to_withdraw: u128,
    /// Minimum base tokens to receive
    pub min_base_amount: u64,
    /// Minimum quote tokens to receive
    pub min_quote_amount: u64,
}

#[derive(Accounts)]
#[event_cpi]
pub struct WithdrawLiquidity<'info> {
    #[account(mut)]
    pub dao: Account<'info, Dao>,
    pub position_authority: Signer<'info>,
    #[account(
        mut,
        token::mint = dao.base_mint,
        token::authority = position_authority,
    )]
    pub liquidity_provider_base_account: Account<'info, TokenAccount>,
    #[account(
        mut,
        token::mint = dao.quote_mint,
        token::authority = position_authority,
    )]
    pub liquidity_provider_quote_account: Account<'info, TokenAccount>,
    #[account(
        mut,
        associated_token::mint = dao.base_mint,
        associated_token::authority = dao,
    )]
    pub amm_base_vault: Account<'info, TokenAccount>,
    #[account(
        mut,
        associated_token::mint = dao.quote_mint,
        associated_token::authority = dao,
    )]
    pub amm_quote_vault: Account<'info, TokenAccount>,
    #[account(
        mut,
        seeds = [b"amm_position", dao.key().as_ref(), position_authority.key().as_ref()],
        bump,
        has_one = dao,
        has_one = position_authority,
    )]
    pub amm_position: Account<'info, AmmPosition>,
    pub token_program: Program<'info, Token>,
}

impl WithdrawLiquidity<'_> {
    pub fn handle(ctx: Context<Self>, params: WithdrawLiquidityParams) -> Result<()> {
        let WithdrawLiquidityParams {
            liquidity_to_withdraw,
            min_base_amount,
            min_quote_amount,
        } = params;

        let Self {
            dao,
            position_authority: liquidity_provider,
            liquidity_provider_base_account,
            liquidity_provider_quote_account,
            amm_base_vault,
            amm_quote_vault,
            amm_position,
            token_program,
            event_authority: _,
            program: _,
        } = ctx.accounts;

        // Get the key before any borrows
        let liquidity_provider_key = liquidity_provider.key();

        require_gte!(
            amm_position.liquidity,
            liquidity_to_withdraw,
            FutarchyError::InsufficientBalance
        );

        require!(
            liquidity_to_withdraw > 0,
            FutarchyError::ZeroLiquidityRemove
        );

        let total_liquidity = dao.amm.total_liquidity;
        require_gt!(total_liquidity, 0, FutarchyError::AssertFailed);

        let (base_to_withdraw, quote_to_withdraw) = {
            let PoolState::Spot { ref spot } = dao.amm.state else {
                // TODO: check that pool is already in right state
                unreachable!();
            };
            spot.get_base_and_quote_withdrawable(
                liquidity_to_withdraw as u64,
                total_liquidity as u64,
            )
        };

        require_gte!(
            base_to_withdraw,
            min_base_amount,
            FutarchyError::SwapSlippageExceeded
        );
        require_gte!(
            quote_to_withdraw,
            min_quote_amount,
            FutarchyError::SwapSlippageExceeded
        );

        // Update the AMM position
        amm_position.liquidity -= liquidity_to_withdraw;

        // Update the futarchy AMM
        dao.amm.total_liquidity -= liquidity_to_withdraw;
        {
            let PoolState::Spot { ref mut spot } = dao.amm.state else {
                unreachable!();
            };
            spot.base_reserves -= base_to_withdraw;
            spot.quote_reserves -= quote_to_withdraw;
        }

        let dao_creator = dao.dao_creator;
        let nonce = dao.nonce.to_le_bytes();
        let signer_seeds = &[
            b"dao".as_ref(),
            dao_creator.as_ref(),
            nonce.as_ref(),
            &[dao.pda_bump],
        ];

        for (amount_to_withdraw, from, to) in [
            (
                base_to_withdraw,
                amm_base_vault,
                liquidity_provider_base_account,
            ),
            (
                quote_to_withdraw,
                amm_quote_vault,
                liquidity_provider_quote_account,
            ),
        ] {
            token::transfer(
                CpiContext::new_with_signer(
                    token_program.to_account_info(),
                    Transfer {
                        from: from.to_account_info(),
                        to: to.to_account_info(),
                        authority: dao.to_account_info(),
                    },
                    &[&signer_seeds[..]],
                ),
                amount_to_withdraw,
            )?;
        }

        dao.seq_num += 1;

        let clock = Clock::get()?;
        emit_cpi!(WithdrawLiquidityEvent {
            common: CommonFields::new(&clock, dao.seq_num),
            dao: dao.key(),
            liquidity_provider: liquidity_provider_key,
            liquidity_withdrawn: liquidity_to_withdraw,
            min_base_amount,
            min_quote_amount,
            base_amount: base_to_withdraw,
            quote_amount: quote_to_withdraw,
            post_amm_state: dao.amm.clone(),
        });

        Ok(())
    }
}
use super::*;

use squads_multisig_program::{
    program::SquadsMultisigProgram, Member, Period, Permission, Permissions,
};

#[derive(Debug, Clone, AnchorSerialize, AnchorDeserialize, PartialEq, Eq)]
pub struct InitializeDaoParams {
    pub twap_initial_observation: u128,
    pub twap_max_observation_change_per_update: u128,
    pub twap_start_delay_seconds: u32,
    pub min_quote_futarchic_liquidity: u64,
    pub min_base_futarchic_liquidity: u64,
    pub base_to_stake: u64,
    pub pass_threshold_bps: u16,
    pub seconds_per_proposal: u32,
    pub nonce: u64,
    pub initial_spending_limit: Option<InitialSpendingLimit>,
}

#[derive(Accounts)]
#[event_cpi]
#[instruction(params: InitializeDaoParams)]
pub struct InitializeDao<'info> {
    #[account(
        init,
        payer = payer,
        seeds = [b"dao", dao_creator.key().as_ref(), params.nonce.to_le_bytes().as_ref()],
        bump,
        space = 8 + Dao::INIT_SPACE,
    )]
    pub dao: Box<Account<'info, Dao>>,
    pub dao_creator: Signer<'info>,
    #[account(mut)]
    pub payer: Signer<'info>,
    pub system_program: Program<'info, System>,
    pub base_mint: Box<Account<'info, Mint>>,
    #[account(mint::decimals = 6)]
    pub quote_mint: Box<Account<'info, Mint>>,
    /// CHECK: initialized by squads
    #[account(mut, seeds = [squads_multisig_program::SEED_PREFIX, squads_multisig_program::SEED_MULTISIG, dao.key().as_ref()], bump, seeds::program = squads_program)]
    pub squads_multisig: UncheckedAccount<'info>,
    /// CHECK: just a signer
    #[account(seeds = [squads_multisig_program::SEED_PREFIX, squads_multisig.key().as_ref(), squads_multisig_program::SEED_VAULT, 0_u8.to_le_bytes().as_ref()], bump, seeds::program = squads_program)]
    pub squads_multisig_vault: UncheckedAccount<'info>,
    pub squads_program: Program<'info, SquadsMultisigProgram>,
    /// CHECK: checked by squads
    #[account(seeds = [squads_multisig_program::SEED_PREFIX, squads_multisig_program::SEED_PROGRAM_CONFIG], bump, seeds::program = squads_program)]
    pub squads_program_config: UncheckedAccount<'info>,
    /// CHECK: checked by squads multisig program
    #[account(mut)]
    pub squads_program_config_treasury: UncheckedAccount<'info>,
    /// CHECK: initialized by squads
    #[account(mut, seeds = [squads_multisig_program::SEED_PREFIX, squads_multisig.key().as_ref(), squads_multisig_program::SEED_SPENDING_LIMIT, dao.key().as_ref()], bump, seeds::program = squads_program)]
    pub spending_limit: UncheckedAccount<'info>,
    #[account(init_if_needed, associated_token::mint = base_mint, associated_token::authority = dao, payer = payer)]
    pub futarchy_amm_base_vault: Box<Account<'info, TokenAccount>>,
    #[account(init_if_needed, associated_token::mint = quote_mint, associated_token::authority = dao, payer = payer)]
    pub futarchy_amm_quote_vault: Box<Account<'info, TokenAccount>>,
    pub token_program: Program<'info, Token>,
    pub associated_token_program: Program<'info, AssociatedToken>,
}

pub mod permissionless_account {
    use anchor_lang::prelude::declare_id;

    declare_id!("EP3SoC2SvR3d4c2eXVBvhEMWSr2j3YtoCY3UMiQV7BPD");
}

impl InitializeDao<'_> {
    pub fn handle(ctx: Context<Self>, params: InitializeDaoParams) -> Result<()> {
        let InitializeDaoParams {
            twap_initial_observation,
            twap_max_observation_change_per_update,
            twap_start_delay_seconds,
            min_base_futarchic_liquidity,
            min_quote_futarchic_liquidity,
            base_to_stake,
            pass_threshold_bps,
            seconds_per_proposal,
            nonce,
            initial_spending_limit,
        } = params;

        let dao = &mut ctx.accounts.dao;

        let creator_key = ctx.accounts.dao_creator.key();
        let dao_seeds = &[
            b"dao".as_ref(),
            creator_key.as_ref(),
            &nonce.to_le_bytes(),
            &[ctx.bumps.dao],
        ];

        squads_multisig_program::cpi::multisig_create_v2(
            CpiContext::new_with_signer(
                ctx.accounts.squads_program.to_account_info(),
                squads_multisig_program::cpi::accounts::MultisigCreateV2 {
                    program_config: ctx.accounts.squads_program_config.to_account_info(),
                    multisig: ctx.accounts.squads_multisig.to_account_info(),
                    system_program: ctx.accounts.system_program.to_account_info(),
                    treasury: ctx
                        .accounts
                        .squads_program_config_treasury
                        .to_account_info(),
                    create_key: dao.to_account_info(),
                    creator: ctx.accounts.payer.to_account_info(),
                },
                &[&dao_seeds[..]],
            ),
            squads_multisig_program::MultisigCreateArgsV2 {
                config_authority: Some(dao.key()),
                threshold: 1,
                members: vec![
                    Member {
                        key: dao.key(),
                        permissions: Permissions::from_vec(&[
                            Permission::Vote,
                            Permission::Execute,
                        ]),
                    },
                    Member {
                        key: permissionless_account::id(),
                        permissions: Permissions::from_vec(&[
                            Permission::Initiate,
                            Permission::Execute,
                        ]),
                    },
                ],
                time_lock: 0,
                rent_collector: None,
                memo: None,
            },
        )?;

        if let Some(initial_spending_limit) = initial_spending_limit.clone() {
            require_gte!(
                MAX_SPENDING_LIMIT_MEMBERS,
                initial_spending_limit.members.len()
            );

            squads_multisig_program::cpi::multisig_add_spending_limit(
                CpiContext::new_with_signer(
                    ctx.accounts.squads_program.to_account_info(),
                    squads_multisig_program::cpi::accounts::MultisigAddSpendingLimit {
                        multisig: ctx.accounts.squads_multisig.to_account_info(),
                        system_program: ctx.accounts.system_program.to_account_info(),
                        rent_payer: ctx.accounts.payer.to_account_info(),
                        config_authority: dao.to_account_info(),
                        spending_limit: ctx.accounts.spending_limit.to_account_info(),
                    },
                    &[&dao_seeds[..]],
                ),
                squads_multisig_program::MultisigAddSpendingLimitArgs {
                    create_key: dao.key(),
                    vault_index: 0,
                    mint: ctx.accounts.quote_mint.key(),
                    amount: initial_spending_limit.amount_per_month,
                    period: Period::Month,
                    members: initial_spending_limit.members,
                    destinations: vec![],
                    memo: None,
                },
            )?;
        }

        let clock = Clock::get()?;

        dao.set_inner(Dao {
            nonce,
            dao_creator: creator_key,
            pda_bump: ctx.bumps.dao,
            squads_multisig: ctx.accounts.squads_multisig.key(),
            squads_multisig_vault: ctx.accounts.squads_multisig_vault.key(),
            base_mint: ctx.accounts.base_mint.key(),
            quote_mint: ctx.accounts.quote_mint.key(),
            proposal_count: 0,
            pass_threshold_bps,
            seconds_per_proposal,
            twap_initial_observation,
            twap_max_observation_change_per_update,
            twap_start_delay_seconds,
            min_base_futarchic_liquidity,
            min_quote_futarchic_liquidity,
            base_to_stake,
            seq_num: 0,
            initial_spending_limit,
            amm: FutarchyAmm {
                state: PoolState::Spot {
                    spot: Pool {
                        quote_reserves: 0,
                        base_reserves: 0,
                        quote_protocol_fee_balance: 0,
                        base_protocol_fee_balance: 0,
                        oracle: TwapOracle::new(
                            clock.unix_timestamp,
                            twap_initial_observation,
                            twap_max_observation_change_per_update,
                            0,
                        ),
                    },
                },
                total_liquidity: 0,
                base_mint: ctx.accounts.base_mint.key(),
                quote_mint: ctx.accounts.quote_mint.key(),
                amm_base_vault: ctx.accounts.futarchy_amm_base_vault.key(),
                amm_quote_vault: ctx.accounts.futarchy_amm_quote_vault.key(),
            },
        });

        dao.invariant()?;

        dao.seq_num += 1;

        let clock = Clock::get()?;
        emit_cpi!(InitializeDaoEvent {
            common: CommonFields::new(&clock, dao.seq_num),
            dao: dao.key(),
            base_mint: ctx.accounts.base_mint.key(),
            quote_mint: ctx.accounts.quote_mint.key(),
            pass_threshold_bps: dao.pass_threshold_bps,
            seconds_per_proposal: dao.seconds_per_proposal,
            twap_initial_observation: dao.twap_initial_observation,
            twap_max_observation_change_per_update: dao.twap_max_observation_change_per_update,
            min_quote_futarchic_liquidity: dao.min_quote_futarchic_liquidity,
            min_base_futarchic_liquidity: dao.min_base_futarchic_liquidity,
            base_to_stake: dao.base_to_stake,
            initial_spending_limit: dao.initial_spending_limit.clone(),
            squads_multisig: dao.squads_multisig,
            squads_multisig_vault: dao.squads_multisig_vault,
        });

        Ok(())
    }
}
use anchor_lang::prelude::*;

use crate::{FutarchyAmm, InitialSpendingLimit, Market, ProposalState, SwapType};

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct CommonFields {
    pub slot: u64,
    pub unix_timestamp: i64,
    pub dao_seq_num: u64,
}

impl CommonFields {
    pub fn new(clock: &Clock, dao_seq_num: u64) -> Self {
        Self {
            slot: clock.slot,
            unix_timestamp: clock.unix_timestamp,
            dao_seq_num,
        }
    }
}

#[event]
pub struct CollectFeesEvent {
    pub common: CommonFields,
    pub dao: Pubkey,
    pub base_token_account: Pubkey,
    pub quote_token_account: Pubkey,
    pub amm_base_vault: Pubkey,
    pub amm_quote_vault: Pubkey,
    pub quote_mint: Pubkey,
    pub base_mint: Pubkey,
    pub quote_fees_collected: u64,
    pub base_fees_collected: u64,
    pub post_amm_state: FutarchyAmm,
}

#[event]
pub struct InitializeDaoEvent {
    pub common: CommonFields,
    pub dao: Pubkey,
    pub base_mint: Pubkey,
    pub quote_mint: Pubkey,
    pub pass_threshold_bps: u16,
    pub seconds_per_proposal: u32,
    pub twap_initial_observation: u128,
    pub twap_max_observation_change_per_update: u128,
    pub min_quote_futarchic_liquidity: u64,
    pub min_base_futarchic_liquidity: u64,
    pub base_to_stake: u64,
    pub initial_spending_limit: Option<InitialSpendingLimit>,
    pub squads_multisig: Pubkey,
    pub squads_multisig_vault: Pubkey,
}

#[event]
pub struct UpdateDaoEvent {
    pub common: CommonFields,
    pub dao: Pubkey,
    pub pass_threshold_bps: u16,
    pub seconds_per_proposal: u32,
    pub twap_initial_observation: u128,
    pub twap_max_observation_change_per_update: u128,
    pub min_quote_futarchic_liquidity: u64,
    pub min_base_futarchic_liquidity: u64,
    pub base_to_stake: u64,
}

#[event]
pub struct InitializeProposalEvent {
    pub common: CommonFields,
    pub proposal: Pubkey,
    pub dao: Pubkey,
    pub question: Pubkey,
    pub quote_vault: Pubkey,
    pub base_vault: Pubkey,
    pub proposer: Pubkey,
    pub number: u32,
    pub pda_bump: u8,
    pub duration_in_seconds: u32,
    pub squads_proposal: Pubkey,
    pub squads_multisig: Pubkey,
    pub squads_multisig_vault: Pubkey,
}

#[event]
pub struct StakeToProposalEvent {
    pub common: CommonFields,
    pub proposal: Pubkey,
    pub staker: Pubkey,
    pub amount: u64,
    pub total_staked: u64,
}

#[event]
pub struct UnstakeFromProposalEvent {
    pub common: CommonFields,
    pub proposal: Pubkey,
    pub staker: Pubkey,
    pub amount: u64,
    pub total_staked: u64,
}

#[event]
pub struct LaunchProposalEvent {
    pub common: CommonFields,
    pub proposal: Pubkey,
    pub dao: Pubkey,
    pub total_staked: u64,
    pub post_amm_state: FutarchyAmm,
}

#[event]
pub struct FinalizeProposalEvent {
    pub common: CommonFields,
    pub proposal: Pubkey,
    pub dao: Pubkey,
    pub pass_market_twap: u128,
    pub fail_market_twap: u128,
    pub threshold: u128,
    pub state: ProposalState,
    pub squads_proposal: Pubkey,
    pub squads_multisig: Pubkey,
    pub post_amm_state: FutarchyAmm,
}

#[event]
pub struct SpotSwapEvent {
    pub common: CommonFields,
    pub dao: Pubkey,
    pub user: Pubkey,
    pub swap_type: SwapType,
    pub input_amount: u64,
    pub output_amount: u64,
    pub min_output_amount: u64,
    pub post_amm_state: FutarchyAmm,
}

#[event]
pub struct ConditionalSwapEvent {
    pub common: CommonFields,
    pub dao: Pubkey,
    pub proposal: Pubkey,
    pub trader: Pubkey,
    pub market: Market,
    pub swap_type: SwapType,
    pub input_amount: u64,
    pub output_amount: u64,
    pub min_output_amount: u64,
    pub post_amm_state: FutarchyAmm,
}

#[event]
pub struct ProvideLiquidityEvent {
    pub common: CommonFields,
    pub dao: Pubkey,
    pub liquidity_provider: Pubkey,
    pub position_authority: Pubkey,
    pub quote_amount: u64,
    pub base_amount: u64,
    pub liquidity_minted: u128,
    pub min_liquidity: u128,
    pub post_amm_state: FutarchyAmm,
}

#[event]
pub struct WithdrawLiquidityEvent {
    pub common: CommonFields,
    pub dao: Pubkey,
    pub liquidity_provider: Pubkey,
    pub liquidity_withdrawn: u128,
    pub min_base_amount: u64,
    pub min_quote_amount: u64,
    pub base_amount: u64,
    pub quote_amount: u64,
    pub post_amm_state: FutarchyAmm,
}
use super::*;

#[error_code]
pub enum FutarchyError {
    #[msg("Amms must have been created within 5 minutes (counted in slots) of proposal initialization")]
    AmmTooOld,
    #[msg("An amm has an `initial_observation` that doesn't match the `dao`'s config")]
    InvalidInitialObservation,
    #[msg(
        "An amm has a `max_observation_change_per_update` that doesn't match the `dao`'s config"
    )]
    InvalidMaxObservationChange,
    #[msg("An amm has a `start_delay_slots` that doesn't match the `dao`'s config")]
    InvalidStartDelaySlots,
    #[msg("One of the vaults has an invalid `settlement_authority`")]
    InvalidSettlementAuthority,
    #[msg("Proposal is too young to be executed or rejected")]
    ProposalTooYoung,
    #[msg("Markets too young for proposal to be finalized. TWAP might need to be cranked")]
    MarketsTooYoung,
    #[msg("This proposal has already been finalized")]
    ProposalAlreadyFinalized,
    #[msg("A conditional vault has an invalid nonce. A nonce should encode the proposal number")]
    InvalidVaultNonce,
    #[msg("This proposal can't be executed because it isn't in the passed state")]
    ProposalNotPassed,
    #[msg("More liquidity needs to be in the AMM to launch this proposal")]
    InsufficientLiquidity,
    #[msg("Proposal duration must be longer 1 day and longer than 2 times the TWAP start delay")]
    ProposalDurationTooShort,
    #[msg("Pass threshold must be less than 10%")]
    PassThresholdTooHigh,
    #[msg("Question must have exactly 2 outcomes for binary futarchy")]
    QuestionMustBeBinary,
    #[msg("Squads proposal must be in Draft status")]
    InvalidSquadsProposalStatus,
    #[msg("Casting overflow. If you're seeing this, please report this")]
    CastingOverflow,
    #[msg("Insufficient balance")]
    InsufficientBalance,
    #[msg("Cannot remove zero liquidity")]
    ZeroLiquidityRemove,
    #[msg("Swap slippage exceeded")]
    SwapSlippageExceeded,
    #[msg("Assert failed")]
    AssertFailed,
    #[msg("Invalid admin")]
    InvalidAdmin,
    #[msg("Proposal is not in draft state")]
    ProposalNotInDraftState,
    #[msg("Insufficient token balance")]
    InsufficientTokenBalance,
    #[msg("Invalid amount")]
    InvalidAmount,
    #[msg("Insufficient stake to launch proposal")]
    InsufficientStakeToLaunch,
    #[msg("Staker not found in proposal")]
    StakerNotFound,
    #[msg("Pool must be in spot state")]
    PoolNotInSpotState,
    #[msg("If you're providing liquidity, you must provide both base and quote token accounts")]
    InvalidDaoCreateLiquidity,
    #[msg("Invalid stake account")]
    InvalidStakeAccount,
    #[msg("An invariant was violated. You should get in contact with the MetaDAO team if you see this")]
    InvariantViolated,
    #[msg("Proposal needs to be active to perform a conditional swap")]
    ProposalNotActive,
    #[msg("This Squads transaction should only contain calls to update spending limits")]
    InvalidTransaction,
}
use anchor_lang::prelude::*;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token::{self, Mint, Token, TokenAccount, Transfer};
use conditional_vault::program::ConditionalVault as ConditionalVaultProgram;
use conditional_vault::{ConditionalVault, Question};

pub mod error;
pub mod events;
pub mod instructions;
pub mod state;

pub use error::FutarchyError;
pub use events::*;
pub use instructions::*;
pub use state::*;

#[cfg(not(feature = "no-entrypoint"))]
use solana_security_txt::security_txt;

#[cfg(not(feature = "no-entrypoint"))]
security_txt! {
    name: "futarchy",
    project_url: "https://metadao.fi",
    contacts: "telegram:metaproph3t,telegram:kollan_house",
    source_code: "https://github.com/metaDAOproject/programs",
    source_release: "v0.6.0",
    policy: "The market will decide whether we pay a bug bounty.",
    acknowledgements: "DCF = (CF1 / (1 + r)^1) + (CF2 / (1 + r)^2) + ... (CFn / (1 + r)^n)"
}

declare_id!("FUTARELBfJfQ8RDGhg1wdhddq1odMAJUePHFuBYfUxKq");

pub const SLOTS_PER_10_SECS: u64 = 25;
pub const ONE_MINUTE_IN_SLOTS: u64 = 6 * SLOTS_PER_10_SECS;

pub const MIN_QUOTE_LIQUIDITY: u64 = 100_000;

pub const TEN_DAYS_IN_SECONDS: i64 = 10 * 24 * 60 * 60;

pub const PRICE_SCALE: u128 = 1_000_000_000_000;

// by default, the pass price needs to be 3% higher than the fail price
pub const DEFAULT_PASS_THRESHOLD_BPS: u16 = 300;

// MetaDAO takes 0.2%, LP takes 0.4%
pub const LP_TAKER_FEE_BPS: u16 = 25;
pub const PROTOCOL_TAKER_FEE_BPS: u16 = 25;
pub const MAX_BPS: u16 = 10_000;

// the index of the fail and pass outcomes in the question and the index of
// the pass and fail conditional tokens in the conditional vault
pub const FAIL_INDEX: usize = 0;
pub const PASS_INDEX: usize = 1;

// TWAP can only move by $5 per slot
pub const DEFAULT_MAX_OBSERVATION_CHANGE_PER_UPDATE_LOTS: u64 = 5_000;

#[program]
pub mod futarchy {
    use super::*;

    pub fn initialize_dao(ctx: Context<InitializeDao>, params: InitializeDaoParams) -> Result<()> {
        InitializeDao::handle(ctx, params)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn initialize_proposal(ctx: Context<InitializeProposal>) -> Result<()> {
        InitializeProposal::handle(ctx)
    }

    #[access_control(ctx.accounts.validate(&params))]
    pub fn stake_to_proposal(
        ctx: Context<StakeToProposal>,
        params: StakeToProposalParams,
    ) -> Result<()> {
        StakeToProposal::handle(ctx, params)
    }

    #[access_control(ctx.accounts.validate(&params))]
    pub fn unstake_from_proposal(
        ctx: Context<UnstakeFromProposal>,
        params: UnstakeFromProposalParams,
    ) -> Result<()> {
        UnstakeFromProposal::handle(ctx, params)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn launch_proposal(ctx: Context<LaunchProposal>) -> Result<()> {
        LaunchProposal::handle(ctx)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn finalize_proposal(ctx: Context<FinalizeProposal>) -> Result<()> {
        FinalizeProposal::handle(ctx)
    }

    pub fn update_dao(ctx: Context<UpdateDao>, dao_params: UpdateDaoParams) -> Result<()> {
        UpdateDao::handle(ctx, dao_params)
    }

    // AMM instructions

    pub fn spot_swap(ctx: Context<SpotSwap>, params: SpotSwapParams) -> Result<()> {
        SpotSwap::handle(ctx, params)
    }

    #[access_control(ctx.accounts.validate(&params))]
    pub fn conditional_swap(
        ctx: Context<ConditionalSwap>,
        params: ConditionalSwapParams,
    ) -> Result<()> {
        ConditionalSwap::handle(ctx, params)
    }

    pub fn provide_liquidity(
        ctx: Context<ProvideLiquidity>,
        params: ProvideLiquidityParams,
    ) -> Result<()> {
        ProvideLiquidity::handle(ctx, params)
    }

    pub fn withdraw_liquidity(
        ctx: Context<WithdrawLiquidity>,
        params: WithdrawLiquidityParams,
    ) -> Result<()> {
        WithdrawLiquidity::handle(ctx, params)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn collect_fees(ctx: Context<CollectFees>) -> Result<()> {
        CollectFees::handle(ctx)
    }

    #[access_control(ctx.accounts.validate())]
    pub fn execute_spending_limit_change<'c: 'info, 'info>(
        ctx: Context<'_, '_, 'c, 'info, ExecuteSpendingLimitChange<'info>>,
    ) -> Result<()> {
        ExecuteSpendingLimitChange::handle(ctx)
    }
}
use super::*;

#[derive(Clone, Copy, AnchorSerialize, AnchorDeserialize, PartialEq, Eq, Debug, InitSpace)]
pub enum ProposalState {
    Draft { amount_staked: u64 },
    Pending,
    Passed,
    Failed,
}

impl std::fmt::Display for ProposalState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self)
    }
}

#[account]
#[derive(InitSpace)]
pub struct Proposal {
    pub number: u32,
    pub proposer: Pubkey,
    pub timestamp_enqueued: i64,
    pub state: ProposalState,
    pub base_vault: Pubkey,
    pub quote_vault: Pubkey,
    pub dao: Pubkey,
    pub pda_bump: u8,
    pub question: Pubkey,
    pub duration_in_seconds: u32,
    pub squads_proposal: Pubkey,
    pub pass_base_mint: Pubkey,
    pub pass_quote_mint: Pubkey,
    pub fail_base_mint: Pubkey,
    pub fail_quote_mint: Pubkey,
}
use anchor_lang::prelude::*;

#[account]
#[derive(InitSpace)]
pub struct AmmPosition {
    pub dao: Pubkey,
    pub position_authority: Pubkey,
    pub liquidity: u128,
}
use super::*;

#[account]
#[derive(InitSpace)]
pub struct StakeAccount {
    pub proposal: Pubkey,
    pub staker: Pubkey,
    pub amount: u64,
    pub bump: u8,
}
pub mod amm_position;
pub mod dao;
pub mod futarchy_amm;
pub mod proposal;
pub mod stake_account;

pub use amm_position::*;
pub use dao::*;
pub use futarchy_amm::*;
pub use proposal::*;
pub use stake_account::*;

pub use super::*;
use anchor_lang::prelude::*;

use crate::{FutarchyError, LP_TAKER_FEE_BPS, MAX_BPS, PROTOCOL_TAKER_FEE_BPS};
use std::cmp::Ordering;

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, InitSpace)]
pub struct FutarchyAmm {
    pub state: PoolState,
    pub total_liquidity: u128,
    pub base_mint: Pubkey,
    pub quote_mint: Pubkey,
    pub amm_base_vault: Pubkey,
    pub amm_quote_vault: Pubkey,
}

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, InitSpace)]
pub enum PoolState {
    Spot { spot: Pool },
    Futarchy { spot: Pool, pass: Pool, fail: Pool },
}

#[derive(AnchorSerialize, AnchorDeserialize, PartialEq, Eq, Debug, Clone, Copy)]
pub enum Market {
    Spot,
    Pass,
    Fail,
}

impl std::fmt::Display for Market {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}", self)
    }
}

impl PoolState {
    pub fn swap(&mut self, input_amount: u64, swap_type: SwapType, market: Market) -> Result<u64> {
        let clock = Clock::get()?;

        match self {
            PoolState::Spot { spot } => {
                require_eq!(market, Market::Spot);

                spot.update_twap(clock.unix_timestamp)?;

                spot.swap(input_amount, swap_type)
            }
            PoolState::Futarchy { spot, pass, fail } => {
                let pre_spot = spot.clone();
                let pre_pass = pass.clone();
                let pre_fail = fail.clone();

                spot.update_twap(clock.unix_timestamp)?;
                pass.update_twap(clock.unix_timestamp)?;
                fail.update_twap(clock.unix_timestamp)?;

                let spot_k = spot.k();
                let pass_k = pass.k();
                let fail_k = fail.k();

                match market {
                    Market::Spot => {
                        let spot_output = spot.swap(input_amount, swap_type)?;

                        let arbitrage_result =
                            arbitrage_after_spot_swap(spot, pass, fail, spot_output, swap_type)?;

                        match swap_type {
                            SwapType::Buy => {
                                pass.base_protocol_fee_balance += arbitrage_result.pass_profit;
                                fail.base_protocol_fee_balance += arbitrage_result.fail_profit;
                            }
                            SwapType::Sell => {
                                pass.quote_protocol_fee_balance += arbitrage_result.pass_profit;
                                fail.quote_protocol_fee_balance += arbitrage_result.fail_profit;
                            }
                        }

                        require_gte!(spot.k(), spot_k);
                        require_gte!(pass.k(), pass_k);
                        require_gte!(fail.k(), fail_k);

                        Ok(spot_output + arbitrage_result.spot_profit)
                    }
                    Market::Pass | Market::Fail => {
                        let conditional_output = match market {
                            Market::Pass => pass.swap(input_amount, swap_type)?,
                            Market::Fail => fail.swap(input_amount, swap_type)?,
                            Market::Spot => unreachable!(),
                        };

                        let arbitrage_result = arbitrage_after_conditional_swap(
                            spot,
                            pass,
                            fail,
                            conditional_output,
                            swap_type,
                            market,
                        )?;

                        // Split the spot
                        let conditional_profit = match market {
                            Market::Pass => {
                                // We split the spot so we can maximize conditional profit, so we take the other side of the split
                                // and add it to the protocol fee balance
                                match swap_type {
                                    SwapType::Buy => {
                                        fail.base_protocol_fee_balance += arbitrage_result
                                            .fail_profit
                                            + arbitrage_result.spot_profit
                                    }
                                    SwapType::Sell => {
                                        fail.quote_protocol_fee_balance += arbitrage_result
                                            .fail_profit
                                            + arbitrage_result.spot_profit
                                    }
                                }

                                arbitrage_result.pass_profit + arbitrage_result.spot_profit
                            }
                            Market::Fail => {
                                match swap_type {
                                    SwapType::Buy => {
                                        pass.base_protocol_fee_balance += arbitrage_result
                                            .pass_profit
                                            + arbitrage_result.spot_profit
                                    }
                                    SwapType::Sell => {
                                        pass.quote_protocol_fee_balance += arbitrage_result
                                            .pass_profit
                                            + arbitrage_result.spot_profit
                                    }
                                }

                                arbitrage_result.fail_profit + arbitrage_result.spot_profit
                            }
                            Market::Spot => unreachable!(),
                        };

                        require_gte!(spot.k(), spot_k);
                        require_gte!(pass.k(), pass_k);
                        require_gte!(fail.k(), fail_k);

                        fn get_total_reserves(spot: &Pool, conditional: &Pool) -> (u64, u64) {
                            let total_quote = spot.quote_reserves
                                + conditional.quote_reserves
                                + spot.quote_protocol_fee_balance
                                + conditional.quote_protocol_fee_balance;
                            let total_base = spot.base_reserves
                                + conditional.base_reserves
                                + spot.base_protocol_fee_balance
                                + conditional.base_protocol_fee_balance;
                            (total_quote, total_base)
                        }

                        let (total_pass_quote_before, total_pass_base_before) =
                            get_total_reserves(&pre_spot, &pre_pass);
                        let (total_pass_quote_after, total_pass_base_after) =
                            get_total_reserves(&spot, &pass);
                        let (total_fail_quote_before, total_fail_base_before) =
                            get_total_reserves(&pre_spot, &pre_fail);
                        let (total_fail_quote_after, total_fail_base_after) =
                            get_total_reserves(&spot, &fail);

                        // these shouldn't be triggered, but just in case
                        match (market, swap_type) {
                            (Market::Pass, SwapType::Buy) => {
                                require_eq!(
                                    total_pass_quote_after,
                                    total_pass_quote_before + input_amount,
                                    FutarchyError::InvariantViolated
                                );
                                require_eq!(
                                    total_fail_quote_after,
                                    total_fail_quote_before,
                                    FutarchyError::InvariantViolated
                                );
                                require_eq!(
                                    total_pass_base_after,
                                    total_pass_base_before
                                        - (conditional_output + conditional_profit),
                                    FutarchyError::InvariantViolated
                                );
                                require_eq!(
                                    total_fail_base_after,
                                    total_fail_base_before,
                                    FutarchyError::InvariantViolated
                                );
                            }
                            (Market::Fail, SwapType::Buy) => {
                                require_eq!(
                                    total_pass_quote_after,
                                    total_pass_quote_before,
                                    FutarchyError::InvariantViolated
                                );
                                require_eq!(
                                    total_fail_quote_after,
                                    total_fail_quote_before + input_amount,
                                    FutarchyError::InvariantViolated
                                );
                                require_eq!(
                                    total_pass_base_after,
                                    total_pass_base_before,
                                    FutarchyError::InvariantViolated
                                );
                                require_eq!(
                                    total_fail_base_after,
                                    total_fail_base_before
                                        - (conditional_output + conditional_profit),
                                    FutarchyError::InvariantViolated
                                );
                            }
                            (Market::Pass, SwapType::Sell) => {
                                require_eq!(
                                    total_pass_quote_after,
                                    total_pass_quote_before
                                        - (conditional_output + conditional_profit),
                                    FutarchyError::InvariantViolated
                                );
                                require_eq!(
                                    total_fail_quote_after,
                                    total_fail_quote_before,
                                    FutarchyError::InvariantViolated
                                );
                                require_eq!(
                                    total_pass_base_after,
                                    total_pass_base_before + input_amount,
                                    FutarchyError::InvariantViolated
                                );
                                require_eq!(
                                    total_fail_base_after,
                                    total_fail_base_before,
                                    FutarchyError::InvariantViolated
                                );
                            }
                            (Market::Fail, SwapType::Sell) => {
                                require_eq!(
                                    total_pass_quote_after,
                                    total_pass_quote_before,
                                    FutarchyError::InvariantViolated
                                );
                                require_eq!(
                                    total_fail_quote_after,
                                    total_fail_quote_before
                                        - (conditional_output + conditional_profit),
                                    FutarchyError::InvariantViolated
                                );
                                require_eq!(
                                    total_pass_base_after,
                                    total_pass_base_before,
                                    FutarchyError::InvariantViolated
                                );
                                require_eq!(
                                    total_fail_base_after,
                                    total_fail_base_before + input_amount,
                                    FutarchyError::InvariantViolated
                                );
                            }
                            (Market::Spot, _) => unreachable!(),
                        }

                        Ok(conditional_output + conditional_profit)
                    }
                }
            }
        }
    }
}

#[derive(Default, Clone, Copy, Debug, AnchorDeserialize, AnchorSerialize, InitSpace)]
pub struct TwapOracle {
    /// Running sum of slots_per_last_update * last_observation.
    ///
    /// Assuming latest observations are as big as possible (u64::MAX * 1e12),
    /// we can store 18 million slots worth of observations, which turns out to
    /// be ~85 days worth of slots.
    ///
    /// Assuming that latest observations are 100x smaller than they could theoretically
    /// be, we can store 8500 days (23 years) worth of them. Even this is a very
    /// very conservative assumption - META/USDC prices should be between 1e9 and
    /// 1e15, which would overflow after 1e15 years worth of slots.
    ///
    /// So in the case of an overflow, the aggregator rolls back to 0. It's the
    /// client's responsibility to sanity check the assets or to handle an
    /// aggregator at T2 being smaller than an aggregator at T1.
    pub aggregator: u128,
    pub last_updated_timestamp: i64,
    pub created_at_timestamp: i64,
    /// A price is the number of quote units per base unit multiplied by 1e12.
    /// You cannot simply divide by 1e12 to get a price you can display in the UI
    /// because the base and quote decimals may be different. Instead, do:
    /// ui_price = (price * (10**(base_decimals - quote_decimals))) / 1e12
    pub last_price: u128,
    /// If we did a raw TWAP over prices, someone could push the TWAP heavily with
    /// a few extremely large outliers. So we use observations, which can only move
    /// by `max_observation_change_per_update` per update.
    pub last_observation: u128,
    /// The most that an observation can change per update.
    pub max_observation_change_per_update: u128,
    /// What the initial `latest_observation` is set to.
    pub initial_observation: u128,
    /// Number of seconds after amm.created_at_slot to start recording TWAP
    pub start_delay_seconds: u32,
}

impl TwapOracle {
    pub fn new(
        current_timestamp: i64,
        initial_observation: u128,
        max_observation_change_per_update: u128,
        start_delay_seconds: u32,
    ) -> Self {
        Self {
            created_at_timestamp: current_timestamp,
            last_updated_timestamp: current_timestamp,
            last_price: 0,
            last_observation: initial_observation,
            aggregator: 0,
            max_observation_change_per_update,
            initial_observation,
            start_delay_seconds,
        }
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, InitSpace)]
pub struct Pool {
    pub oracle: TwapOracle,
    pub quote_reserves: u64,
    pub base_reserves: u64,
    pub quote_protocol_fee_balance: u64,
    pub base_protocol_fee_balance: u64,
}

impl Pool {
    /// Updates the TWAP. Should be called before any changes to the AMM's state
    /// have been made.
    ///
    /// Returns an observation if one was recorded.
    pub fn update_twap(&mut self, current_timestamp: i64) -> Result<Option<u128>> {
        let oracle = &mut self.oracle;

        // a manipulator is likely to be "bursty" with their usage, such as a
        // validator who abuses their slots to manipulate the TWAP.
        // meanwhile, regular trading is less likely to happen in each slot.
        // suppose that in normal trading, one trade happens every 4 slots.
        // if we allow observations to move 1% per slot, a manipulator who
        // can land every slot would be able to move the last observation by 348%
        // over 1 minute (1.01^(# of slots in a minute)) whereas normal trading
        // activity would be only able to move it by 45% over 1 minute
        // (1.01^(# of slots in a minute / 4)). so it makes sense to not allow an
        // update every slot.
        //
        // on the other hand, you can't allow updates too infrequently either.
        // if you could only update once a day, a manipulator only needs to buy
        // one slot per day to drastically shift the TWAP.
        //
        // we allow updates once a minute as a happy medium. if you have an asset
        // that trades near $1500 and you allow $25 updates per minute, it can double
        // over an hour.
        if current_timestamp < oracle.last_updated_timestamp + 60 {
            return Ok(None);
        }

        if self.base_reserves == 0 || self.quote_reserves == 0 {
            return Ok(None);
        }

        // we store prices as quote units / base units scaled by 1e12.
        // for example, suppose META is $100 and there's 400 USDC & 4 META in
        // this pool. USDC has 6 decimals and META has 9, so we have:
        // - 400 * 1,000,000   = 400,000,000 USDC units
        // - 4 * 1,000,000,000 = 4,000,000,000 META units (hansons)
        // so there's (400,000,000 / 4,000,000,000) or 0.1 USDC units per hanson,
        // which is 100,000,000,000 when scaled by 1e12.
        let price = (self.quote_reserves as u128 * crate::PRICE_SCALE) / self.base_reserves as u128;

        let last_observation = oracle.last_observation;

        let new_observation = if price > last_observation {
            let max_observation =
                last_observation.saturating_add(oracle.max_observation_change_per_update);

            std::cmp::min(price, max_observation)
        } else {
            let min_observation =
                last_observation.saturating_sub(oracle.max_observation_change_per_update);

            std::cmp::max(price, min_observation)
        };

        // if the start delay hasn't passed, we don't update the aggregator
        // but we still update the observation
        let twap_start_timestamp = oracle.created_at_timestamp + oracle.start_delay_seconds as i64;

        let new_aggregator = if current_timestamp <= twap_start_timestamp {
            oracle.aggregator
        } else {
            // so that we don't act as if the first update ocurred over the whole
            // pre-start delay period
            let effective_last_updated_timestamp =
                oracle.last_updated_timestamp.max(twap_start_timestamp);

            let slot_difference: u128 = (current_timestamp - effective_last_updated_timestamp)
                .try_into()
                .unwrap();

            // if this saturates, the aggregator will wrap back to 0, so this value doesn't
            // really matter. we just can't panic.
            let weighted_observation = new_observation.saturating_mul(slot_difference);

            oracle.aggregator.wrapping_add(weighted_observation)
        };

        let new_oracle = TwapOracle {
            created_at_timestamp: oracle.created_at_timestamp,
            last_updated_timestamp: current_timestamp,
            last_price: price,
            last_observation: new_observation,
            aggregator: new_aggregator,
            // these three shouldn't change
            max_observation_change_per_update: oracle.max_observation_change_per_update,
            initial_observation: oracle.initial_observation,
            start_delay_seconds: oracle.start_delay_seconds,
        };

        require_gt!(
            new_oracle.last_updated_timestamp,
            oracle.last_updated_timestamp
        );

        // assert that the new observation is between price and last observation
        match price.cmp(&oracle.last_observation) {
            Ordering::Greater => {
                require_gte!(new_observation, oracle.last_observation);
                require_gte!(price, new_observation);
            }
            Ordering::Equal => {
                require_eq!(new_observation, price);
            }
            Ordering::Less => {
                require_gte!(oracle.last_observation, new_observation);
                require_gte!(new_observation, price);
            }
        }

        *oracle = new_oracle;

        Ok(Some(new_observation))
    }

    /// Returns the time-weighted average price since market creation
    pub fn get_twap(&self) -> Result<u128> {
        let start_timestamp =
            self.oracle.created_at_timestamp + self.oracle.start_delay_seconds as i64;

        require_gt!(self.oracle.last_updated_timestamp, start_timestamp);
        let seconds_passed = (self.oracle.last_updated_timestamp - start_timestamp) as u128;

        require_neq!(seconds_passed, 0);
        require_neq!(self.oracle.aggregator, 0);

        Ok(self.oracle.aggregator / seconds_passed)
    }
}

// Buy spot to above conditional -> sell spot & buy back conditional, META profit
// Buy conditional to above spot -> sell conditional & buy back spot, META profit
// Sell spot to below conditional -> buy spot & sell back conditional, USDC profit
// Sell conditional to below spot -> buy conditional & sell back spot, USDC profit

#[derive(PartialEq, Eq, Debug, Clone, Copy, AnchorSerialize, AnchorDeserialize)]
pub enum SwapType {
    Buy,
    Sell,
}

impl Pool {
    pub fn k(&self) -> u128 {
        (self.base_reserves as u128) * (self.quote_reserves as u128)
    }

    #[cfg(test)]
    pub fn price(&self) -> f64 {
        self.quote_reserves as f64 / self.base_reserves as f64
    }

    pub fn swap(&mut self, input_amount: u64, swap_type: SwapType) -> Result<u64> {
        let input_amount_after_protocol_fee = (input_amount as u128
            * (MAX_BPS - PROTOCOL_TAKER_FEE_BPS) as u128
            / MAX_BPS as u128) as u64;
        let protocol_fee = input_amount - input_amount_after_protocol_fee;

        if swap_type == SwapType::Buy {
            self.quote_protocol_fee_balance += protocol_fee;
        } else {
            self.base_protocol_fee_balance += protocol_fee;
        }

        let k = self.k();

        let (input_reserve, output_reserve) = match swap_type {
            SwapType::Buy => (self.quote_reserves, self.base_reserves),
            SwapType::Sell => (self.base_reserves, self.quote_reserves),
        };

        // airlifted from uniswap v1:
        // https://github.com/Uniswap/v1-contracts/blob/c10c08d81d6114f694baa8bd32f555a40f6264da/contracts/uniswap_exchange.vy#L106-L111

        require_neq!(input_reserve, 0);
        require_neq!(output_reserve, 0);

        let input_amount_with_lp_fee =
            input_amount_after_protocol_fee as u128 * (MAX_BPS - LP_TAKER_FEE_BPS) as u128;

        let numerator = input_amount_with_lp_fee * output_reserve as u128;

        let denominator =
            (input_reserve as u128 * MAX_BPS as u128) + input_amount_with_lp_fee as u128;

        let output_amount = (numerator / denominator) as u64;

        match swap_type {
            SwapType::Buy => {
                self.quote_reserves += input_amount_after_protocol_fee;
                self.base_reserves -= output_amount;
            }
            SwapType::Sell => {
                self.base_reserves += input_amount_after_protocol_fee;
                self.quote_reserves -= output_amount;
            }
        }

        let new_k = self.k();

        require_gte!(new_k, k);

        Ok(output_amount)
    }

    pub fn feeless_swap(&mut self, input_amount: u64, swap_type: SwapType) -> Result<u64> {
        let k = self.k();

        let (input_reserve, output_reserve) = match swap_type {
            SwapType::Buy => (self.quote_reserves, self.base_reserves),
            SwapType::Sell => (self.base_reserves, self.quote_reserves),
        };

        // airlifted from uniswap v1:
        // https://github.com/Uniswap/v1-contracts/blob/c10c08d81d6114f694baa8bd32f555a40f6264da/contracts/uniswap_exchange.vy#L106-L111

        require_neq!(input_reserve, 0);
        require_neq!(output_reserve, 0);

        let numerator = input_amount as u128 * output_reserve as u128;

        let denominator = input_reserve as u128 + input_amount as u128;

        let output_amount = (numerator / denominator) as u64;

        match swap_type {
            SwapType::Buy => {
                self.quote_reserves += input_amount;
                self.base_reserves -= output_amount;
            }
            SwapType::Sell => {
                self.base_reserves += input_amount;
                self.quote_reserves -= output_amount;
            }
        }

        let new_k = self.k();

        require_gte!(new_k, k);

        Ok(output_amount)
    }

    pub fn simulate_swap(&self, input_amount: u64, swap_type: SwapType) -> Result<u64> {
        let mut pool = self.clone();
        pool.feeless_swap(input_amount, swap_type)
    }

    /// Get the number of base and quote tokens withdrawable from a position
    pub fn get_base_and_quote_withdrawable(
        &self,
        lp_tokens: u64,
        lp_total_supply: u64,
    ) -> (u64, u64) {
        (
            self.get_base_withdrawable(lp_tokens, lp_total_supply),
            self.get_quote_withdrawable(lp_tokens, lp_total_supply),
        )
    }

    /// Get the number of base tokens withdrawable from a position
    pub fn get_base_withdrawable(&self, lp_tokens: u64, lp_total_supply: u64) -> u64 {
        // must fit back into u64 since `lp_tokens` <= `lp_total_supply`
        ((lp_tokens as u128 * self.base_reserves as u128) / lp_total_supply as u128) as u64
    }

    /// Get the number of quote tokens withdrawable from a position
    pub fn get_quote_withdrawable(&self, lp_tokens: u64, lp_total_supply: u64) -> u64 {
        ((lp_tokens as u128 * self.quote_reserves as u128) / lp_total_supply as u128) as u64
    }
}

#[derive(PartialEq, Eq, Debug, Clone, Copy)]
pub enum Token {
    Base,
    Quote,
}

#[derive(Debug, Clone)]
pub struct ArbitrageResult {
    pub spot_profit: u64,
    pub pass_profit: u64,
    pub fail_profit: u64,
}

pub fn arbitrage_after_spot_swap(
    spot: &mut Pool,
    pass: &mut Pool,
    fail: &mut Pool,
    max_input: u64,
    swap_type: SwapType,
) -> Result<ArbitrageResult> {
    let mut best_profit = 0;
    let mut best_input_amount = 0;

    let step_size = max_input / 100;

    // If we're buying spot, we want to maximize base profit & spot is possibly above
    // conditional, so we sell spot & buy conditional. If we're selling spot, we want
    // to maximize quote profit & spot is possibly below conditional, so we buy spot &
    // sell conditional.
    let (spot_direction, conditional_direction) = match swap_type {
        SwapType::Buy => (SwapType::Sell, SwapType::Buy),
        SwapType::Sell => (SwapType::Buy, SwapType::Sell),
    };

    for i in 1..=100 {
        let input_amount = i * step_size;

        let spot_output = spot.simulate_swap(input_amount, spot_direction).unwrap();

        let pass_output = pass
            .simulate_swap(spot_output, conditional_direction)
            .unwrap();

        let fail_output = fail
            .simulate_swap(spot_output, conditional_direction)
            .unwrap();

        let conditional_output = std::cmp::min(pass_output, fail_output);

        let profit = conditional_output as i64 - input_amount as i64;

        if fail_output > pass_output {
            msg!("fail output: {}", (fail_output - pass_output));
            msg!("profit: {}", profit);
        }

        if profit > best_profit {
            best_profit = profit;
            best_input_amount = input_amount;
        } else {
            break;
        }
    }

    let final_spot_output = spot
        .feeless_swap(best_input_amount, spot_direction)
        .unwrap();

    let final_pass_output = pass
        .feeless_swap(final_spot_output, conditional_direction)
        .unwrap();

    let final_fail_output = fail
        .feeless_swap(final_spot_output, conditional_direction)
        .unwrap();

    let final_conditional_output = std::cmp::min(final_pass_output, final_fail_output);

    let (remaining_pass, remaining_fail) = if final_pass_output > final_fail_output {
        (final_pass_output - final_conditional_output, 0)
    } else {
        (0, final_fail_output - final_conditional_output)
    };

    assert!(final_conditional_output >= best_input_amount);
    assert_eq!(
        final_conditional_output - best_input_amount,
        best_profit as u64
    );

    Ok(ArbitrageResult {
        spot_profit: best_profit as u64,
        pass_profit: remaining_pass,
        fail_profit: remaining_fail,
    })
}

pub fn arbitrage_after_conditional_swap(
    spot: &mut Pool,
    pass: &mut Pool,
    fail: &mut Pool,
    max_input: u64,
    swap_type: SwapType,
    market: Market,
) -> Result<ArbitrageResult> {
    // We're selling conditional, so we want quote profit
    // assert!(post_direction == SwapType::Sell);

    // Assume for now that we're selling fail so want fUSDC profit
    let mut best_arb_profit = 0;
    let mut best_arb_input_amount = 0;

    let step_size = max_input / 100;

    // If we're buying conditional, we want to maximize base profit & spot is possibly below
    // conditional, so we sell conditional and buy spot. If we're selling conditional, we want
    // to maximize quote profit & spot is possibly above conditional, so we buy conditional and
    // sell spot.
    let (conditional_direction, spot_direction) = match swap_type {
        SwapType::Buy => (SwapType::Sell, SwapType::Buy),
        SwapType::Sell => (SwapType::Buy, SwapType::Sell),
    };

    for i in 1..=100 {
        let input_amount = i * step_size;

        // We clone these because we're doing a swap later to sell our remaining
        // and we want to use accurate reserves
        let mut temp_pass = pass.clone();
        let mut temp_fail = fail.clone();

        let pass_output = temp_pass
            .feeless_swap(input_amount, conditional_direction)
            .unwrap();
        let fail_output = temp_fail
            .feeless_swap(input_amount, conditional_direction)
            .unwrap();

        let conditional_output = std::cmp::min(pass_output, fail_output);

        let spot_output = spot
            .simulate_swap(conditional_output, spot_direction)
            .unwrap();

        let spot_profit = spot_output as i64 - input_amount as i64;

        if market == Market::Fail {
            let fail_remaining_from_step_1 = fail_output.saturating_sub(conditional_output);

            let fail_profit_from_remaining = temp_fail
                .feeless_swap(fail_remaining_from_step_1, spot_direction)
                .unwrap();

            // We can split those spot tokens, so for the purpose of profit maximization we consider
            // spot + profit from remaining
            let fail_profit_incl_spot = fail_profit_from_remaining as i64 + spot_profit;

            // msg!("{} = {} + {}", fail_profit_incl_spot, fail_profit_from_remaining, spot_profit);

            if fail_profit_incl_spot > best_arb_profit && spot_profit >= 0 {
                best_arb_profit = fail_profit_incl_spot;
                best_arb_input_amount = input_amount;
            } else {
                break;
            }
        } else if market == Market::Pass {
            let pass_remaining_from_step_1 = pass_output.saturating_sub(conditional_output);

            let pass_profit_from_remaining = temp_pass
                .feeless_swap(pass_remaining_from_step_1, spot_direction)
                .unwrap();

            let pass_profit_incl_spot = pass_profit_from_remaining as i64 + spot_profit;

            if pass_profit_incl_spot > best_arb_profit && spot_profit >= 0 {
                best_arb_profit = pass_profit_incl_spot;
                best_arb_input_amount = input_amount;
            } else {
                break;
            }
        } else {
            unreachable!()
        }
    }

    let final_pass_output = pass
        .feeless_swap(best_arb_input_amount, conditional_direction)
        .unwrap();
    let final_fail_output = fail
        .feeless_swap(best_arb_input_amount, conditional_direction)
        .unwrap();
    let final_conditional_output = std::cmp::min(final_pass_output, final_fail_output);

    let final_spot_output = spot
        .feeless_swap(final_conditional_output, spot_direction)
        .unwrap();

    let fail_profit = if final_fail_output > final_pass_output {
        let remaining_fail = final_fail_output - final_conditional_output;

        let fail_profit_from_base_remaining =
            fail.feeless_swap(remaining_fail, spot_direction).unwrap();

        fail_profit_from_base_remaining
    } else {
        0
    };

    let pass_profit = if final_pass_output > final_fail_output {
        let remaining_pass = final_pass_output - final_conditional_output;

        let pass_profit_from_base_remaining =
            pass.feeless_swap(remaining_pass, spot_direction).unwrap();

        pass_profit_from_base_remaining
    } else {
        0
    };

    assert!(final_spot_output >= best_arb_input_amount);
    let spot_profit = final_spot_output - best_arb_input_amount;

    // assert_eq!(final_spot_output - best_input_amount, best_profit as u64);

    Ok(ArbitrageResult {
        spot_profit,
        pass_profit,
        fail_profit,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_base_arbitrage() {
        let mut spot = Pool {
            base_reserves: 100 * 1_000_000,
            quote_reserves: 100 * 1_000_000,
            quote_protocol_fee_balance: 0,
            base_protocol_fee_balance: 0,
            oracle: TwapOracle::new(0, 0, 0, 0),
        };

        let mut pass = Pool {
            base_reserves: 100 * 1_000_000,
            quote_reserves: 100 * 1_000_000,
            quote_protocol_fee_balance: 0,
            base_protocol_fee_balance: 0,
            oracle: TwapOracle::new(0, 0, 0, 0),
        };

        let mut fail = Pool {
            base_reserves: 100 * 1_000_000,
            quote_reserves: 100 * 1_000_000,
            quote_protocol_fee_balance: 0,
            base_protocol_fee_balance: 0,
            oracle: TwapOracle::new(0, 0, 0, 0),
        };

        // spot.swap(1 * 1_000_000, SwapType::Buy).unwrap();

        // fail.swap(1 * 1_100_000, SwapType::Sell).unwrap();

        // let result = conditional_arbitrage_after_cond(&mut spot, &mut pass, &mut fail, 1 * 1_100_000, SwapType::Sell).unwrap();

        // msg!("result: {:?}", result);

        // let spot_output = spot.swap(1 * 1_000_000, SwapType::Buy).unwrap();

        let mut state = PoolState::Futarchy { spot, pass, fail };

        let output = state
            .swap(1 * 1_000_000, SwapType::Buy, Market::Spot)
            .unwrap();

        msg!("output: {:?}", output);

        let output = state
            .swap(1 * 1_000_000, SwapType::Sell, Market::Pass)
            .unwrap();

        msg!("output: {:?}", output);

        let output = state
            .swap(1 * 1_200_000, SwapType::Sell, Market::Fail)
            .unwrap();

        msg!("output: {:?}", output);

        if let PoolState::Futarchy { spot, pass, fail } = &mut state {
            msg!("spot: {:?}, price: {:?}", spot, spot.price());

            msg!("pass: {:?}, price: {:?}", pass, pass.price());

            msg!("fail: {:?}, price: {:?}", fail, fail.price());
        }
    }
}
pub use super::*;

pub const MAX_SPENDING_LIMIT_MEMBERS: usize = 10;

#[account]
#[derive(InitSpace)]
pub struct Dao {
    /// Embedded FutarchyAmm - 1:1 relationship
    pub amm: FutarchyAmm,
    /// `nonce` + `dao_creator` are PDA seeds
    pub nonce: u64,
    pub dao_creator: Pubkey,
    pub pda_bump: u8,
    pub squads_multisig: Pubkey,
    pub squads_multisig_vault: Pubkey,
    pub base_mint: Pubkey,
    pub quote_mint: Pubkey,
    pub proposal_count: u32,
    // the percentage, in basis points, the pass price needs to be above the
    // fail price in order for the proposal to pass
    pub pass_threshold_bps: u16,
    pub seconds_per_proposal: u32,
    /// For manipulation-resistance the TWAP is a time-weighted average observation,
    /// where observation tries to approximate price but can only move by
    /// `twap_max_observation_change_per_update` per update. Because it can only move
    /// a little bit per update, you need to check that it has a good initial observation.
    /// Otherwise, an attacker could create a very high initial observation in the pass
    /// market and a very low one in the fail market to force the proposal to pass.
    ///
    /// We recommend setting an initial observation around the spot price of the token,
    /// and max observation change per update around 2% the spot price of the token.
    /// For example, if the spot price of META is $400, we'd recommend setting an initial
    /// observation of 400 (converted into the AMM prices) and a max observation change per
    /// update of 8 (also converted into the AMM prices). Observations can be updated once
    /// a minute, so 2% allows the proposal market to reach double the spot price or 0
    /// in 50 minutes.
    pub twap_initial_observation: u128,
    pub twap_max_observation_change_per_update: u128,
    /// Forces TWAP calculation to start after `twap_start_delay_seconds` seconds
    pub twap_start_delay_seconds: u32,
    /// As an anti-spam measure and to help liquidity, you need to lock up some liquidity
    /// in both futarchic markets in order to create a proposal.
    ///
    /// For example, for META, we can use a `min_quote_futarchic_liquidity` of
    /// 5000 * 1_000_000 (5000 USDC) and a `min_base_futarchic_liquidity` of
    /// 10 * 1_000_000_000 (10 META).
    pub min_quote_futarchic_liquidity: u64,
    pub min_base_futarchic_liquidity: u64,
    /// Minimum amount of base tokens that must be staked to launch a proposal
    pub base_to_stake: u64,
    pub seq_num: u64,
    pub initial_spending_limit: Option<InitialSpendingLimit>,
}

#[derive(AnchorSerialize, AnchorDeserialize, Debug, Clone, PartialEq, Eq, InitSpace)]
pub struct InitialSpendingLimit {
    pub amount_per_month: u64,
    #[max_len(MAX_SPENDING_LIMIT_MEMBERS)]
    pub members: Vec<Pubkey>,
}

impl Dao {
    pub fn invariant(&self) -> Result<()> {
        require_gte!(
            self.seconds_per_proposal,
            self.twap_start_delay_seconds * 2,
            FutarchyError::ProposalDurationTooShort
        );

        require_gte!(
            self.seconds_per_proposal,
            60 * 60 * 24,
            FutarchyError::ProposalDurationTooShort
        );

        require_gte!(
            1_000,
            self.pass_threshold_bps,
            FutarchyError::PassThresholdTooHigh
        );

        Ok(())
    }
}
use anchor_lang::prelude::*;

pub mod constants {
    pub mod seeds {
        pub const CONFIG_PREFIX: &[u8] = b"config";
        pub const CUSTOMIZABLE_POOL_PREFIX: &[u8] = b"cpool";
        pub const POOL_PREFIX: &[u8] = b"pool";
        pub const TOKEN_VAULT_PREFIX: &[u8] = b"token_vault";
        pub const POOL_AUTHORITY_PREFIX: &[u8] = b"pool_authority";
        pub const POSITION_PREFIX: &[u8] = b"position";
        pub const POSITION_NFT_ACCOUNT_PREFIX: &[u8] = b"position_nft_account";
        pub const TOKEN_BADGE_PREFIX: &[u8] = b"token_badge";
        pub const REWARD_VAULT_PREFIX: &[u8] = b"reward_vault";
        pub const CLAIM_FEE_OPERATOR_PREFIX: &[u8] = b"cf_operator";
    }

    pub const MIN_SQRT_PRICE: u128 = 4295048016;
    pub const MAX_SQRT_PRICE: u128 = 79226673521066979257578248091;
}

declare_id!("cpamdpZCGKUy5JxQXB4dcpGPiikHawvSWAd6mEn1sGG");

#[program]
pub mod damm_v2_cpi {
    use super::*;

    pub fn initialize_pool_with_dynamic_config(
        _ctx: Context<InitializePoolWithDynamicConfigCtx>,
        _params: InitializeCustomizablePoolParameters,
    ) -> Result<()> {
        Ok(())
    }
}

/// Information regarding fee charges
#[derive(Copy, Clone, Debug, AnchorSerialize, AnchorDeserialize, InitSpace, Default)]
pub struct PoolFeeParameters {
    /// Base fee
    pub base_fee: BaseFeeParameters,
    /// padding
    pub padding: [u8; 3],
    /// dynamic fee
    pub dynamic_fee: Option<DynamicFeeParameters>,
}

#[derive(Copy, Clone, Debug, AnchorSerialize, AnchorDeserialize, InitSpace, Default)]
pub struct BaseFeeParameters {
    pub cliff_fee_numerator: u64,
    pub number_of_period: u16,
    pub period_frequency: u64,
    pub reduction_factor: u64,
    pub fee_scheduler_mode: u8,
}

#[derive(Copy, Clone, Debug, AnchorSerialize, AnchorDeserialize, InitSpace, Default)]
pub struct DynamicFeeParameters {
    pub bin_step: u16,
    pub bin_step_u128: u128,
    pub filter_period: u16,
    pub decay_period: u16,
    pub reduction_factor: u16,
    pub max_volatility_accumulator: u32,
    pub variable_fee_control: u32,
}

#[derive(AnchorSerialize, AnchorDeserialize)]
pub struct InitializeCustomizablePoolParameters {
    /// pool fees
    pub pool_fees: PoolFeeParameters,
    /// sqrt min price
    pub sqrt_min_price: u128,
    /// sqrt max price
    pub sqrt_max_price: u128,
    /// has alpha vault
    pub has_alpha_vault: bool,
    /// initialize liquidity
    pub liquidity: u128,
    /// The init price of the pool as a sqrt(token_b/token_a) Q64.64 value
    pub sqrt_price: u128,
    /// activation type
    pub activation_type: u8,
    /// collect fee mode
    pub collect_fee_mode: u8,
    /// activation point
    pub activation_point: Option<u64>,
}

#[event_cpi]
#[derive(Accounts)]
pub struct InitializePoolWithDynamicConfigCtx<'info> {
    /// CHECK: Pool creator
    pub creator: UncheckedAccount<'info>,

    #[account(mut)]
    pub position_nft_mint: Signer<'info>,

    /// CHECK: CPI
    #[account(mut)]
    pub position_nft_account: UncheckedAccount<'info>,

    /// Address paying to create the pool. Can be anyone
    #[account(mut)]
    pub payer: Signer<'info>,

    pub pool_creator_authority: Signer<'info>,

    /// CHECK: CPI
    pub config: UncheckedAccount<'info>,

    /// CHECK: pool authority
    pub pool_authority: UncheckedAccount<'info>,

    /// CHECK: CPI
    #[account(mut)]
    pub pool: UncheckedAccount<'info>,

    /// CHECK: CPI
    #[account(mut)]
    pub position: UncheckedAccount<'info>,

    /// CHECK: CPI
    pub token_a_mint: UncheckedAccount<'info>,

    /// CHECK: CPI
    pub token_b_mint: UncheckedAccount<'info>,

    /// CHECK: CPI
    #[account(mut)]
    pub token_a_vault: UncheckedAccount<'info>,

    /// CHECK: CPI
    #[account(mut)]
    pub token_b_vault: UncheckedAccount<'info>,

    /// CHECK: CPI
    #[account(mut)]
    pub payer_token_a: UncheckedAccount<'info>,

    /// CHECK: CPI
    #[account(mut)]
    pub payer_token_b: UncheckedAccount<'info>,

    /// CHECK: CPI
    pub token_a_program: UncheckedAccount<'info>,
    /// CHECK: CPI
    pub token_b_program: UncheckedAccount<'info>,

    /// CHECK: CPI
    pub token_2022_program: UncheckedAccount<'info>,

    // Sysvar for program account
    pub system_program: Program<'info, System>,
}
