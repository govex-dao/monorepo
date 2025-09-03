# Futarchy Protocol Dogfooding Setup

## Overview
This document describes how the Futarchy protocol can be governed by one of its own DAOs (dogfooding), allowing the protocol owner DAO and its security council to control all platform admin functions through market-based governance.

## Admin Capabilities

The Futarchy protocol has three main admin capabilities that control platform operations:

### 1. FactoryOwnerCap
Controls the DAO factory operations:
- Pause/unpause factory (emergency stop for new DAO creation)
- Add/remove allowed stable coin types for DAOs
- Manage factory configuration

### 2. FeeAdminCap  
Controls all fee management:
- Update DAO creation fees
- Update proposal creation fees
- Update monthly DAO fees (with built-in delay)
- Update verification fees by level
- Update recovery fees
- Withdraw accumulated fees to treasury

### 3. ValidatorAdminCap
Controls DAO verification (currently stored but not actively used)

## Architecture

### Storage Pattern
All admin caps are stored in the protocol DAO's Account as managed assets with specific keys:
- `protocol:factory_owner_cap` - FactoryOwnerCap storage
- `protocol:fee_admin_cap` - FeeAdminCap storage  
- `protocol:validator_admin_cap` - ValidatorAdminCap storage

### Module Structure

#### protocol_admin_actions.move
Contains all action definitions and execution functions for protocol administration:
- Factory actions (pause, stable type management)
- Fee actions (all fee updates and withdrawals)
- Security council helper functions for emergency access

#### protocol_admin_intents.move
Handles the initial migration of admin caps to the DAO:
- Intent definitions for accepting each cap type
- Execution functions for cap transfer
- Migration helper functions for initial setup

#### action_dispatcher.move
Extended with `execute_protocol_admin_operations` to route protocol admin actions to the appropriate handlers.

## Migration Process

### Initial Setup
The current admin cap holders need to transfer control to the protocol DAO:

```move
// Option 1: Migrate all caps at once
protocol_admin_intents::migrate_admin_caps_to_dao(
    dao_account,
    factory_cap,
    fee_cap, 
    validator_cap,
    ctx
);

// Option 2: Gradual migration - transfer caps individually
protocol_admin_intents::migrate_factory_cap_to_dao(dao_account, factory_cap, ctx);
protocol_admin_intents::migrate_fee_cap_to_dao(dao_account, fee_cap, ctx);
protocol_admin_intents::migrate_validator_cap_to_dao(dao_account, validator_cap, ctx);
```

### Through Governance Proposal
Caps can also be transferred through standard governance proposals using intents:

1. Create proposal with cap transfer intent
2. Markets trade on the proposal
3. If passed, execute the intent to accept the cap

## Governance Flow

Once admin caps are in the DAO's custody:

1. **Proposal Creation**: Community member creates a proposal with protocol admin actions
2. **Market Trading**: Conditional markets determine if the action should execute
3. **Execution**: If markets approve, the action dispatcher executes using stored caps

### Example: Update DAO Creation Fee

```move
// Create action in proposal
let action = protocol_admin_actions::new_update_dao_creation_fee(new_fee);

// During execution (if proposal passes)
protocol_admin_actions::do_update_dao_creation_fee(
    executable,
    dao_account,
    version,
    witness,
    fee_manager,
    clock,
    ctx
);
```

## Security Council Access

The security council can be granted emergency access to admin functions:

### Emergency Factory Pause
```move
protocol_admin_actions::council_set_factory_paused(
    council_account,
    executable,
    factory,
    true, // pause
    version,
    ctx
);
```

### Emergency Fee Withdrawal  
```move
protocol_admin_actions::council_withdraw_emergency_fees(
    council_account,
    executable,
    fee_manager,
    amount,
    version,
    ctx
);
```

## Benefits of Dogfooding

1. **Decentralized Control**: No single entity controls protocol parameters
2. **Market-Based Decisions**: Protocol changes guided by prediction markets
3. **Transparent Governance**: All admin actions go through public proposals
4. **Emergency Safety**: Security council retains emergency powers
5. **Aligned Incentives**: Token holders directly control protocol they use

## Implementation Status

✅ **Completed**:
- protocol_admin_actions module with all action definitions
- protocol_admin_intents module for cap migration
- Action dispatcher integration
- Security council emergency functions

🔄 **Future Improvements**:
- Add validator admin functionality when verification system is ready
- Implement time-locked admin actions for additional security
- Add multi-sig requirements for critical operations
- Create admin action templates for common operations

## Testing Checklist

- [ ] Test initial cap migration to DAO
- [ ] Test factory pause/unpause through proposal
- [ ] Test fee updates with proper delays
- [ ] Test security council emergency access
- [ ] Test cap storage and retrieval from Account
- [ ] Test full proposal lifecycle with admin actions
- [ ] Verify caps cannot be accessed by unauthorized accounts