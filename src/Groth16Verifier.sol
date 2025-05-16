// src/Groth16Verifier.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../lib/Pairing.sol"; // Your NEW, complete Pairing.sol

contract Groth16Verifier {
    using Pairing for Pairing.G1Point;
    using Pairing for Pairing.G2Point;

    struct VerifyingKey {
        Pairing.G1Point alfa1;
        Pairing.G2Point beta2;
        Pairing.G2Point gamma2;
        Pairing.G2Point delta2;
        Pairing.G1Point[] IC;
    }

    VerifyingKey public vk;
    uint256 public constant N_PUBLIC_INPUTS = 1; // Keep as 1 for current tests

    event VerifyingKeySet();
    // event VerificationResult(bool result); // Optional for debugging, remove for production view

    function setVerifyingKey(
        Pairing.G1Point[] memory _icArray, 
        Pairing.G1Point memory _alfa1,
        Pairing.G2Point memory _beta2,
        Pairing.G2Point memory _gamma2,
        Pairing.G2Point memory _delta2
    ) public { // TODO: Add access control
        require(_icArray.length == N_PUBLIC_INPUTS + 1, "VK IC length mismatch");

        vk.alfa1 = _alfa1;
        vk.beta2 = _beta2;
        vk.gamma2 = _gamma2;
        vk.delta2 = _delta2;

        delete vk.IC; // Clear existing IC if any
        for (uint256 i = 0; i < _icArray.length; i++) {
            vk.IC.push(_icArray[i]);
        }

        emit VerifyingKeySet();
    }

    function getVerifyingKey()
        external
        view
        returns (
            Pairing.G1Point memory alfa1,
            Pairing.G2Point memory beta2,
            Pairing.G2Point memory gamma2,
            Pairing.G2Point memory delta2,
            Pairing.G1Point[] memory IC
        )
    {
        alfa1 = vk.alfa1;
        beta2 = vk.beta2;
        gamma2 = vk.gamma2;
        delta2 = vk.delta2;
        IC     = vk.IC;
    }

    function verifyProof(
        Pairing.G1Point memory _pA,
        Pairing.G2Point memory _pB,
        Pairing.G1Point memory _pC,
        uint256[] memory _pubSignals
    ) public view returns (bool) {
        require(vk.IC.length == N_PUBLIC_INPUTS + 1, "Verifying key IC not set or sized correctly");
        require(_pubSignals.length == N_PUBLIC_INPUTS, "Invalid number of public inputs");

        // Compute linear combination: vk.IC[0] + sum(vk.IC[i+1] * _pubSignals[i])
        Pairing.G1Point memory sumIC = vk.IC[0]; // This copies from storage to memory
        for (uint256 i = 0; i < _pubSignals.length; i++) {
            // vk.IC[i+1] is a storage point. When used with .scalar_mul, Solidity should handle it.
            // The `using Pairing for Pairing.G1Point` allows these member-like calls.
            sumIC = sumIC.add(vk.IC[i + 1].scalar_mul(_pubSignals[i]));
        }

        // Groth16 verification equation:
        // e(A, B) == e(alpha1, beta2) * e(sumIC, gamma2) * e(C, delta2)
        // Check: e(A, B) * e(alpha1, -beta2) * e(sumIC, -gamma2) * e(C, -delta2) == 1
        // Use the pairingProd4 from the new library that takes individual points
        bool success = Pairing.pairingProd4(
            _pA, _pB,                           // e(A,B)
            vk.alfa1, vk.beta2.negate(),        // e(alfa1, -beta2)
            sumIC, vk.gamma2.negate(),          // e(sumIC, -gamma2)
            _pC, vk.delta2.negate()             // e(C, -delta2)
        );
        // emit VerificationResult(success); // Remove emit from view function
        return success;
    }
}