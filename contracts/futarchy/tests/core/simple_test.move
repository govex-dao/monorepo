#[test_only]
module futarchy::simple_test;

#[test]
fun test_basic_math() {
    assert!(1 + 1 == 2, 0);
}

#[test]
#[expected_failure(abort_code = 1)]
fun test_expected_failure() {
    assert!(1 + 1 == 3, 1);
}