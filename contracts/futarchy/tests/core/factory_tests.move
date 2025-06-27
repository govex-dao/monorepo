#[test_only]
module futarchy::asset_coin {
    public struct ASSET_COIN has drop {}

    public fun create(): ASSET_COIN {
        ASSET_COIN {}
    }
}

#[test_only]
module futarchy::stable_coin {
    public struct STABLE_COIN has drop {}

    public fun create(): STABLE_COIN {
        STABLE_COIN {}
    }
}

#[test_only]
module futarchy::factory_tests {
    use futarchy::asset_coin::{Self, ASSET_COIN};
    use futarchy::dao::{Self, DAO};
    use futarchy::factory::{Self, Factory, FactoryOwnerCap, ValidatorAdminCap};
    use futarchy::fee::{Self, FeeManager};
    use futarchy::stable_coin::{Self, STABLE_COIN};
    use std::string::{Self, String};
    use sui::clock;
    use sui::coin::{Self, CoinMetadata, Coin};
    use sui::sui::SUI;
    use sui::test_scenario::{Self as test, ctx};
    use sui::url;

    const ADMIN: address = @0xA;
    const USER: address = @0xB;
    const MIN_ASSET_AMOUNT: u64 = 2_000_000;
    const MIN_STABLE_AMOUNT: u64 = 2_000_000;
    const REVIEW_PERIOD_MS: u64 = 2_000_000; // 2 s
    const TRADING_PERIOD_MS: u64 = 2_000_000; // 2 s
    const TEST_DAO_NAME: vector<u8> = b"TestDAO";
    const TEST_DAO_URL: vector<u8> = b"https://test.com";
    const TWAP_THRESHOLD: u64 = 1_000;
    const TWAP_INITIAL_OBSERVATION: u128 = 1_000_000;

    fun mint_sui(amount: u64, ctx: &mut sui::tx_context::TxContext): Coin<SUI> {
        coin::mint_for_testing(amount, ctx)
    }

    fun setup(scenario: &mut test::Scenario) {
        test::next_tx(scenario, ADMIN);
        {
            let (treasury_cap_asset, metadata_asset) = coin::create_currency(
                asset_coin::create(),
                9,
                b"ASSET",
                b"Asset Coin",
                b"Test asset coin",
                option::some(url::new_unsafe_from_bytes(b"https://test.com")),
                ctx(scenario),
            );

            let (treasury_cap_stable, metadata_stable) = coin::create_currency(
                stable_coin::create(),
                9,
                b"STABLE",
                b"Stable Coin",
                b"Test stable coin",
                option::some(url::new_unsafe_from_bytes(b"https://test.com")),
                ctx(scenario),
            );

            // Create factory
            factory::create_factory(ctx(scenario));

            // Create fee manager - ADD THIS LINE
            fee::create_fee_manager_for_testing(ctx(scenario));

            transfer::public_transfer(treasury_cap_asset, ADMIN);
            transfer::public_transfer(treasury_cap_stable, ADMIN);
            transfer::public_share_object(metadata_asset);
            transfer::public_share_object(metadata_stable);
        };
    }

