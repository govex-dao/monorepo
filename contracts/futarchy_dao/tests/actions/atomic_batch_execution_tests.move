/// Tests for atomic batch execution of actions using composable entry functions
#[test_only]
module futarchy::atomic_batch_execution_tests;

// === Test 1: Module compiles ===

#[test]
fun test_module_compiles() {
    // Simplest possible test - just verify the test module compiles
    assert!(true, 0);
}
