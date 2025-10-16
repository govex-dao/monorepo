#[test_only]
module account_protocol::bcs_validation_tests;

use account_protocol::bcs_validation;
use sui::bcs;

// === Error Constants ===
// NOTE: Error code must match the one in bcs_validation.move
const ETrailingActionData: u64 = 0;

// For expected_failure tests, we need to specify the module where the error originates
// Format: ModuleAddress::ModuleName::ERROR_CODE

// === Happy Path Tests ===

#[test]
fun test_validate_all_bytes_consumed_empty_vector() {
    // Create BCS reader from empty vector
    let empty_vec = vector::empty<u8>();
    let reader = bcs::new(empty_vec);

    // Should pass - no bytes to consume
    bcs_validation::validate_all_bytes_consumed(reader);
}

#[test]
fun test_validate_all_bytes_consumed_fully_consumed_u64() {
    // Serialize a u64
    let value: u64 = 42;
    let bytes = bcs::to_bytes(&value);

    // Create reader and consume all bytes
    let mut reader = bcs::new(bytes);
    let _consumed = bcs::peel_u64(&mut reader);

    // Should pass - all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);
}

#[test]
fun test_validate_all_bytes_consumed_fully_consumed_vector() {
    // Serialize a vector
    let vec = vector[1u8, 2, 3, 4, 5];
    let bytes = bcs::to_bytes(&vec);

    // Create reader and consume all bytes
    let mut reader = bcs::new(bytes);
    let _consumed = bcs::peel_vec_u8(&mut reader);

    // Should pass - all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);
}

#[test]
fun test_validate_all_bytes_consumed_multiple_fields() {
    // Serialize multiple values
    let value1: u64 = 100;
    let value2: u8 = 42;
    let value3: bool = true;

    let mut bytes = vector::empty<u8>();
    bytes.append(bcs::to_bytes(&value1));
    bytes.append(bcs::to_bytes(&value2));
    bytes.append(bcs::to_bytes(&value3));

    // Create reader and consume all bytes
    let mut reader = bcs::new(bytes);
    let _v1 = bcs::peel_u64(&mut reader);
    let _v2 = bcs::peel_u8(&mut reader);
    let _v3 = bcs::peel_bool(&mut reader);

    // Should pass - all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);
}

#[test]
fun test_validate_all_bytes_consumed_string() {
    // Serialize a string (as vector<u8>)
    let text = b"hello world";
    let bytes = bcs::to_bytes(&text);

    // Create reader and consume all bytes
    let mut reader = bcs::new(bytes);
    let _consumed = bcs::peel_vec_u8(&mut reader);

    // Should pass - all bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);
}

// === Error Path Tests ===

#[test]
#[expected_failure(abort_code = account_protocol::bcs_validation::ETrailingActionData)]
fun test_validate_fails_with_trailing_u64() {
    // Serialize two u64s
    let value1: u64 = 100;
    let value2: u64 = 200;

    let mut bytes = vector::empty<u8>();
    bytes.append(bcs::to_bytes(&value1));
    bytes.append(bcs::to_bytes(&value2));

    // Create reader and only consume first u64
    let mut reader = bcs::new(bytes);
    let _v1 = bcs::peel_u64(&mut reader);

    // Should abort - trailing bytes remaining
    bcs_validation::validate_all_bytes_consumed(reader);
}

#[test]
#[expected_failure(abort_code = account_protocol::bcs_validation::ETrailingActionData)]
fun test_validate_fails_with_extra_bytes() {
    // Create bytes with extra trailing data
    let value: u64 = 42;
    let mut bytes = bcs::to_bytes(&value);

    // Append malicious extra bytes
    bytes.push_back(0xDE);
    bytes.push_back(0xAD);
    bytes.push_back(0xBE);
    bytes.push_back(0xEF);

    // Create reader and consume only the u64
    let mut reader = bcs::new(bytes);
    let _consumed = bcs::peel_u64(&mut reader);

    // Should abort - trailing bytes remaining
    bcs_validation::validate_all_bytes_consumed(reader);
}

#[test]
#[expected_failure(abort_code = account_protocol::bcs_validation::ETrailingActionData)]
fun test_validate_fails_with_single_trailing_byte() {
    // Serialize a u64
    let value: u64 = 123;
    let mut bytes = bcs::to_bytes(&value);

    // Add one extra byte
    bytes.push_back(0xFF);

    // Create reader and consume only the u64
    let mut reader = bcs::new(bytes);
    let _consumed = bcs::peel_u64(&mut reader);

    // Should abort - 1 trailing byte remaining
    bcs_validation::validate_all_bytes_consumed(reader);
}

