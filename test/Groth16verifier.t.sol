// test/Groth16Verifier.t.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0; // Match contracts

import "forge-std/Test.sol";
import "src/Groth16Verifier.sol"; // Your verifier
import "lib/Pairing.sol";        // The Pairing library

contract Groth16VerifierTest is Test {
    Groth16Verifier public verifier;
    address public owner = address(0x1);

    // Dummy Verifying Key components that will make our dummy proof "valid"
    Pairing.G1Point public dummy_vk_alfa1;
    Pairing.G2Point public dummy_vk_beta2;
    Pairing.G2Point public dummy_vk_gamma2;
    Pairing.G2Point public dummy_vk_delta2;
    Pairing.G1Point[] public dummy_vk_ic; // For N_PUBLIC_INPUTS = 1, needs 2 elements

    // Dummy proof components
    Pairing.G1Point public dummy_pA;
    Pairing.G2Point public dummy_pB;
    Pairing.G1Point public dummy_pC;
    uint256[] public dummy_pubSignals;

    uint256 constant DUMMY_PUBLIC_INPUT_VALUE = 12345;

    function setUp() public {
        vm.startPrank(owner);
        verifier = new Groth16Verifier();
        vm.stopPrank();

        // --- Setup Dummy Verifying Key (VK) ---
        // These are just arbitrary non-zero values for G1 and G2 points.
        // In reality, these come from a trusted setup for a specific circuit.
        dummy_vk_alfa1 = Pairing.G1Point(1, 2);
        dummy_vk_beta2 = Pairing.G2Point([uint256(3), 4], [uint256(5), 6]);
        dummy_vk_gamma2 = Pairing.G2Point([uint256(7), 8], [uint256(9), 10]);
        dummy_vk_delta2 = Pairing.G2Point([uint256(11), 12], [uint256(13), 14]);

        // For N_PUBLIC_INPUTS = 1, vk.IC needs 2 G1 points (IC[0] and IC[1])
        dummy_vk_ic = new Pairing.G1Point[](Groth16Verifier.N_PUBLIC_INPUTS + 1);
        dummy_vk_ic[0] = Pairing.G1Point(15, 16); // IC[0]
        dummy_vk_ic[1] = Pairing.G1Point(17, 18); // IC[1] (coefficient for publicSignals[0])

        vm.startPrank(owner);
        verifier.setVerifyingKey(
            dummy_vk_alfa1,
            dummy_vk_beta2,
            dummy_vk_gamma2,
            dummy_vk_delta2,
            dummy_vk_ic
        );
        vm.stopPrank();


        // --- Setup Dummy Proof & Public Signals to satisfy the DUMMY verifyProof logic ---
        // To pass our DUMMY verifyProof:
        // _pA must equal vk.alfa1
        // _pB must equal vk.beta2
        // _pubSignals[0] must equal DUMMY_PUBLIC_INPUT_VALUE (12345)
        dummy_pA = dummy_vk_alfa1; // pA = alfa1
        dummy_pB = dummy_vk_beta2; // pB = beta2

        // _pC can be anything for our DUMMY check as it's not used in the simplified pass condition
        dummy_pC = Pairing.G1Point(19, 20);

        dummy_pubSignals = new uint256[](Groth16Verifier.N_PUBLIC_INPUTS);
        dummy_pubSignals[0] = DUMMY_PUBLIC_INPUT_VALUE;
    }

    function test_VerifyDummyProof_Valid_WithRealVerifierStructure() public {
        bool success = verifier.verifyProof(
            dummy_pA,
            dummy_pB,
            dummy_pC,
            dummy_pubSignals
        );
        assertTrue(success, "Dummy proof should pass the simplified check in Groth16Verifier");
    }

    function testFail_VerifyDummyProof_InvalidSignal_WithRealVerifierStructure() public {
        uint256[] memory invalidPubSignals = new uint256[](Groth16Verifier.N_PUBLIC_INPUTS);
        invalidPubSignals[0] = DUMMY_PUBLIC_INPUT_VALUE + 1; // Make it different

        bool success = verifier.verifyProof(
            dummy_pA,
            dummy_pB,
            dummy_pC,
            invalidPubSignals
        );
        assertFalse(success, "Proof with invalid signal should fail the simplified check");
    }

    function testFail_VerifyProof_WrongPA() public {
        Pairing.G1Point memory wrongPA = Pairing.G1Point(dummy_vk_alfa1.X + 1, dummy_vk_alfa1.Y);
        bool success = verifier.verifyProof(
            wrongPA, // Different pA
            dummy_pB,
            dummy_pC,
            dummy_pubSignals
        );
        assertFalse(success, "Proof with wrong pA should fail");
    }

     function testFail_VerifyProof_WrongNumberOfPublicInputs() public {
        uint256[] memory tooManyPubSignals = new uint256[](Groth16Verifier.N_PUBLIC_INPUTS + 1);
        for(uint i=0; i < tooManyPubSignals.length; ++i) tooManyPubSignals[i] = DUMMY_PUBLIC_INPUT_VALUE;

        vm.expectRevert("Invalid number of public inputs");
        verifier.verifyProof(
            dummy_pA,
            dummy_pB,
            dummy_pC,
            tooManyPubSignals
        );
    }
}