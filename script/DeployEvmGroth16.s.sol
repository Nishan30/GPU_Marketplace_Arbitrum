// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "src/Verifier.sol";

contract DeployEvmGroth16 is Script {
    function run() external {
        vm.startBroadcast();
        new Verifier();
        vm.stopBroadcast();
    }
}
