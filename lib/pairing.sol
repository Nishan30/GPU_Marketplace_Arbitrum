// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24; // Compatible with common verifiers

library Pairing {
    struct G1Point {
        uint256 X;
        uint256 Y;
    }

    // Encoding of field elements is: X[0] * z + X[1]
    struct G2Point {
        uint256[2] X;
        uint256[2] Y;
    }

    /// @return the address of the alt_bn128 pairing check precompile.
    function pairingAddress() internal pure returns (address) {
        return address(0x08); // Precompile for bn254Pairing (alt_bn128)
    }

    /// @return true if the pairing equation e(p1[0], p2[0]) * e(p1[1], p2[1]) * ... * e(p1[n], p2[n]) = 1 holds.
    function pairingProd(G1Point[] memory p1, G2Point[] memory p2) internal view returns (bool) {
        require(p1.length == p2.length, "Pairing: input array length mismatch");
        uint256 inputSize = p1.length * 6; // Each G1 point is 2 uints, each G2 point is 4 uints
        uint256[] memory input = new uint256[](inputSize);
        for (uint256 i = 0; i < p1.length; i++) {
            input[i * 6 + 0] = p1[i].X;
            input[i * 6 + 1] = p1[i].Y;
            input[i * 6 + 2] = p2[i].X[0];
            input[i * 6 + 3] = p2[i].X[1];
            input[i * 6 + 4] = p2[i].Y[0];
            input[i * 6 + 5] = p2[i].Y[1];
        }
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // staticcall costs 700 gas.
            let success := staticcall(gas(), 8, input, mul(inputSize, 32), input, 32)
            // Use input memory as output memory as well.
            // We trust that the precompile is well-behaved and won't try to write more than 32 bytes.
            if success {
                success := mload(input) // Check the result (1 for success, 0 for failure)
            }
            // Revert if the call failed (i.e. out of gas, stack too deep)
            // or if the result is false.
            if iszero(success) {
                revert(0, 0)
            }
        }
        return true;
    }

    /// Convenience method for a single pairing check.
    /// @return true if e(p1, p2) == 1
    function pairing(G1Point memory p1, G2Point memory p2) internal view returns (bool) {
        G1Point[] memory p1Arr = new G1Point[](1);
        G2Point[] memory p2Arr = new G2Point[](1);
        p1Arr[0] = p1;
        p2Arr[0] = p2;
        return pairingProd(p1Arr, p2Arr);
    }
}