    // Helper to setup and create a DAO
    fun setup_with_dao(scenario: &mut test::Scenario, clock: &clock::Clock) {
        // Setup factory
        test::next_tx(scenario, ADMIN);
        {
            let (treasury_cap_asset, metadata_asset) = coin::create_currency(
                asset_coin::create(),
                9,
                b"ASSET",
                b"Asset Coin",
                b"Test asset coin",
                option::some(sui::url::new_unsafe_from_bytes(b"https://test.com")),
                ctx(scenario),
            );

            let (treasury_cap_stable, metadata_stable) = coin::create_currency(
                stable_coin::create(),
                9,
                b"STABLE",
                b"Stable Coin",
                b"Test stable coin",
                option::some(sui::url::new_unsafe_from_bytes(b"https://test.com")),
                ctx(scenario),
            );

            factory::create_factory(ctx(scenario));
            fee::create_fee_manager_for_testing(ctx(scenario));

            transfer::public_transfer(treasury_cap_asset, ADMIN);
            transfer::public_transfer(treasury_cap_stable, ADMIN);
            transfer::public_share_object(metadata_asset);
            transfer::public_share_object(metadata_stable);
        };

        // Create a DAO
        test::next_tx(scenario, USER);
        {
            let mut factory = test::take_shared<Factory>(scenario);
            let mut fee_manager = test::take_shared<FeeManager>(scenario);
            let payment = coin::mint_for_testing(
                fee::get_dao_creation_fee(&fee_manager),
                ctx(scenario),
            );
            let dao_name = std::ascii::string(TEST_DAO_NAME);
            let icon_url = std::ascii::string(TEST_DAO_URL);
            let asset_metadata = test::take_shared<CoinMetadata<ASSET_COIN>>(scenario);
            let stable_metadata = test::take_shared<CoinMetadata<STABLE_COIN>>(scenario);

            factory::create_dao<ASSET_COIN, STABLE_COIN>(
                &mut factory,
                &mut fee_manager,
                payment,
                MIN_ASSET_AMOUNT,
                MIN_STABLE_AMOUNT,
                dao_name,
                icon_url,
                REVIEW_PERIOD_MS,
                TRADING_PERIOD_MS,
                &asset_metadata,
                &stable_metadata,
                60_000,
                300_000,
                TWAP_INITIAL_OBSERVATION,
                TWAP_THRESHOLD,
                string::utf8(b"DAO description"),
                clock,
                ctx(scenario),
            );

            test::return_shared(factory);
            test::return_shared(fee_manager);
            test::return_shared(asset_metadata);
            test::return_shared(stable_metadata);
        };
    }

    // Test 1: Attempting to request verification for an already verified DAO should fail
    #[test]
    #[expected_failure(abort_code = factory::EAlreadyVerified)]
    fun test_request_verification_already_verified() {
        let mut scenario = test::begin(ADMIN);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        setup_with_dao(&mut scenario, &clock);

        // Request verification first time
        test::next_tx(&mut scenario, USER);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let mut dao = test::take_shared<DAO>(&scenario);
            let payment = coin::mint_for_testing(
                fee::get_verification_fee(&fee_manager),
                ctx(&mut scenario),
            );
            let attestation_url = string::utf8(b"https://example.com/attestation");

            factory::request_verification(
                &mut fee_manager,
                payment,
                &mut dao,
                attestation_url,
                &clock,
                ctx(&mut scenario),
            );

            test::return_shared(fee_manager);
            test::return_shared(dao);
        };

        // Approve verification
        test::next_tx(&mut scenario, ADMIN);
        {
            let mut dao = test::take_shared<DAO>(&scenario);
            let validator_cap = test::take_from_address<ValidatorAdminCap>(&scenario, ADMIN);

            let verification_id = object::new(ctx(&mut scenario));
            let verification_id_inner = object::uid_to_inner(&verification_id);
            object::delete(verification_id);

            factory::verify_dao(
                &validator_cap,
                &mut dao,
                verification_id_inner,
                string::utf8(b"https://verified.example.com"),
                true, // approved
                string::utf8(b""),
                &clock,
                ctx(&mut scenario),
            );

            test::return_shared(dao);
            test::return_to_address(ADMIN, validator_cap);
        };

        // Try to request verification again (should fail)
        test::next_tx(&mut scenario, USER);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let mut dao = test::take_shared<DAO>(&scenario);
            let payment = coin::mint_for_testing(
                fee::get_verification_fee(&fee_manager),
                ctx(&mut scenario),
            );
            let attestation_url = string::utf8(b"https://example.com/new-attestation");

            // This should fail with EALREADY_VERIFIED
            factory::request_verification(
                &mut fee_manager,
                payment,
                &mut dao,
                attestation_url,
                &clock,
                ctx(&mut scenario),
            );

