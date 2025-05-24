// script/DeployJobManager.s.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24; // Or your JobManager's pragma

import "forge-std/Script.sol";
import "forge-std/console.sol";
// Correct import path relative to the `src` directory defined in foundry.toml
import {JobManager} from "src/JobManager.sol";
// No need to import GPUCredit or ProviderRegistry if you're just using their addresses

contract DeployJobManager is Script {
    function run() external {
        // --- Configuration ---
        // Load addresses from .env or specify them directly
        // Option 1: Load from .env (Recommended)
        // Ensure these are set in your .env file for the target network
        address providerRegistryAddress = vm.envAddress("PROVIDER_REGISTRY_ADDRESS");
        address gpuCreditAddress = vm.envAddress("GPU_CREDIT_ADDRESS");
        address risc0VerifierRouterAddress = vm.envAddress("RISC0_VERIFIER_ROUTER_ADDRESS"); // Risc0 Router
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address initialAdmin = vm.envAddress("INITIAL_ADMIN_ADDRESS"); // Can be deployer or another admin

        // Basic checks for loaded environment variables
        if (deployerPrivateKey == 0) {
            revert("PRIVATE_KEY not set in .env");
        }
        if (providerRegistryAddress == address(0)) { // Adjust if you allow address(0) for no registry
            console.log("Warning: EXISTING_PROVIDER_REGISTRY_ADDRESS not set or is address(0).");
        }
        if (gpuCreditAddress == address(0)) {
            revert("EXISTING_GPU_CREDIT_ADDRESS not set or is address(0).");
        }
        if (risc0VerifierRouterAddress == address(0)) {
            revert("RISC0_VERIFIER_ROUTER_ADDRESS not set or is address(0).");
        }
         if (initialAdmin == address(0)) {
            initialAdmin = vm.addr(deployerPrivateKey); // Default to deployer if not set
            console.log("INITIAL_ADMIN_ADDRESS not set, defaulting to deployer: ", initialAdmin);
        }


        // Option 2: Hardcode addresses (Less flexible, use for quick tests if needed)
        // address providerRegistryAddress = 0xYourProviderRegistryAddress;
        // address gpuCreditAddress = 0xYourGPUCreditAddress;
        // address risc0VerifierRouterAddress = 0xYourRisc0VerifierRouterAddress; // Risc0 Router
        // uint256 deployerPrivateKey = 0xYourPrivateKey;
        // address initialAdmin = 0xYourAdminAddress; // Or vm.addr(deployerPrivateKey)

        console.log("Deploying JobManager with the following addresses:");
        console.log("  ProviderRegistry Address:", providerRegistryAddress);
        console.log("  GPUCredit (JobPaymentToken) Address:", gpuCreditAddress);
        console.log("  Risc0VerifierRouter Address:", risc0VerifierRouterAddress);
        console.log("  Initial Admin Address:", initialAdmin);
        console.log("  Deployer Address:", vm.addr(deployerPrivateKey));


        vm.startBroadcast(deployerPrivateKey);

        // Deploy JobManager
        JobManager jobManager = new JobManager(
            providerRegistryAddress,
            gpuCreditAddress,
            risc0VerifierRouterAddress,
            initialAdmin
        );
        console.log("JobManager deployed to:", address(jobManager));

        // --- Post-Deployment Setup for JobManager (if needed) ---
        // For example, if JobManager needs roles on ProviderRegistry and it wasn't done before,
        // AND if the deployer of this script has admin rights on ProviderRegistry.
        // This part assumes you have an instance of ProviderRegistry if you need to call it.
        // If ProviderRegistry is used (not address(0)) and you need to grant roles:
        if (providerRegistryAddress != address(0)) {
            // To call functions on an existing contract, you need its interface/contract type
            // Assuming ProviderRegistry.sol defines RATER_ROLE, SLASHER_ROLE, DEFAULT_ADMIN_ROLE
            // and the grantRole function.
            // You'd typically cast the address to the contract type:
            // ProviderRegistry registryInstance = ProviderRegistry(payable(providerRegistryAddress)); // If ProviderRegistry is imported

            // However, to grant roles, the msg.sender of grantRole must have DEFAULT_ADMIN_ROLE on registry.
            // The deployerPrivateKey used here might or might not be the admin of the existing ProviderRegistry.
            // It's often cleaner to do role granting in a separate script or transaction by the actual admin of ProviderRegistry.

            // If the deployer of this script IS the admin of ProviderRegistry:
            // console.log("Attempting to grant RATER_ROLE to JobManager on ProviderRegistry...");
            // registryInstance.grantRole(registryInstance.RATER_ROLE(), address(jobManager));
            // console.log("JobManager granted RATER_ROLE on ProviderRegistry.");
            // Note: The above lines for granting roles need ProviderRegistry contract type imported and instantiated.
            // For simplicity, if roles are already granted or will be handled by ProviderRegistry admin, omit this.
            console.log("Skipping role grant for JobManager on ProviderRegistry in this script. Ensure it's done if needed.");
        }


        vm.stopBroadcast();

        console.log("\n--- JobManager Deployment Complete ---");
        console.log("JOB_MANAGER_ADDRESS=", address(jobManager));
    }
}