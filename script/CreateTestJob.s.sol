// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {JobManager} from "src/JobManager.sol";      // Adjust path if needed
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol"; // For GPUCredit interaction

contract CreateTestJob is Script {
    JobManager public jobManager;
    IERC20 public gpuCreditToken;

    // Amounts
    uint256 constant PAYMENT_AMOUNT_GPU_CREDIT = 100 * 10**18; // Example: 100 GPUCredits (assuming 18 decimals)

    function setUp() public {
        // Load JobManager address
        string memory jobManagerAddressStr = vm.envString("JOB_MANAGER_ADDRESS");
        if (bytes(jobManagerAddressStr).length == 0) revert("JOB_MANAGER_ADDRESS not in .env");
        address jobManagerAddr = vm.parseAddress(jobManagerAddressStr);
        jobManager = JobManager(jobManagerAddr);
        console.log("Attached to JobManager at:", address(jobManager));

        // Load GPUCredit token address
        string memory gpuCreditAddressStr = vm.envString("GPU_CREDIT_ADDRESS");
        if (bytes(gpuCreditAddressStr).length == 0) revert("GPU_CREDIT_ADDRESS not in .env");
        address gpuCreditAddr = vm.parseAddress(gpuCreditAddressStr);
        gpuCreditToken = IERC20(gpuCreditAddr);
        console.log("Attached to GPUCredit token at:", address(gpuCreditToken));
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        if (deployerPrivateKey == 0) revert("DEPLOYER_PRIVATE_KEY not in .env");
        address sender = vm.addr(deployerPrivateKey);
        console.log("Using account:", sender, "to send transactions.");

        // --- Job Parameters ---
        string memory cid = "QmbWqxBEKC3P8tqsKc98xmWNzrzDtRLMiMPL8wBuTGsMnR";
        // The `reward` parameter in your createJob function is named `_paymentAmountGPUCredit`
        uint256 deadline = block.timestamp + 1 hours;

        console.log("Preparing to create job with CID:", cid);
        console.log("Payment Amount (GPUCredit):", PAYMENT_AMOUNT_GPU_CREDIT);
        console.log("Deadline (timestamp):", deadline);

        // --- Approve and Create Job ---
        vm.startBroadcast(deployerPrivateKey);

        // 1. Approve the JobManager contract to spend sender's GPUCredit tokens
        // Check current allowance (optional, for debugging)
        uint256 currentAllowance = gpuCreditToken.allowance(sender, address(jobManager));
        console.log("Current allowance for JobManager:", currentAllowance);

        if (currentAllowance < PAYMENT_AMOUNT_GPU_CREDIT) {
            // If allowance is insufficient, approve.
            // Some tokens require resetting allowance to 0 first if changing non-zero to non-zero.
            // For simplicity, assuming standard ERC20 behavior or sufficient initial allowance.
            // To be safe, you might do `approve(address(jobManager), 0)` then `approve(address(jobManager), PAYMENT_AMOUNT_GPU_CREDIT)`
            // or just set a high enough approval once.
            bool approved = gpuCreditToken.approve(address(jobManager), PAYMENT_AMOUNT_GPU_CREDIT);
            if (!approved) {
                // Note: approve usually doesn't return bool in older OZ, but can.
                // Modern OZ approve returns void. Check your IERC20 if it has a bool return for approve.
                // If it's void, just call it. The transaction will revert on failure.
                console.log("Approval might have failed or returns void. Assuming success if no revert.");
            } else {
                 console.log("Successfully approved JobManager to spend", PAYMENT_AMOUNT_GPU_CREDIT, "GPUCredits.");
            }
            // It's good practice to wait for the approval transaction to be mined in a real scenario,
            // but in a script, Foundry often handles this sequencing correctly within a broadcast.
        } else {
            console.log("Sufficient allowance already exists for JobManager.");
        }


        // 2. Call createJob on JobManager (NO {value: ...} here)
        // The parameters must match your JobManager.sol's createJob signature:
        // function createJob(string memory _jobDataCID, uint256 _paymentAmountGPUCredit, uint256 _deadlineTimestamp)
        (uint256 jobId) = jobManager.createJob(cid, PAYMENT_AMOUNT_GPU_CREDIT, deadline);

        vm.stopBroadcast();

        console.log("Job creation transaction sent!");
        console.log("New Job ID:", jobId);
        console.log("Waiting for event in coordinator service (check its logs)...");
    }
}