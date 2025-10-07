/// Comprehensive tests for descriptor_analyzer.move
/// Tests approval requirement analysis and approval checking logic
#[test_only]
module futarchy_multisig::descriptor_analyzer_tests {
    use std::option;
    use sui::object;
    use sui::test_utils::assert_eq;
    use futarchy_multisig::descriptor_analyzer;

    // === ApprovalRequirement Structure Tests ===

    #[test]
    fun test_check_approvals_dao_only() {
        let requirement = create_test_requirement(
            true,  // needs_dao
            false, // needs_council
            option::none(),
            0  // DAO_ONLY mode
        );

        // DAO approved = OK
        assert!(descriptor_analyzer::check_approvals(&requirement, true, false));

        // DAO not approved = FAIL
        assert!(!descriptor_analyzer::check_approvals(&requirement, false, false));

        // Council approval doesn't matter for DAO_ONLY
        assert!(descriptor_analyzer::check_approvals(&requirement, true, true));
        assert!(!descriptor_analyzer::check_approvals(&requirement, false, true));
    }

    #[test]
    fun test_check_approvals_council_only() {
        let requirement = create_test_requirement(
            false, // needs_dao
            true,  // needs_council
            option::some(object::id_from_address(@0x123)),
            1  // COUNCIL_ONLY mode
        );

        // Council approved = OK
        assert!(descriptor_analyzer::check_approvals(&requirement, false, true));

        // Council not approved = FAIL
        assert!(!descriptor_analyzer::check_approvals(&requirement, false, false));

        // DAO approval doesn't matter for COUNCIL_ONLY
        assert!(descriptor_analyzer::check_approvals(&requirement, true, true));
        assert!(!descriptor_analyzer::check_approvals(&requirement, true, false));
    }

    #[test]
    fun test_check_approvals_dao_or_council() {
        let requirement = create_test_requirement(
            true, // needs_dao
            true, // needs_council
            option::some(object::id_from_address(@0x123)),
            2  // DAO_OR_COUNCIL mode
        );

        // DAO approved alone = OK
        assert!(descriptor_analyzer::check_approvals(&requirement, true, false));

        // Council approved alone = OK
        assert!(descriptor_analyzer::check_approvals(&requirement, false, true));

        // Both approved = OK
        assert!(descriptor_analyzer::check_approvals(&requirement, true, true));

        // Neither approved = FAIL
        assert!(!descriptor_analyzer::check_approvals(&requirement, false, false));
    }

    #[test]
    fun test_check_approvals_dao_and_council() {
        let requirement = create_test_requirement(
            true, // needs_dao
            true, // needs_council
            option::some(object::id_from_address(@0x123)),
            3  // DAO_AND_COUNCIL mode
        );

        // Both approved = OK
        assert!(descriptor_analyzer::check_approvals(&requirement, true, true));

        // Only DAO approved = FAIL
        assert!(!descriptor_analyzer::check_approvals(&requirement, true, false));

        // Only Council approved = FAIL
        assert!(!descriptor_analyzer::check_approvals(&requirement, false, true));

        // Neither approved = FAIL
        assert!(!descriptor_analyzer::check_approvals(&requirement, false, false));
    }

    #[test]
    fun test_check_approvals_invalid_mode() {
        let requirement = create_test_requirement(
            true,
            true,
            option::some(object::id_from_address(@0x123)),
            4  // Invalid mode
        );

        // Invalid mode should return false for all combinations
        assert!(!descriptor_analyzer::check_approvals(&requirement, true, true));
        assert!(!descriptor_analyzer::check_approvals(&requirement, true, false));
        assert!(!descriptor_analyzer::check_approvals(&requirement, false, true));
        assert!(!descriptor_analyzer::check_approvals(&requirement, false, false));
    }

    // === Getter Tests ===

    #[test]
    fun test_needs_dao_getter() {
        let req_true = create_test_requirement(true, false, option::none(), 0);
        assert_eq(descriptor_analyzer::needs_dao(&req_true), true);

        let req_false = create_test_requirement(false, true, option::none(), 1);
        assert_eq(descriptor_analyzer::needs_dao(&req_false), false);
    }

    #[test]
    fun test_needs_council_getter() {
        let req_true = create_test_requirement(false, true, option::none(), 1);
        assert_eq(descriptor_analyzer::needs_council(&req_true), true);

        let req_false = create_test_requirement(true, false, option::none(), 0);
        assert_eq(descriptor_analyzer::needs_council(&req_false), false);
    }

    #[test]
    fun test_council_id_getter() {
        let test_id = object::id_from_address(@0xABC);

        let req_with_id = create_test_requirement(
            false,
            true,
            option::some(test_id),
            1
        );
        let council_id_opt = descriptor_analyzer::council_id(&req_with_id);
        assert!(council_id_opt.is_some());
        assert_eq(*council_id_opt.borrow(), test_id);

        let req_without_id = create_test_requirement(true, false, option::none(), 0);
        let council_id_opt2 = descriptor_analyzer::council_id(&req_without_id);
        assert!(council_id_opt2.is_none());
    }

