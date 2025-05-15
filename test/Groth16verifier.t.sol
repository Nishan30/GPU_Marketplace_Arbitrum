// test/Groth16Verifier.t.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24; // Match contracts

import "forge-std/Test.sol";
import "src/Groth16Verifier.sol"; // Your verifier
import "lib/Pairing.sol";        // The Pairing library

contract Groth16VerifierTest is Test {
    Groth16Verifier public verifier;
    address public owner = address(0x1);

    // --- Dummy Verifying Key components ---
    Pairing.G1Point public dummy_vk_alfa1;
    Pairing.G1Point[] internal dummy_vk_ic;

    Pairing.G2Point internal dummy_vk_beta2;
    Pairing.G2Point internal dummy_vk_gamma2;
    Pairing.G2Point internal dummy_vk_delta2;

    // --- Dummy proof components ---
    Pairing.G1Point public dummy_pA;
    Pairing.G1Point public dummy_pC;
    Pairing.G2Point internal dummy_pB;

    uint256[] public dummy_pubSignals;

    uint256 constant DUMMY_PUBLIC_INPUT_VALUE = 12345;

    function setUp() public {
        vm.startPrank(owner);
        verifier = new Groth16Verifier();
        vm.stopPrank();

        dummy_vk_alfa1 = Pairing.G1Point(1, 2);
        dummy_vk_beta2 = Pairing.G2Point([uint256(3), 4], [uint256(5), 6]);
        dummy_vk_gamma2 = Pairing.G2Point([uint256(7), 8], [uint256(9), 10]);
        dummy_vk_delta2 = Pairing.G2Point([uint256(11), 12], [uint256(13), 14]);

        uint256 ic_length = verifier.N_PUBLIC_INPUTS() + 1;
        Pairing.G1Point[] memory temp_ic = new Pairing.G1Point[](ic_length);
        temp_ic[0] = Pairing.G1Point(15, 16);
        if (ic_length > 1) {
            temp_ic[1] = Pairing.G1Point(17, 18);
        }

        if (dummy_vk_ic.length > 0) {
            delete dummy_vk_ic;
        }
        for (uint256 i = 0; i < temp_ic.length; i++) {
            dummy_vk_ic.push();
            dummy_vk_ic[i].X = temp_ic[i].X;
            dummy_vk_ic[i].Y = temp_ic[i].Y;
        }

        vm.startPrank(owner);
        verifier.setVerifyingKey(
            dummy_vk_alfa1,
            dummy_vk_beta2,
            dummy_vk_gamma2,
            dummy_vk_delta2,
            dummy_vk_ic
        );
        vm.stopPrank();

        dummy_pA = dummy_vk_alfa1;
        dummy_pB = dummy_vk_beta2;
        dummy_pC = Pairing.G1Point(19, 20);

        dummy_pubSignals = new uint256[](verifier.N_PUBLIC_INPUTS());
        if (verifier.N_PUBLIC_INPUTS() > 0) {
            dummy_pubSignals[0] = DUMMY_PUBLIC_INPUT_VALUE;
        }
    }

    function test_VerifyDummyProof_Valid_WithRealVerifierStructure() public view {
        bool success = verifier.verifyProof(
            dummy_pA,
            dummy_pB,
            dummy_pC,
            dummy_pubSignals
        );
        assertTrue(success, "Dummy proof should pass the simplified check in Groth16Verifier");
    }

    // FIX: Renamed test
    function test_VerifyDummyProof_InvalidSignal_ReturnsFalse() public view {
        uint256 numPubInputs = verifier.N_PUBLIC_INPUTS();
        uint256[] memory invalidPubSignals = new uint256[](numPubInputs);
        if (numPubInputs > 0) {
            invalidPubSignals[0] = DUMMY_PUBLIC_INPUT_VALUE + 1;
            for(uint i = 1; i < numPubInputs; ++i) invalidPubSignals[i] = DUMMY_PUBLIC_INPUT_VALUE; // Keep others same if they exist
        }

        bool success = verifier.verifyProof(
            dummy_pA,
            dummy_pB,
            dummy_pC,
            invalidPubSignals
        );
        assertFalse(success, "Proof with invalid signal should fail the simplified check");
    }

    // FIX: Renamed test
    function test_VerifyProof_WrongPA_ReturnsFalse() public view {
        Pairing.G1Point memory wrongPA = Pairing.G1Point(dummy_vk_alfa1.X + 1, dummy_vk_alfa1.Y);
        bool success = verifier.verifyProof(
            wrongPA,
            dummy_pB,
            dummy_pC,
            dummy_pubSignals
        );
        assertFalse(success, "Proof with wrong pA should fail");
    }

    // FIX: Renamed test
    function test_VerifyProof_WrongNumberOfPublicInputs_Reverts() public { // Marked as public, not view, because vm.expectRevert
        uint256 expectedNumPubInputs = verifier.N_PUBLIC_INPUTS();
        uint256[] memory tooManyPubSignals = new uint256[](expectedNumPubInputs + 1);
        for(uint i=0; i < tooManyPubSignals.length; ++i) {
            tooManyPubSignals[i] = DUMMY_PUBLIC_INPUT_VALUE;
        }

        vm.expectRevert("Invalid number of public inputs");
        verifier.verifyProof(
            dummy_pA,
            dummy_pB,
            dummy_pC,
            tooManyPubSignals
        );
    }

    // FIX: Renamed test
    function test_VerifyDummyProof_NoVkSet_Reverts() public { // Marked as public, not view, because vm.expectRevert
        Groth16Verifier newVerifierWithRealStruct = new Groth16Verifier();
        uint256 numPubInputs = newVerifierWithRealStruct.N_PUBLIC_INPUTS();
        uint256[] memory pubSignalsForNewVerifier = new uint256[](numPubInputs);

        if (numPubInputs > 0) {
            pubSignalsForNewVerifier[0] = DUMMY_PUBLIC_INPUT_VALUE;
            for(uint i = 1; i < numPubInputs; ++i) pubSignalsForNewVerifier[i] = DUMMY_PUBLIC_INPUT_VALUE;
        }

        vm.expectRevert("Verifying key IC not correctly set or sized");
        newVerifierWithRealStruct.verifyProof(
            dummy_pA,
            dummy_pB,
            dummy_pC,
            pubSignalsForNewVerifier
        );
    }
}