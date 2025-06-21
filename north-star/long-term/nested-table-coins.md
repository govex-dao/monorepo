```
module futarchy::conditional_balances {
    use sui::table::{Self, Table};
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::type_name::{Self, TypeName};
    
    // ===== Proposal Object =====
    
    public struct Proposal has key {
        id: UID,
        outcomes: u8,
        resolved: bool,
        winning_outcome: Option<u8>,
    }
    
    // ===== Core Account Structure (unchanged) =====
    
    public struct UserAccount has key {
        id: UID,
        owner: address,
        admin: address,
        // proposal_id -> ProposalBalances
        proposals: Table<ID, ProposalBalances>,
    }
    
    public struct ProposalBalances has store {
        // outcome -> OutcomeBalances
        outcomes: Table<u8, OutcomeBalances>,
    }
    
    public struct OutcomeBalances has store {
        // coin_type -> balance
        balances: Table<TypeName, Balance<any>>,
    }
    
    // ===== Create Proposal =====
    
    public fun create_proposal(
        outcomes: u8,
        ctx: &mut TxContext
    ): Proposal {
        Proposal {
            id: object::new(ctx),
            outcomes,
            resolved: false,
            winning_outcome: option::none(),
        }
    }
    
    // ===== Resolve Proposal =====
    
    public fun resolve_proposal(
        proposal: &mut Proposal,
        winning_outcome: u8,
        _: &AdminCap  // Or whatever auth mechanism
    ) {
        assert!(!proposal.resolved, ALREADY_RESOLVED);
        assert!(winning_outcome < proposal.outcomes, INVALID_OUTCOME);
        
        proposal.resolved = true;
        proposal.winning_outcome = option::some(winning_outcome);
    }
    
    // ===== Process Single Resolution =====
    
    // User passes in resolved proposal to process
    public fun process_resolution<T>(
        account: &mut UserAccount,
        proposal: &Proposal,
        coin_type_witness: &T,  // For type inference
        ctx: &mut TxContext
    ): u64 {
        assert!(proposal.resolved, NOT_RESOLVED);
        
        let proposal_id = object::id(proposal);
        let winning_outcome = *option::borrow(&proposal.winning_outcome);
        let coin_type = type_name::get<T>();
        
        // Check if user has positions in this proposal
        if (!table::contains(&account.proposals, proposal_id)) {
            return 0
        };
        
        let proposal_balances = table::remove(&mut account.proposals, proposal_id);
        let mut_outcomes = &mut proposal_balances.outcomes;
        
        // Extract winning balance if exists
        let amount = if (table::contains(mut_outcomes, winning_outcome)) {
            let outcome_balances = table::remove(mut_outcomes, winning_outcome);
            let mut_balances = &mut outcome_balances.balances;
            
            if (table::contains(mut_balances, coin_type)) {
                let balance = table::remove(mut_balances, coin_type);
                let amt = balance::value(&balance);
                
                // Create coin and send to user
                let coin = coin::from_balance(balance, ctx);
                transfer::public_transfer(coin, account.owner);
                
                amt
            } else {
                0
            }
        } else {
            0
        };
        
        // Clean up all tables (winners and losers)
        let ProposalBalances { outcomes } = proposal_balances;
        let outcome = 0u8;
        while (table::contains(&outcomes, outcome)) {
            let OutcomeBalances { balances } = table::remove(&mut outcomes, outcome);
            // Destroy any remaining balances (losers)
            table::drop_empty(balances);
            outcome = outcome + 1;
        };
        table::destroy_empty(outcomes);
        
        amount
    }
    
    // ===== Batch Processing =====
    
    // Process multiple proposals at once
    public fun process_multiple_resolutions(
        account: &mut UserAccount,
        proposals: vector<&Proposal>,
        ctx: &mut TxContext
    ) {
        let i = 0;
        while (i < vector::length(&proposals)) {
            let proposal = vector::borrow(&proposals, i);
            
            if (proposal.resolved) {
                process_all_coins_for_proposal(account, proposal, ctx);
            };
            
            i = i + 1;
        };
    }
    
    // Process all coin types for a proposal
    fun process_all_coins_for_proposal(
        account: &mut UserAccount,
        proposal: &Proposal,
        ctx: &mut TxContext
    ) {
        let proposal_id = object::id(proposal);
        let winning_outcome = *option::borrow(&proposal.winning_outcome);
        
        if (!table::contains(&account.proposals, proposal_id)) {
            return
        };
        
        let proposal_balances = table::remove(&mut account.proposals, proposal_id);
        let mut_outcomes = &mut proposal_balances.outcomes;
        
        // Process winning outcome if exists
        if (table::contains(mut_outcomes, winning_outcome)) {
            let outcome_balances = table::remove(mut_outcomes, winning_outcome);
            let coin_types = table::keys(&outcome_balances.balances);
            
            // Redeem each coin type
            let i = 0;
            while (i < vector::length(&coin_types)) {
                let coin_type = vector::borrow(&coin_types, i);
                let balance = table::remove(&mut outcome_balances.balances, *coin_type);
                
                // Dynamic dispatch to create appropriate coin type
                redeem_balance_dynamic(balance, *coin_type, account.owner, ctx);
                
                i = i + 1;
            };
            
            let OutcomeBalances { balances } = outcome_balances;
            table::destroy_empty(balances);
        };
        
        // Clean up remaining outcomes
        let ProposalBalances { outcomes } = proposal_balances;
        table::drop_empty(outcomes);
    }
    
    // ===== Admin Functions =====
    
    public fun admin_process_resolution(
        account: &mut UserAccount,
        proposal: &Proposal,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == account.admin, NOT_ADMIN);
        process_all_coins_for_proposal(account, proposal, ctx);
    }
    
    public fun admin_batch_process(
        account: &mut UserAccount,
        proposals: vector<&Proposal>,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == account.admin, NOT_ADMIN);
        process_multiple_resolutions(account, proposals, ctx);
    }
    
    // ===== Query Functions =====
    
    // Check if user has positions in a proposal
    public fun has_positions(
        account: &UserAccount,
        proposal: &Proposal
    ): bool {
        table::contains(&account.proposals, object::id(proposal))
    }
    
    // Get user's positions in unresolved proposal
    public fun get_positions(
        account: &UserAccount,
        proposal: &Proposal
    ): vector<(u8, TypeName, u64)> {
        assert!(!proposal.resolved, PROPOSAL_RESOLVED);
        
        let proposal_id = object::id(proposal);
        let result = vector::empty();
        
        if (!table::contains(&account.proposals, proposal_id)) {
            return result
        };
        
        let proposal_balances = table::borrow(&account.proposals, proposal_id);
        
        let outcome = 0u8;
        while (table::contains(&proposal_balances.outcomes, outcome)) {
            let outcome_balances = table::borrow(&proposal_balances.outcomes, outcome);
            let coin_types = table::keys(&outcome_balances.balances);
            
            let i = 0;
            while (i < vector::length(&coin_types)) {
                let coin_type = vector::borrow(&coin_types, i);
                let balance = table::borrow(&outcome_balances.balances, *coin_type);
                
                vector::push_back(&mut result, (
                    outcome,
                    *coin_type,
                    balance::value(balance)
                ));
                
                i = i + 1;
            };
            
            outcome = outcome + 1;
        };
        
        result
    }
}
```