            test::return_shared(fee_manager);
            test::return_shared(dao);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // Test 3: Test disabling DAO proposals
    #[test]
    fun test_disable_dao_proposals() {
        let mut scenario = test::begin(ADMIN);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        setup_with_dao(&mut scenario, &clock);

        // Disable proposals
        test::next_tx(&mut scenario, ADMIN);
        {
            let mut dao = test::take_shared<DAO>(&scenario);
            let owner_cap = test::take_from_address<FactoryOwnerCap>(&scenario, ADMIN);

            // Verify proposals are enabled initially
            assert!(dao::are_proposals_enabled(&dao), 0);

            factory::disable_dao_proposals(&mut dao, &owner_cap);

            // Verify proposals are now disabled
            assert!(!dao::are_proposals_enabled(&dao), 1);

            test::return_shared(dao);
            test::return_to_address(ADMIN, owner_cap);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // Test 4: Test verification rejection
    #[test]
    fun test_dao_verification_rejection() {
        let mut scenario = test::begin(ADMIN);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        setup_with_dao(&mut scenario, &clock);

        // Request verification
        test::next_tx(&mut scenario, USER);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let mut dao = test::take_shared<DAO>(&scenario);
            let payment = coin::mint_for_testing(
                fee::get_verification_fee(&fee_manager),
                ctx(&mut scenario),
            );
            let attestation_url = string::utf8(b"https://example.com/attestation");

            factory::request_verification(
                &mut fee_manager,
                payment,
                &mut dao,
                attestation_url,
                &clock,
                ctx(&mut scenario),
            );

            test::return_shared(fee_manager);
            test::return_shared(dao);
        };

        // Reject verification
        test::next_tx(&mut scenario, ADMIN);
        {
            let mut dao = test::take_shared<DAO>(&scenario);
            let validator_cap = test::take_from_address<ValidatorAdminCap>(&scenario, ADMIN);

            let verification_id = object::new(ctx(&mut scenario));
            let verification_id_inner = object::uid_to_inner(&verification_id);
            object::delete(verification_id);

            let reject_reason = string::utf8(b"Failed to meet standards");

            factory::verify_dao(
                &validator_cap,
                &mut dao,
                verification_id_inner,
                string::utf8(b"https://rejected.example.com"),
                false, // rejected
                reject_reason,
                &clock,
                ctx(&mut scenario),
            );

            // Verify DAO is not verified
            assert!(!dao::is_verification_pending(&dao), 0);
            assert!(!dao::is_verified(&dao), 1);

            test::return_shared(dao);
            test::return_to_address(ADMIN, validator_cap);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    // Test 5: Test parameter validation in create_dao
    #[test]
    #[expected_failure(abort_code = factory::ELongTradingTime)]
    fun test_create_dao_exceed_max_trading_time() {
        let mut scenario = test::begin(ADMIN);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        // Setup factory
        test::next_tx(&mut scenario, ADMIN);
        {
            let (treasury_cap_asset, metadata_asset) = coin::create_currency(
                asset_coin::create(),
                9,
                b"ASSET",
                b"Asset Coin",
                b"Test asset coin",
                option::some(sui::url::new_unsafe_from_bytes(b"https://test.com")),
                ctx(&mut scenario),
            );

            let (treasury_cap_stable, metadata_stable) = coin::create_currency(
                stable_coin::create(),
                9,
                b"STABLE",
                b"Stable Coin",
                b"Test stable coin",
                option::some(sui::url::new_unsafe_from_bytes(b"https://test.com")),
                ctx(&mut scenario),
            );

            factory::create_factory(ctx(&mut scenario));
            fee::create_fee_manager_for_testing(ctx(&mut scenario));

            transfer::public_transfer(treasury_cap_asset, ADMIN);
            transfer::public_transfer(treasury_cap_stable, ADMIN);
            transfer::public_share_object(metadata_asset);
            transfer::public_share_object(metadata_stable);
        };

        // Try to create a DAO with excessive trading period
        test::next_tx(&mut scenario, USER);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = coin::mint_for_testing(
                fee::get_dao_creation_fee(&fee_manager),
                ctx(&mut scenario),
            );
            let dao_name = std::ascii::string(TEST_DAO_NAME);
            let icon_url = std::ascii::string(TEST_DAO_URL);
            let asset_metadata = test::take_shared<CoinMetadata<ASSET_COIN>>(&scenario);
            let stable_metadata = test::take_shared<CoinMetadata<STABLE_COIN>>(&scenario);

            // Use trading period > MAX_TRADING_TIME (604_800_000)
            let excessive_trading_period = 604_800_000 + 1;

            factory::create_dao<ASSET_COIN, STABLE_COIN>(
                &mut factory,
                &mut fee_manager,
                payment,
                MIN_ASSET_AMOUNT,
                MIN_STABLE_AMOUNT,
                dao_name,
                icon_url,
                REVIEW_PERIOD_MS,
                excessive_trading_period, // This should cause failure
                &asset_metadata,
                &stable_metadata,
                60_000,
                300_000,
TWAP_INITIAL_OBSERVATION,
                TWAP_THRESHOLD,
                string::utf8(b"DAO description"),
                &clock,
                ctx(&mut scenario),
            );

            test::return_shared(factory);
            test::return_shared(fee_manager);
            test::return_shared(asset_metadata);
            test::return_shared(stable_metadata);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_init() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);

        test::next_tx(&mut scenario, ADMIN);
        {
            let factory = test::take_shared<Factory>(&scenario);
            assert!(factory::dao_count(&factory) == 0, 0);
            assert!(!factory::is_paused(&factory), 1);
            let fee_manager = test::take_shared<FeeManager>(&scenario);
            assert!(fee::get_dao_creation_fee(&fee_manager) == 10_000, 2);
            test::return_shared(factory);
            test::return_shared(fee_manager);

            assert!(test::has_most_recent_for_address<FactoryOwnerCap>(ADMIN), 3);
        };
        test::end(scenario);
    }

    #[test]
    fun test_withdraw_fees() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        let dao_fee = 10_000;

        test::next_tx(&mut scenario, USER);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = mint_sui(dao_fee, ctx(&mut scenario));
            let dao_name = std::ascii::string(TEST_DAO_NAME);
            let icon_url = std::ascii::string(TEST_DAO_URL);
            let asset_metadata = test::take_shared<CoinMetadata<ASSET_COIN>>(&scenario);
            let stable_metadata = test::take_shared<CoinMetadata<STABLE_COIN>>(&scenario);

            factory::create_dao<ASSET_COIN, STABLE_COIN>(
                &mut factory,
                &mut fee_manager,
                payment,
                MIN_ASSET_AMOUNT,
                MIN_STABLE_AMOUNT,
                dao_name,
                icon_url,
                REVIEW_PERIOD_MS,
                TRADING_PERIOD_MS,
                &asset_metadata,
                &stable_metadata,
                60_000,
                300_000,
TWAP_INITIAL_OBSERVATION,
                TWAP_THRESHOLD,
                string::utf8(b"DAO description"),
                &clock,
                ctx(&mut scenario),
            );
            test::return_shared(factory);
            test::return_shared(fee_manager);
            test::return_shared(asset_metadata);
            test::return_shared(stable_metadata);
        };

        test::next_tx(&mut scenario, ADMIN);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let cap = test::take_from_address<fee::FeeAdminCap>(&scenario, ADMIN);

            assert!(fee::get_sui_balance(&fee_manager) == dao_fee, 0);
            fee::withdraw_all_fees(&mut fee_manager, &cap, &clock, ctx(&mut scenario));

            test::return_shared(fee_manager);
            test::return_to_address(ADMIN, cap);
        };

