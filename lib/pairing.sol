// lib/Pairing.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0; // Can be ^0.8.24 as well

library Pairing {
    struct G1Point {
        uint256 X;
        uint256 Y;
    }

    struct G2Point {
        uint256[2] X;
        uint256[2] Y;
    }

    uint256 private constant FIELD_PRIME = 0x30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47;

    // --- Precompile Addresses (still useful for documentation/Solidity code) ---
    // address private constant ECADD_ADDR = address(0x06); // Not used directly in assembly
    // address private constant ECMUL_ADDR = address(0x07); // Not used directly in assembly
    // address private constant ECPAIRING_ADDR = address(0x08); // Not used directly in assembly

    function add(G1Point memory p1, G1Point memory p2) internal view returns (G1Point memory r) {
        uint256[4] memory input;
        input[0] = p1.X;
        input[1] = p1.Y;
        input[2] = p2.X;
        input[3] = p2.Y;
        bool success;
        assembly {
            // FIX: Use literal 0x06 for ECADD address
            success := staticcall(gas(), 0x06, input, 0x80, r, 0x40)
        }
        require(success, "Pairing: ECADD failed");
    }

    function scalar_mul(G1Point memory p, uint256 s) internal view returns (G1Point memory r) {
        uint256[3] memory input;
        input[0] = p.X;
        input[1] = p.Y;
        input[2] = s;
        bool success;
        assembly {
            // FIX: Use literal 0x07 for ECMUL address
            success := staticcall(gas(), 0x07, input, 0x60, r, 0x40)
        }
        require(success, "Pairing: ECMUL failed");
    }

    function negate(G1Point memory p) internal pure returns (G1Point memory) {
        if (p.Y == 0) {
            return G1Point(p.X, 0);
        }
        return G1Point(p.X, FIELD_PRIME - p.Y);
    }
    
    function negate(G2Point memory p) internal pure returns (G2Point memory r) {
        r.X = p.X; 
        if (p.Y[0] == 0) { r.Y[0] = 0; } else { r.Y[0] = FIELD_PRIME - p.Y[0]; }
        if (p.Y[1] == 0) { r.Y[1] = 0; } else { r.Y[1] = FIELD_PRIME - p.Y[1]; }
        return r; // Ensure r is returned
    }

    function pairingProd(G1Point[] memory p1Array, G2Point[] memory p2Array) internal view returns (bool result) {
        require(p1Array.length == p2Array.length, "Pairing: arrays must be same length");
        uint256 numPairings = p1Array.length;
        if (numPairings == 0) {
            return true;
        }

        uint256 inputSizeWords = numPairings * 6;
        uint256[] memory input = new uint256[](inputSizeWords);

        for (uint256 i = 0; i < numPairings; ) {
            uint256 j = i * 6;
            input[j + 0] = p1Array[i].X;
            input[j + 1] = p1Array[i].Y;
            input[j + 2] = p2Array[i].X[0]; 
            input[j + 3] = p2Array[i].X[1]; 
            input[j + 4] = p2Array[i].Y[0]; 
            input[j + 5] = p2Array[i].Y[1]; 
            unchecked { ++i; } 
        }

        uint256 success; // Solidity-level variable to capture success of staticcall
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // FIX: Use literal 0x08 for ECPAIRING address
            let callSuccess := staticcall(gas(), 0x08, add(input, 0x20), mul(inputSizeWords, 0x20), 0x00, 0x20)
            success := callSuccess // Assign to Solidity variable
            if callSuccess { // Only mload if staticcall succeeded
                result := mload(0x00) 
            }
        }
        require(success == 1, "Pairing: ECPAIRING precompile call failed");
        // result is already true (1) or false (0) from mload if success == 1
        // if success == 0, result remains its default (false/0), and require above will catch it.
        return result; 
    }

    function pairingProd4(
        G1Point memory p1_1, G2Point memory p2_1,
        G1Point memory p1_2, G2Point memory p2_2,
        G1Point memory p1_3, G2Point memory p2_3,
        G1Point memory p1_4, G2Point memory p2_4
    ) internal view returns (bool) {
        G1Point[] memory p1Array = new G1Point[](4);
        G2Point[] memory p2Array = new G2Point[](4);

        p1Array[0] = p1_1; p2Array[0] = p2_1;
        p1Array[1] = p1_2; p2Array[1] = p2_2;
        p1Array[2] = p1_3; p2Array[2] = p2_3;
        p1Array[3] = p1_4; p2Array[3] = p2_4;

        return pairingProd(p1Array, p2Array);
    }
}