    #[test]
    fun test_mode_getter() {
        let req0 = create_test_requirement(true, false, option::none(), 0);
        assert_eq(descriptor_analyzer::mode(&req0), 0);

        let req1 = create_test_requirement(false, true, option::none(), 1);
        assert_eq(descriptor_analyzer::mode(&req1), 1);

        let req2 = create_test_requirement(true, true, option::none(), 2);
        assert_eq(descriptor_analyzer::mode(&req2), 2);

        let req3 = create_test_requirement(true, true, option::none(), 3);
        assert_eq(descriptor_analyzer::mode(&req3), 3);
    }

    // === Edge Case Tests ===

    #[test]
    fun test_mode_0_needs_dao_true() {
        // Mode 0 (DAO_ONLY) should have needs_dao = true
        let requirement = create_test_requirement(true, false, option::none(), 0);
        assert_eq(descriptor_analyzer::needs_dao(&requirement), true);
        assert_eq(descriptor_analyzer::mode(&requirement), 0);
    }

    #[test]
    fun test_mode_2_needs_both() {
        // Mode 2 (DAO_OR) should have needs_dao = true
        let requirement = create_test_requirement(true, true, option::some(object::id_from_address(@0x1)), 2);
        assert_eq(descriptor_analyzer::needs_dao(&requirement), true);
        assert_eq(descriptor_analyzer::needs_council(&requirement), true);
        assert_eq(descriptor_analyzer::mode(&requirement), 2);
    }

    #[test]
    fun test_mode_3_needs_both() {
        // Mode 3 (DAO_AND) should have needs_dao = true
        let requirement = create_test_requirement(true, true, option::some(object::id_from_address(@0x1)), 3);
        assert_eq(descriptor_analyzer::needs_dao(&requirement), true);
        assert_eq(descriptor_analyzer::needs_council(&requirement), true);
        assert_eq(descriptor_analyzer::mode(&requirement), 3);
    }

    #[test]
    fun test_all_mode_combinations() {
        // Test all 4 modes with all 4 approval combinations
        let modes = vector[0u8, 1u8, 2u8, 3u8];
        let approval_combos = vector[
            (false, false),
            (false, true),
            (true, false),
            (true, true),
        ];

        let mut i = 0;
        while (i < modes.length()) {
            let mode = *modes.borrow(i);
            let needs_dao = (mode == 0 || mode == 2 || mode == 3);
            let needs_council = (mode != 0);

            let requirement = create_test_requirement(
                needs_dao,
                needs_council,
                if (needs_council) { option::some(object::id_from_address(@0x1)) } else { option::none() },
                mode
            );

            let mut j = 0;
            while (j < approval_combos.length()) {
                let (dao_approved, council_approved) = *approval_combos.borrow(j);

                let expected = if (mode == 0) {
                    dao_approved
                } else if (mode == 1) {
                    council_approved
                } else if (mode == 2) {
                    dao_approved || council_approved
                } else if (mode == 3) {
                    dao_approved && council_approved
                } else {
                    false
                };

                let actual = descriptor_analyzer::check_approvals(
                    &requirement,
                    dao_approved,
                    council_approved
                );

                assert_eq(actual, expected);

                j = j + 1;
            };

            i = i + 1;
        };
    }

    #[test]
    fun test_different_council_ids() {
        let id1 = object::id_from_address(@0xABC);
        let id2 = object::id_from_address(@0xDEF);

        let req1 = create_test_requirement(false, true, option::some(id1), 1);
        let req2 = create_test_requirement(false, true, option::some(id2), 1);

        assert!(*descriptor_analyzer::council_id(&req1).borrow() != *descriptor_analyzer::council_id(&req2).borrow());
    }

    // === Helper Functions ===

    fun create_test_requirement(
        needs_dao: bool,
        needs_council: bool,
        council_id: option::Option<object::ID>,
        mode: u8
    ): descriptor_analyzer::ApprovalRequirement {
        // Create via the module's logic since we can't construct directly
        // This is a workaround - in reality we'd use analyze_requirements
        // For now, we'll create requirements that match the expected behavior

        // Note: Since ApprovalRequirement doesn't have a public constructor,
        // we need to work with the module's actual functions
        // For these unit tests, we're testing the logic functions with known requirements

        // Create a dummy requirement using internal constructor pattern
        use futarchy_multisig::descriptor_analyzer::ApprovalRequirement;
        ApprovalRequirement {
            needs_dao,
            needs_council,
            council_id,
            mode,
        }
    }
}
