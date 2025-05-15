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
    Pairing.G1Point[] internal dummy_vk_ic;   // State variable (storage)

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

        // --- Setup Dummy Verifying Key (VK) ---
        dummy_vk_alfa1 = Pairing.G1Point(1, 2);
        dummy_vk_beta2 = Pairing.G2Point([uint256(3), 4], [uint256(5), 6]);
        dummy_vk_gamma2 = Pairing.G2Point([uint256(7), 8], [uint256(9), 10]);
        dummy_vk_delta2 = Pairing.G2Point([uint256(11), 12], [uint256(13), 14]);

        // --- CORRECTED INITIALIZATION for dummy_vk_ic (storage array) ---
        uint256 ic_length = verifier.N_PUBLIC_INPUTS() + 1;

        // Create a temporary memory array to hold the values
        Pairing.G1Point[] memory temp_ic = new Pairing.G1Point[](ic_length);
        temp_ic[0] = Pairing.G1Point(15, 16); // IC[0]
        if (ic_length > 1) { // Ensure we don't go out of bounds if N_PUBLIC_INPUTS is 0
            temp_ic[1] = Pairing.G1Point(17, 18); // IC[1]
        }
        // Populate further elements of temp_ic if ic_length > 2

        // Now, copy from the temporary memory array (temp_ic) to the storage array (dummy_vk_ic)
        // Clear dummy_vk_ic first if setUp could be called multiple times or if its length might change
        if (dummy_vk_ic.length > 0) {
            delete dummy_vk_ic;
        }
        for (uint256 i = 0; i < temp_ic.length; i++) {
            dummy_vk_ic.push(); // Create a new storage slot (default G1Point)
            dummy_vk_ic[i].X = temp_ic[i].X; // Assign X
            dummy_vk_ic[i].Y = temp_ic[i].Y; // Assign Y
        }
        // --- END CORRECTED INITIALIZATION ---

        vm.startPrank(owner);
        // Pass the now correctly populated storage array dummy_vk_ic to setVerifyingKey.
        // setVerifyingKey itself will copy this into its own internal storage `vk.IC`.
        verifier.setVerifyingKey(
            dummy_vk_alfa1,
            dummy_vk_beta2,
            dummy_vk_gamma2,
            dummy_vk_delta2,
            dummy_vk_ic // Passing the storage array from the test contract
        );
        vm.stopPrank();

        // --- Setup Dummy Proof & Public Signals ---
        dummy_pA = dummy_vk_alfa1;
        dummy_pB = dummy_vk_beta2;
        dummy_pC = Pairing.G1Point(19, 20);

        dummy_pubSignals = new uint256[](verifier.N_PUBLIC_INPUTS());
        if (verifier.N_PUBLIC_INPUTS() > 0) { // Guard against N_PUBLIC_INPUTS being 0
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

    function testFail_VerifyDummyProof_InvalidSignal_WithRealVerifierStructure() public view {
        uint256 numPubInputs = verifier.N_PUBLIC_INPUTS();
        uint256[] memory invalidPubSignals = new uint256[](numPubInputs);
        if (numPubInputs > 0) {
            invalidPubSignals[0] = DUMMY_PUBLIC_INPUT_VALUE + 1; // Make it different
             // Populate other signals if numPubInputs > 1
            for(uint i = 1; i < numPubInputs; ++i) invalidPubSignals[i] = DUMMY_PUBLIC_INPUT_VALUE;
        }


        bool success = verifier.verifyProof(
            dummy_pA,
            dummy_pB,
            dummy_pC,
            invalidPubSignals
        );
        assertFalse(success, "Proof with invalid signal should fail the simplified check");
    }

    function testFail_VerifyProof_WrongPA() public view {
        Pairing.G1Point memory wrongPA = Pairing.G1Point(dummy_vk_alfa1.X + 1, dummy_vk_alfa1.Y);
        bool success = verifier.verifyProof(
            wrongPA,
            dummy_pB,
            dummy_pC,
            dummy_pubSignals
        );
        assertFalse(success, "Proof with wrong pA should fail");
    }

    function testFail_VerifyProof_WrongNumberOfPublicInputs() public {
        uint256 expectedNumPubInputs = verifier.N_PUBLIC_INPUTS();
        uint256[] memory tooManyPubSignals = new uint256[](expectedNumPubInputs + 1); // One more than expected
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

    function testFail_VerifyDummyProof_NoVkSet() public {
        Groth16Verifier newVerifierWithRealStruct = new Groth16Verifier();
        uint256 numPubInputs = newVerifierWithRealStruct.N_PUBLIC_INPUTS();
        uint256[] memory pubSignalsForNewVerifier = new uint256[](numPubInputs);

        if (numPubInputs > 0) {
            pubSignalsForNewVerifier[0] = DUMMY_PUBLIC_INPUT_VALUE;
            for(uint i = 1; i < numPubInputs; ++i) pubSignalsForNewVerifier[i] = DUMMY_PUBLIC_INPUT_VALUE;
        }


        vm.expectRevert("Verifying key IC not correctly set or sized");
        newVerifierWithRealStruct.verifyProof(
            dummy_pA, // Using global dummy_pA etc. is fine for this test's purpose
            dummy_pB,
            dummy_pC,
            pubSignalsForNewVerifier
        );
    }
}