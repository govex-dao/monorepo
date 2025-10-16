/// Standard coin type definitions for the Futarchy protocol
module futarchy_types::coin_types;

/// USDC stablecoin type
/// This is a witness type for USDC on Sui
/// The actual USDC coin will be registered on-chain with this type
public struct USDC has drop {}

/// USDT stablecoin type
/// This is a witness type for USDT on Sui
/// The actual USDT coin will be registered on-chain with this type
public struct USDT has drop {}
