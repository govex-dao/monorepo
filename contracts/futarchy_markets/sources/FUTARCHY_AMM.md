This is a novel type of amm.
It has has a spot pool and when a proposal is created a set proportion of the liqudity is taken out of there and put into the conditional liqudiity. This proportion is a dao config, but has to be between 10 and 90%.

The conditinal markets a quantum hanson style liqudiity and coins.

So 1 spot USDC deposited goes to 1 USDC for each of the N outcomes.

When think about this system while a propsoal is live always model it an N conditional outcomes and n conditional outcomes.

Only on conditional outcome can win.

The conditional coins for that oucome can be redeemed for spot coin. The conditional AMM LP with be auto cranked back into the spot AMM. 

⏺ YES! That's a great solution! Let me break it down:

  SDK-Level Conditional Branching (This Works!)

  // SDK reads pool to check if proposal is active
  async function buildSmartSwap(
    poolId: string,
    stableIn: TransactionArgument,
    minAssetOut: number,
    recipient: string,
  ) {
    // 1. Read pool state off-chain
    const pool = await client.getObject({ id: poolId });
    const config = pool.data.content.fields.aggregator_config;
    const activeProposalId = config?.fields?.active_proposal_id;

    const tx = new TransactionBlock();

    // 2. Conditional branching in SDK
    if (activeProposalId) {
      // Proposal is live → use auto-arb function

      // Derive escrow ID from proposal
      const proposal = await client.getObject({ id: activeProposalId });
      const escrowId = proposal.data.content.fields.escrow_id;

      // Call auto-arb swap
      tx.moveCall({
        target: `${PKG}::swap_entry::swap_spot_stable_to_asset`,
        arguments: [
          tx.object(poolId),
          tx.object(activeProposalId),  // ← Discovered
          tx.object(escrowId),           // ← Derived
          stableIn,
          tx.pure(minAssetOut),
          tx.pure(recipient),
          tx.object(CLOCK_ID),
        ],
      });
    } else {
      // No proposal → use simple spot swap
      tx.moveCall({
        target: `${PKG}::unified_spot_pool::swap_stable_for_asset`,
        arguments: [
          tx.object(poolId),  // ← Only pool needed!
          stableIn,
          tx.pure(minAssetOut),
          tx.object(CLOCK_ID),
        ],
      });
    }

    return tx;
  }

  // User's perspective: Just one function, SDK handles everything
  aftermathSDK.swap({
    pool: "0x123...",
    amountIn: 1000,
    minOut: 990,
  });