#[test]
#[expected_failure(abort_code = account_protocol::bcs_validation::ETrailingActionData)]
fun test_validate_fails_with_partially_consumed_vector() {
    // Serialize two vectors
    let vec1 = vector[1u8, 2, 3];
    let vec2 = vector[4u8, 5, 6];

    let mut bytes = vector::empty<u8>();
    bytes.append(bcs::to_bytes(&vec1));
    bytes.append(bcs::to_bytes(&vec2));

    // Create reader and consume only first vector
    let mut reader = bcs::new(bytes);
    let _v1 = bcs::peel_vec_u8(&mut reader);

    // Should abort - second vector not consumed
    bcs_validation::validate_all_bytes_consumed(reader);
}

#[test]
#[expected_failure(abort_code = account_protocol::bcs_validation::ETrailingActionData)]
fun test_validate_fails_no_consumption() {
    // Create BCS reader with data
    let value: u64 = 999;
    let bytes = bcs::to_bytes(&value);
    let reader = bcs::new(bytes);

    // Don't consume any bytes

    // Should abort - all bytes are trailing
    bcs_validation::validate_all_bytes_consumed(reader);
}

// === Security Attack Simulation Tests ===

#[test]
#[expected_failure(abort_code = account_protocol::bcs_validation::ETrailingActionData)]
fun test_security_attack_action_payload_tampering() {
    // Simulate an action with recipient and amount
    let recipient = @0x1234;
    let amount: u64 = 1000;

    // Serialize the legitimate action
    let mut action_bytes = vector::empty<u8>();
    action_bytes.append(bcs::to_bytes(&recipient));
    action_bytes.append(bcs::to_bytes(&amount));

    // Attacker appends extra data (e.g., trying to inject another transfer)
    let malicious_recipient = @0xBAD;
    let malicious_amount: u64 = 999999;
    action_bytes.append(bcs::to_bytes(&malicious_recipient));
    action_bytes.append(bcs::to_bytes(&malicious_amount));

    // Action handler deserializes only what it expects
    let mut reader = bcs::new(action_bytes);
    let _r = bcs::peel_address(&mut reader);
    let _a = bcs::peel_u64(&mut reader);

    // Validation catches the malicious trailing data
    bcs_validation::validate_all_bytes_consumed(reader);
}

#[test]
#[expected_failure(abort_code = account_protocol::bcs_validation::ETrailingActionData)]
fun test_security_attack_parameter_injection() {
    // Legitimate action: set_config(key, value)
    let key = b"max_supply";
    let value: u64 = 1000000;

    let mut bytes = vector::empty<u8>();
    bytes.append(bcs::to_bytes(&key));
    bytes.append(bcs::to_bytes(&value));

    // Attacker appends extra parameter hoping to execute additional logic
    let injected_param: bool = true;
    bytes.append(bcs::to_bytes(&injected_param));

    // Deserialize expected parameters
    let mut reader = bcs::new(bytes);
    let _k = bcs::peel_vec_u8(&mut reader);
    let _v = bcs::peel_u64(&mut reader);

    // Validation prevents the injection attack
    bcs_validation::validate_all_bytes_consumed(reader);
}

// === Edge Case Tests ===

#[test]
fun test_validate_zero_length_vector_consumed() {
    // Serialize and consume a zero-length vector
    let empty_vec = vector::empty<u8>();
    let bytes = bcs::to_bytes(&empty_vec);

    let mut reader = bcs::new(bytes);
    let _consumed = bcs::peel_vec_u8(&mut reader);

    // Should pass
    bcs_validation::validate_all_bytes_consumed(reader);
}

#[test]
fun test_validate_large_data_fully_consumed() {
    // Create a large vector
    let mut large_vec = vector::empty<u8>();
    let mut i = 0;
    while (i < 1000) {
        large_vec.push_back((i % 256) as u8);
        i = i + 1;
    };

    let bytes = bcs::to_bytes(&large_vec);
    let mut reader = bcs::new(bytes);
    let _consumed = bcs::peel_vec_u8(&mut reader);

    // Should pass - all 1000 bytes consumed
    bcs_validation::validate_all_bytes_consumed(reader);
}

#[test]
#[expected_failure(abort_code = account_protocol::bcs_validation::ETrailingActionData)]
fun test_validate_large_data_with_one_trailing_byte() {
    // Create a large vector
    let mut large_vec = vector::empty<u8>();
    let mut i = 0;
    while (i < 1000) {
        large_vec.push_back((i % 256) as u8);
        i = i + 1;
    };

    let mut bytes = bcs::to_bytes(&large_vec);

    // Add one trailing byte to large payload
    bytes.push_back(0x99);

    let mut reader = bcs::new(bytes);
    let _consumed = bcs::peel_vec_u8(&mut reader);

    // Should abort - even one trailing byte is caught
    bcs_validation::validate_all_bytes_consumed(reader);
}
