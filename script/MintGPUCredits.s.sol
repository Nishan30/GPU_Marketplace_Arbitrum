// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {GPUCredit} from "src/GPUCredit.sol"; // Adjust path

contract MintGPUCredits is Script {
    GPUCredit public gpuCreditToken;
    address public recipient;
    uint256 public mintAmount = 200 * 10**18; // Mint 200 tokens

    function setUp() public {
        string memory gpuCreditAddressStr = vm.envString("GPU_CREDIT_ADDRESS");
        if (bytes(gpuCreditAddressStr).length == 0) revert("GPU_CREDIT_ADDRESS not in .env");
        address gpuCreditAddr = vm.parseAddress(gpuCreditAddressStr);
        gpuCreditToken = GPUCredit(gpuCreditAddr); // Cast to GPUCredit to access mint

        // Get recipient from private key (could be same as deployer or another address)
        uint256 recipientPrivateKey = vm.envUint("PRIVATE_KEY"); // Or use DEPLOYER_PRIVATE_KEY
        if (recipientPrivateKey == 0) revert("RECIPIENT_PRIVATE_KEY not in .env");
        recipient = vm.addr(recipientPrivateKey);
    }

    // In MintGPUCredits.s.sol run()
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address minterAccount = vm.addr(deployerPrivateKey);

        console.log("Checking MINTER_ROLE for account:", minterAccount);
        bool hasMinterRole = gpuCreditToken.hasRole(gpuCreditToken.MINTER_ROLE(), minterAccount);
        console.log("Account has MINTER_ROLE:", hasMinterRole);

        if (!hasMinterRole) {
            console.log("Error: Account does not have MINTER_ROLE. Cannot mint.");
            // You could revert here or just let the mint call fail.
            // For debugging, it's good to see this log.
        }

        console.log("Minter Account:", minterAccount);
        console.log("Minting", mintAmount, "GPUCredits to", recipient);

        vm.startBroadcast(deployerPrivateKey);
        gpuCreditToken.mint(recipient, mintAmount);
        vm.stopBroadcast();

        console.log("Minting complete.");
        uint256 balance = gpuCreditToken.balanceOf(recipient);
        console.log("New balance of", recipient, "is", balance);
    }
}