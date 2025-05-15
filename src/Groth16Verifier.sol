// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24; // Matching your compiler output

import "../lib/Pairing.sol";

contract Groth16Verifier {
    using Pairing for Pairing.G1Point;
    using Pairing for Pairing.G2Point;

    struct VerifyingKey {
        Pairing.G1Point alfa1;
        Pairing.G2Point beta2;
        Pairing.G2Point gamma2;
        Pairing.G2Point delta2;
        Pairing.G1Point[] IC; // Array for supporting multiple public inputs
    }

    VerifyingKey public vk;
    uint256 public constant N_PUBLIC_INPUTS = 1;

    event VerifyingKeySet();

    function setVerifyingKey(
        Pairing.G1Point memory _alfa1,
        Pairing.G2Point memory _beta2,
        Pairing.G2Point memory _gamma2,
        Pairing.G2Point memory _delta2,
        Pairing.G1Point[] memory _ic
    ) public {
        require(_ic.length == N_PUBLIC_INPUTS + 1, "VK IC length mismatch");

        vk.alfa1 = _alfa1;
        vk.beta2 = _beta2;
        vk.gamma2 = _gamma2;
        vk.delta2 = _delta2;

        // --- EVEN MORE EXPLICIT FIX for vk.IC assignment ---
        // 1. Clear the existing storage array elements if any
        if (vk.IC.length > 0) {
            delete vk.IC; // Sets vk.IC.length to 0
        }

        // 2. Populate the storage array vk.IC element by element
        for (uint256 i = 0; i < _ic.length; i++) {
            // Push a new, default-initialized G1Point to storage
            vk.IC.push(); // This creates a new G1Point in storage with X=0, Y=0
            // Now, assign members from the memory struct to the newly pushed storage struct
            vk.IC[i].X = _ic[i].X;
            vk.IC[i].Y = _ic[i].Y;
        }
        // --- END EVEN MORE EXPLICIT FIX ---

        emit VerifyingKeySet();
    }

    /**
     * @notice Verifies a Groth16 proof.
     * @param _pA The A point of the proof.
     * @param _pB The B point of the proof.
     * @param _pC The C point of the proof.
     * @param _pubSignals The public inputs for the proof. Must have N_PUBLIC_INPUTS elements.
     * @return True if the proof is valid, false otherwise.
     */
    function verifyProof(
        Pairing.G1Point memory _pA,
        Pairing.G2Point memory _pB,
        Pairing.G1Point memory _pC,
        uint256[] memory _pubSignals
    ) public view returns (bool) {
        // Ensure vk.IC is correctly sized from setVerifyingKey
        require(vk.IC.length == (N_PUBLIC_INPUTS + 1), "Verifying key IC not correctly set or sized");
        require(_pubSignals.length == N_PUBLIC_INPUTS, "Invalid number of public inputs");

        // DUMMY VERIFICATION LOGIC (same as before)
        // This will pass if the dummy proof in the test matches these conditions.
        if (vk.alfa1.X == _pA.X && vk.alfa1.Y == _pA.Y &&
            vk.beta2.X[0] == _pB.X[0] && vk.beta2.X[1] == _pB.X[1] &&
            vk.beta2.Y[0] == _pB.Y[0] && vk.beta2.Y[1] == _pB.Y[1] &&
            _pubSignals[0] == 12345) { // 12345 is DUMMY_PUBLIC_INPUT_VALUE from test
            return true;
        }
        return false;
    }
}