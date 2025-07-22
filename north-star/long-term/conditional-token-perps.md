look into https://github.com/omnipair/omnipair-rs

https://www.omnipair.fi/

Study this from their docs

"""

Omnipair is a decentralized hyperstructure protocol for spot & margin trading designed for permissionless, oracle-less, and isolated-collateral markets. It enables anyone to lend, borrow, and trade long-tail assets with leverage, without relying on governance whitelists, external oracles, or centralized risk management.

Built on Solana and powered by a novel Generalized Automated Market Maker (GAMM) model, Omnipair introduces a mechanism where liquidity is not only used for swaps but also natively lent out to borrowers, maximizing capital efficiency in every pool.

Why?
Today, most money markets and margin trading options in DeFi are:

Permissioned: Teams must approve assets before they can be used.

Oracle-reliant: Introduces attack vectors and external dependencies.

Inefficient: 

AMMs leave liquidity idle; 

Lending markets are isolated and cannot operate without external makers.

These constraints especially affect long-tail assets that lack deep integrations but command real market demand. 

More details in Problem

How?
GAMM: Coupled spot trading and lending in one entity / pool.

Oracle-less EMA pricing: EMA replaces oracles for debt pricing.

Slippage-aware Dynamic Collateral Factor: derived from xy=k variant to ensure lending doesn't break the AMM invariant. 

Streaming liquidations: Collateral is streamed to the pool over time.

Recursive leverage: Leverage is achieved via in-protocol recursive borrowing (looping).

Find more details in Technical breakdown

Vision
Omnipair is a new primitive for margin trading & permissionless lending/borrowing, autonomous by design and governed by code, not committees. It opens the door to trading leverage on any asset that has liquidity, without permission.
"""