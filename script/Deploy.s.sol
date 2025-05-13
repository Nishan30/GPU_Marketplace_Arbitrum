// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
// Correct import paths relative to the `src` directory defined in foundry.toml
import {GPUCredit} from "src/GPUCredit.sol";
import {ProviderRegistry} from "src/ProviderRegistry.sol";

contract DeployContracts is Script {
    function run() external {
        // vm.envString("...") or vm.envUint("...") etc. to load from .env
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        // It's good practice to check if env var is loaded
        if (deployerPrivateKey == 0) {
            revert("PRIVATE_KEY not set in .env");
        }

        address admin = vm.addr(deployerPrivateKey); // Derive address from private key
        // You might want different addresses for slasher/rater, or set them later
        address initialSlasher = admin; // Example: admin is also initial slasher
        address initialRater = admin;   // Example: admin is also initial rater

        vm.startBroadcast(deployerPrivateKey);

        // Deploy GPUCredit token
        GPUCredit gpuCredit = new GPUCredit("GPU Credit Test", "GPCT");
        console.log("GPUCredit deployed to:", address(gpuCredit));

        // Deploy ProviderRegistry, passing the GPUCredit token address
        ProviderRegistry registry = new ProviderRegistry(address(gpuCredit), admin, initialSlasher, initialRater);
        console.log("ProviderRegistry deployed to:", address(registry));

        // Example: Set slashed funds recipient if different from admin
        // address someOtherRecipient = address(0x...); // Replace with actual address
        // registry.setSlashedFundsRecipient(someOtherRecipient);
        // console.log("Slashed funds recipient set to:", someOtherRecipient);

        vm.stopBroadcast();
    }
}