# Govex DAO Licensing Notice
- This codebase is a fork of the account.tech Move Framework (see `https://github.com/account-tech/move-framework`), which is distributed under the Apache License, Version 2.0.
- Govex DAO LLC has relicensed its modifications under the Business Source License 1.1 (BUSL-1.1) while preserving all Apache 2.0 obligations for inherited code.
- Every Move source file now begins with a BUSL header. Files that retain material from account.tech also include an inline note acknowledging the Apache-licensed portions.

## File Classification
- **Dual-licensed (Apache 2.0 heritage + BUSL 1.1 additions)**  
  `packages/actions/sources/intents/access_control.move`  
  `packages/actions/sources/intents/currency.move`  
  `packages/actions/sources/intents/empty.move`  
  `packages/actions/sources/intents/owned.move`  
  `packages/actions/sources/intents/package_upgrade.move`  
  `packages/actions/sources/intents/vault.move`  
  `packages/actions/sources/lib/access_control.move`  
  `packages/actions/sources/lib/currency.move`  
  `packages/actions/sources/lib/package_upgrade.move`  
  `packages/actions/sources/lib/transfer.move`  
  `packages/actions/sources/lib/vault.move`  
  `packages/actions/sources/lib/vesting.move`  
  `packages/actions/sources/version.move`  
  `packages/extensions/sources/extensions.move`  
  `packages/protocol/sources/account.move`  
  `packages/protocol/sources/actions/config.move`  
  `packages/protocol/sources/actions/owned.move`  
  `packages/protocol/sources/interfaces/account_interface.move`  
  `packages/protocol/sources/interfaces/intent_interface.move`  
  `packages/protocol/sources/types/deps.move`  
  `packages/protocol/sources/types/executable.move`  
  `packages/protocol/sources/types/intents.move`  
  `packages/protocol/sources/types/metadata.move`  
  `packages/protocol/sources/types/version_witness.move`  
  `packages/protocol/sources/user.move`  
  `packages/protocol/sources/version.move`

- **Govex-authored (BUSL 1.1 only)**  
  `packages/actions/sources/decoders/access_control_decoder.move`  
  `packages/actions/sources/decoders/currency_decoder.move`  
  `packages/actions/sources/decoders/decoder_registry_init.move`  
  `packages/actions/sources/decoders/package_upgrade_decoder.move`  
  `packages/actions/sources/decoders/transfer_decoder.move`  
  `packages/actions/sources/decoders/vault_decoder.move`  
  `packages/actions/sources/decoders/vesting_decoder.move`  
  `packages/actions/sources/init/init_actions.move`  
  `packages/actions/sources/intents/vesting.move`  
  `packages/actions/sources/lib/stream_utils.move`  
  `packages/extensions/sources/framework_action_types.move`  
  `packages/protocol/sources/action_validation.move`  
  `packages/protocol/sources/bcs_validation.move`  
  `packages/protocol/sources/decoder_validation.move`  
  `packages/protocol/sources/schema.move`

## Maintenance Notes
- When substantial account.tech code is brought into a new file, leave the Apache notice in place and add the Govex BUSL header plus the attribution comment.
- If a file is rewritten from scratch and no longer contains Apache-licensed material, the attribution comment can be removed after confirming the origin of all lines.
- Keep this notice in sync with future upstream merges or newly authored modules so the licensing footprint stays clear.