        test::next_tx(&mut scenario, ADMIN);
        {
            let coin = test::take_from_address<Coin<SUI>>(&scenario, ADMIN);
            assert!(coin::value(&coin) == dao_fee, 1);
            test::return_to_address(ADMIN, coin);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_update_dao_creation_fee() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        test::next_tx(&mut scenario, ADMIN);
        {
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let fee_admin_cap = test::take_from_address<fee::FeeAdminCap>(&scenario, ADMIN);
            let new_fee = 30_000_000_000;

            fee::update_dao_creation_fee(
                &mut fee_manager,
                &fee_admin_cap,
                new_fee,
                &clock,
                ctx(&mut scenario),
            );

            assert!(fee::get_dao_creation_fee(&fee_manager) == new_fee, 0);

            test::return_shared(fee_manager);
            test::return_to_address(ADMIN, fee_admin_cap);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_toggle_pause() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);

        test::next_tx(&mut scenario, ADMIN);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let owner_cap = test::take_from_address<FactoryOwnerCap>(&scenario, ADMIN);

            assert!(!factory::is_paused(&factory), 0);
            factory::toggle_pause(&mut factory, &owner_cap);
            assert!(factory::is_paused(&factory), 1);

            test::return_shared(factory);
            test::return_to_address(ADMIN, owner_cap);
        };

        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = factory::EPaused)]
    fun test_create_dao_when_paused() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        // Pause the factory
        test::next_tx(&mut scenario, ADMIN);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let owner_cap = test::take_from_address<FactoryOwnerCap>(&scenario, ADMIN);
            factory::toggle_pause(&mut factory, &owner_cap);
            test::return_shared(factory);
            test::return_to_address(ADMIN, owner_cap);
        };

        // Try to create DAO
        test::next_tx(&mut scenario, USER);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = mint_sui(fee::get_dao_creation_fee(&fee_manager), ctx(&mut scenario));
            let dao_name = std::ascii::string(TEST_DAO_NAME);
            let icon_url = std::ascii::string(TEST_DAO_URL);
            let asset_metadata = test::take_shared<CoinMetadata<ASSET_COIN>>(&scenario);
            let stable_metadata = test::take_shared<CoinMetadata<STABLE_COIN>>(&scenario);

            factory::create_dao<ASSET_COIN, STABLE_COIN>(
                &mut factory,
                &mut fee_manager,
                payment,
                MIN_ASSET_AMOUNT,
                MIN_STABLE_AMOUNT,
                dao_name,
                icon_url,
                REVIEW_PERIOD_MS,
                TRADING_PERIOD_MS,
                &asset_metadata,
                &stable_metadata,
                60_000,
                300_000,
TWAP_INITIAL_OBSERVATION,
                TWAP_THRESHOLD,
                string::utf8(b"DAO description"),
                &clock,
                ctx(&mut scenario),
            );

            test::return_shared(factory);
            test::return_shared(fee_manager);
            test::return_shared(asset_metadata);
            test::return_shared(stable_metadata);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = fee::EInvalidPayment)]
    fun test_create_dao_invalid_payment() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        test::next_tx(&mut scenario, USER);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = mint_sui(10_000_000_000, ctx(&mut scenario)); // Wrong amount
            let dao_name = std::ascii::string(TEST_DAO_NAME);
            let icon_url = std::ascii::string(TEST_DAO_URL);
            let asset_metadata = test::take_shared<CoinMetadata<ASSET_COIN>>(&scenario);
            let stable_metadata = test::take_shared<CoinMetadata<STABLE_COIN>>(&scenario);

            factory::create_dao<ASSET_COIN, STABLE_COIN>(
                &mut factory,
                &mut fee_manager,
                payment,
                MIN_ASSET_AMOUNT,
                MIN_STABLE_AMOUNT,
                dao_name,
                icon_url,
                REVIEW_PERIOD_MS,
                TRADING_PERIOD_MS,
                &asset_metadata,
                &stable_metadata,
                60_000,
                300_000,
TWAP_INITIAL_OBSERVATION,
                TWAP_THRESHOLD,
                string::utf8(b"DAO description"),
                &clock,
                ctx(&mut scenario),
            );

            test::return_shared(factory);
            test::return_shared(fee_manager);
            test::return_shared(asset_metadata);
            test::return_shared(stable_metadata);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_create_dao() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        test::next_tx(&mut scenario, USER);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = mint_sui(fee::get_dao_creation_fee(&fee_manager), ctx(&mut scenario));
            let dao_name = std::ascii::string(TEST_DAO_NAME);
            let icon_url = std::ascii::string(TEST_DAO_URL);
            let asset_metadata = test::take_shared<CoinMetadata<ASSET_COIN>>(&scenario);
            let stable_metadata = test::take_shared<CoinMetadata<STABLE_COIN>>(&scenario);

            factory::create_dao<ASSET_COIN, STABLE_COIN>(
                &mut factory,
                &mut fee_manager,
                payment,
                MIN_ASSET_AMOUNT,
                MIN_STABLE_AMOUNT,
                dao_name,
                icon_url,
                REVIEW_PERIOD_MS,
                TRADING_PERIOD_MS,
                &asset_metadata,
                &stable_metadata,
                60_000,
                300_000,
TWAP_INITIAL_OBSERVATION,
                TWAP_THRESHOLD,
                string::utf8(b"DAO description"),
                &clock,
                ctx(&mut scenario),
            );

            assert!(factory::dao_count(&factory) == 1, 0);
            test::return_shared(factory);
            test::return_shared(fee_manager);
            test::return_shared(asset_metadata);
            test::return_shared(stable_metadata);
        };

        test::next_tx(&mut scenario, USER);
        {
            assert!(test::has_most_recent_shared<DAO>(), 1);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_dao_validation_happy_path() {
        let mut scenario = test::begin(ADMIN);
        setup(&mut scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));

        // First create a DAO as a user
        test::next_tx(&mut scenario, USER);
        {
            let mut factory = test::take_shared<Factory>(&scenario);
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let payment = mint_sui(fee::get_dao_creation_fee(&fee_manager), ctx(&mut scenario));
            let dao_name = std::ascii::string(TEST_DAO_NAME);
            let icon_url = std::ascii::string(TEST_DAO_URL);
            let asset_metadata = test::take_shared<CoinMetadata<ASSET_COIN>>(&scenario);
            let stable_metadata = test::take_shared<CoinMetadata<STABLE_COIN>>(&scenario);

            factory::create_dao<ASSET_COIN, STABLE_COIN>(
                &mut factory,
                &mut fee_manager,
                payment,
                MIN_ASSET_AMOUNT,
                MIN_STABLE_AMOUNT,
                dao_name,
                icon_url,
                REVIEW_PERIOD_MS,
                TRADING_PERIOD_MS,
                &asset_metadata,
                &stable_metadata,
                60_000,
                300_000,
TWAP_INITIAL_OBSERVATION,
                TWAP_THRESHOLD,
                string::utf8(b"DAO description"),
                &clock,
                ctx(&mut scenario),
            );

            test::return_shared(factory);
            test::return_shared(fee_manager);
            test::return_shared(asset_metadata);
            test::return_shared(stable_metadata);
        };

        // Now request verification as the user
        test::next_tx(&mut scenario, USER);
        {
            let factory = test::take_shared<Factory>(&scenario);
            let mut fee_manager = test::take_shared<FeeManager>(&scenario);
            let mut dao = test::take_shared<DAO>(&scenario);
            let payment = mint_sui(fee::get_verification_fee(&fee_manager), ctx(&mut scenario));
            let attestation_url = string::utf8(b"https://example.com/attestation");

            // Request verification
            factory::request_verification(
                &mut fee_manager,
                payment,
                &mut dao,
                attestation_url,
                &clock,
                ctx(&mut scenario),
            );

            // Verify the DAO is now pending verification
            assert!(dao::is_verification_pending(&dao), 1);
            assert!(!dao::is_verified(&dao), 2);
            assert!(
                dao::get_attestation_url(&dao) == &string::utf8(b"https://example.com/attestation"),
                3,
            );

            test::return_shared(factory);
            test::return_shared(fee_manager);
            test::return_shared(dao);
        };

        // Finally validate as admin
        // Finally validate as admin
        test::next_tx(&mut scenario, ADMIN);
        {
            let factory = test::take_shared<Factory>(&scenario);
            let mut dao = test::take_shared<DAO>(&scenario);
            let validator_cap = test::take_from_address<factory::ValidatorAdminCap>(
                &scenario,
                ADMIN,
            );

            // Get the verification ID from the previous request
            // We need to store this from the VerificationRequested event or generate a new one
            let verification_id = object::new(ctx(&mut scenario));
            let verification_id_inner = object::uid_to_inner(&verification_id);
            object::delete(verification_id);

            let new_attestation_url = string::utf8(b"https://example.com/final-attestation");
            let empty_reason = string::utf8(b"");

            factory::verify_dao(
                &validator_cap,
                &mut dao,
                verification_id_inner, // Use the ID type
                new_attestation_url, // attestation URL
                true, // verified status
                empty_reason, // reject reason
                &clock, // clock reference
                ctx(&mut scenario), // transaction context
            );

            // Verify final state
            assert!(!dao::is_verification_pending(&dao), 4);
            assert!(dao::is_verified(&dao), 5);
            assert!(
                dao::get_attestation_url(&dao) == &string::utf8(b"https://example.com/final-attestation"),
                6,
            );

            test::return_shared(factory);
            test::return_shared(dao);
            test::return_to_address(ADMIN, validator_cap);
        };

        clock::destroy_for_testing(clock);
        test::end(scenario);
    }
}
