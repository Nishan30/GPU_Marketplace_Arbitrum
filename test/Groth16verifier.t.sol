// test/Groth16Verifier.t.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "src/Groth16Verifier.sol"; // We need this for N_PUBLIC_INPUTS and other tests
import "lib/Pairing.sol";        // We need this for G1Point/G2Point structs

contract Groth16VerifierTest is Test {
    Groth16Verifier public verifier; // Keep for other tests that pass
    address public owner = address(0x1);

    Pairing.G1Point G1_GENERATOR_PT; // Renamed to avoid conflict with any G1_GENERATOR keyword
    Pairing.G2Point G2_GENERATOR_PT;

    // Other dummy variables for tests that are passing or will be fixed later
    Pairing.G1Point dummy_vk_alfa1;
    Pairing.G1Point[] internal dummy_vk_ic_storage;
    Pairing.G2Point dummy_vk_beta2;
    Pairing.G2Point dummy_vk_gamma2;
    Pairing.G2Point dummy_vk_delta2;
    Pairing.G1Point dummy_pA; 
    Pairing.G1Point dummy_pC; 
    Pairing.G2Point dummy_pB; 
    uint256[] public dummy_pubSignals; 
    uint256 constant DUMMY_PUBLIC_INPUT_VALUE = 12345; 


    function setUp() public {
        // Initialize G1_GENERATOR_PT and G2_GENERATOR_PT
        G1_GENERATOR_PT = Pairing.G1Point(1, 2);
        G2_GENERATOR_PT = Pairing.G2Point(
            [0x1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed, 0x198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2],
            [0x12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa, 0x090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b]
        );

        // Setup for other tests (those that are passing)
        vm.startPrank(owner);
        verifier = new Groth16Verifier();
        vm.stopPrank();

        dummy_vk_alfa1 = G1_GENERATOR_PT;
        dummy_vk_beta2 = G2_GENERATOR_PT;
        dummy_vk_gamma2 = G2_GENERATOR_PT; 
        dummy_vk_delta2 = G2_GENERATOR_PT;

        uint256 ic_length = verifier.N_PUBLIC_INPUTS() + 1;
        Pairing.G1Point[] memory temp_ic = new Pairing.G1Point[](ic_length);
        for (uint256 i = 0; i < ic_length; i++) {
            temp_ic[i] = G1_GENERATOR_PT; 
        }
        if (dummy_vk_ic_storage.length > 0) { delete dummy_vk_ic_storage; }
        for (uint256 i = 0; i < temp_ic.length; i++) { dummy_vk_ic_storage.push(temp_ic[i]); }

        vm.startPrank(owner);
        verifier.setVerifyingKey( temp_ic, dummy_vk_alfa1, dummy_vk_beta2, dummy_vk_gamma2, dummy_vk_delta2 );
        vm.stopPrank();

        dummy_pA = G1_GENERATOR_PT; 
        dummy_pC = G1_GENERATOR_PT; 
        dummy_pB = G2_GENERATOR_PT; 
        dummy_pubSignals = new uint256[](verifier.N_PUBLIC_INPUTS());
        if (verifier.N_PUBLIC_INPUTS() > 0) {
            dummy_pubSignals[0] = DUMMY_PUBLIC_INPUT_VALUE;
        }
    }

    // THIS IS THE MOST IMPORTANT TEST NOW
    function test_BareBonesDirectPrecompileCall() public view {
        uint256[] memory input_arr = new uint256[](6);
        // G1 (1,2)
        input_arr[0] = 1;
        input_arr[1] = 2;
        // G2 Generator
        input_arr[2] = 0x1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed; // X.c0
        input_arr[3] = 0x198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2; // X.c1
        input_arr[4] = 0x12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa; // Y.c0
        input_arr[5] = 0x090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b; // Y.c1

        uint256 pairing_result_val = 0; 
        uint256 call_status_val = 0;    
        uint256 input_data_size_bytes = 192; // 6 * 32
        uint256 gas_to_forward = 100000; // Sufficient for 1 pairing

        assembly {
            let input_ptr := add(input_arr, 0x20) 
            let success_flag := staticcall(gas_to_forward, 8, input_ptr, input_data_size_bytes, 0x00, 0x20) 
            call_status_val := success_flag
            if success_flag {
                pairing_result_val := mload(0x00)
            }
        }
        
        assertTrue(call_status_val == 1, "BareBones: staticcall to pairing precompile failed");
        assertFalse(pairing_result_val == 1, "BareBones: e(G1_gen, G2_gen) should not be 1"); 
    }

    // --- Other tests (keep them as they were if some were passing) ---

    function test_VerifyProof_ExecutesWithDummyData() public view {
        bool ok = verifier.verifyProof(dummy_pA, dummy_pB, dummy_pC, dummy_pubSignals);
        assertFalse(ok, "Dummy proof should fail the full cryptographic check");
    }

    function test_VerifyProof_InvalidSignal_ReturnsFalse() public view {
        uint256 n = verifier.N_PUBLIC_INPUTS();
        uint256[] memory wrongSig = new uint256[](n);
        if (n > 0) {
            wrongSig[0] = DUMMY_PUBLIC_INPUT_VALUE + 7; 
            for (uint i = 1; i < n; ++i) wrongSig[i] = dummy_pubSignals[i];
        }
        bool ok = verifier.verifyProof(dummy_pA, dummy_pB, dummy_pC, wrongSig);
        assertFalse(ok, "Proof with invalid signal should fail crypto check");
    }

    function test_VerifyProof_WrongPA_ReturnsFalse() public view {
        Pairing.G1Point memory badA = Pairing.G1Point(G1_GENERATOR_PT.X + 10, G1_GENERATOR_PT.Y); 
        bool ok = verifier.verifyProof(badA, dummy_pB, dummy_pC, dummy_pubSignals);
        assertFalse(ok, "Proof with wrong pA should fail crypto check");
    }

    function test_VerifyProof_WrongNumberOfPublicInputs_Reverts() public {
        uint256 n = verifier.N_PUBLIC_INPUTS();
        uint256[] memory tooMany = new uint256[](n + 1);
        for (uint256 i = 0; i < tooMany.length; i++) {
            tooMany[i] = DUMMY_PUBLIC_INPUT_VALUE;
        }
        vm.expectRevert("Invalid number of public inputs");
        verifier.verifyProof(dummy_pA, dummy_pB, dummy_pC, tooMany);
    }

    function test_VerifyProof_NoVkSet_Reverts() public {
        Groth16Verifier fresh = new Groth16Verifier();
        uint256 n = fresh.N_PUBLIC_INPUTS();
        uint256[] memory sigs = new uint256[](n);
        if (n > 0) sigs[0] = DUMMY_PUBLIC_INPUT_VALUE;
        
        vm.expectRevert("Verifying key IC not set or sized correctly");
        fresh.verifyProof(dummy_pA, dummy_pB, dummy_pC, sigs);
    }

    function test_SetVerifyingKey_Success() public view {
        (
            Pairing.G1Point memory a_vk, Pairing.G2Point memory b_vk, Pairing.G2Point memory c_vk,
            Pairing.G2Point memory d_vk, Pairing.G1Point[] memory ic_vk
        ) = verifier.getVerifyingKey();

        assertEq(a_vk.X, dummy_vk_alfa1.X);
        assertEq(a_vk.Y, dummy_vk_alfa1.Y);
        assertEq(b_vk.X[0], dummy_vk_beta2.X[0]);
        assertEq(ic_vk.length, verifier.N_PUBLIC_INPUTS() + 1);
        if (ic_vk.length > 0) { 
            assertEq(ic_vk[0].X, G1_GENERATOR_PT.X);
        }
    }

    function test_SetVerifyingKey_ICLengthMismatch_Reverts() public {
        uint256 correctLen = verifier.N_PUBLIC_INPUTS() + 1;
        Pairing.G1Point[] memory wrongLenIc = new Pairing.G1Point[](correctLen + 1);
        for(uint i=0; i < wrongLenIc.length; ++i) wrongLenIc[i] = G1_GENERATOR_PT;

        vm.startPrank(owner);
        vm.expectRevert("VK IC length mismatch");
        verifier.setVerifyingKey(wrongLenIc, dummy_vk_alfa1, dummy_vk_beta2, dummy_vk_gamma2, dummy_vk_delta2);
        vm.stopPrank();
    }
}