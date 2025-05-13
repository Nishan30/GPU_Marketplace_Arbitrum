// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "src/GPUCredit.sol";        // Adjust path if needed
import "src/ProviderRegistry.sol"; // Adjust path if needed
import "src/JobManager.sol";       // Adjust path if needed
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract JobManagerTest is Test {
    // --- Contracts ---
    GPUCredit public gpuCredit;
    ProviderRegistry public registry;
    JobManager public jobManager;

    // --- Users ---
    address public admin = address(0x1);
    address public client1 = address(0x2);
    address public provider1 = address(0x3);
    address public provider2 = address(0x4);
    address public stranger = address(0x5); // An unprivileged user
    address public slashedFundsRecipient; // For registry

    // --- Constants ---
    uint256 constant INITIAL_MINT_AMOUNT = 1_000_000 * 1e18; // For each user
    uint256 constant PROVIDER_STAKE_AMOUNT = 1000 * 1e18;
    uint256 constant JOB_PAYMENT_AMOUNT = 100 * 1e18;
    uint256 constant MIN_STAKE_FOR_JOB = 500 * 1e18;
    uint256 constant ONE_DAY_IN_SECONDS = 1 days; // Foundry's time units

    // --- Setup ---
    function setUp() public {
        // Deployer / Admin
        vm.startPrank(admin);

        // 1. Deploy GPUCredit
        gpuCredit = new GPUCredit("Test GPU Credit", "TGPUC");

        // 2. Deploy ProviderRegistry
        // For simplicity, admin is also initial slasher/rater here.
        // These roles might be transferred or granted to jobManager if needed.
        slashedFundsRecipient = address(0x6); // Dummy recipient
        registry = new ProviderRegistry(address(gpuCredit), admin, admin, admin);
        registry.setSlashedFundsRecipient(slashedFundsRecipient);

        // 3. Deploy JobManager
        jobManager = new JobManager(address(registry), address(gpuCredit), admin);

        // 4. Grant necessary roles to JobManager on ProviderRegistry
        // JobManager needs RATER_ROLE to call registry.rate()
        registry.grantRole(registry.RATER_ROLE(), address(jobManager));
        // If JobManager were to call registry.slash(), it would need SLASHER_ROLE
        // registry.grantRole(registry.SLASHER_ROLE(), address(jobManager));

        // 5. Mint GPUCredit to users
        gpuCredit.mint(client1, INITIAL_MINT_AMOUNT);
        gpuCredit.mint(provider1, INITIAL_MINT_AMOUNT);
        gpuCredit.mint(provider2, INITIAL_MINT_AMOUNT);

        vm.stopPrank(); // End admin prank

        // 6. Providers approve registry and stake GPUCredit
        vm.startPrank(provider1);
        gpuCredit.approve(address(registry), PROVIDER_STAKE_AMOUNT);
        registry.stake(PROVIDER_STAKE_AMOUNT);
        vm.stopPrank();

        vm.startPrank(provider2);
        gpuCredit.approve(address(registry), PROVIDER_STAKE_AMOUNT);
        registry.stake(PROVIDER_STAKE_AMOUNT);
        vm.stopPrank();

        // 7. Client1 approves JobManager to spend a large amount of GPUCredit for multiple tests
        vm.startPrank(client1);
        gpuCredit.approve(address(jobManager), type(uint256).max); // Infinite approval for testing convenience
        vm.stopPrank();
    }

    // --- Utility Functions ---
    function _createTestJob(address _client, uint256 _payment, uint256 _deadlineOffset) internal returns (uint256 jobId) {
        vm.startPrank(_client);
        jobId = jobManager.createJob("ipfs://test_job_data_cid", _payment, block.timestamp + _deadlineOffset);
        vm.stopPrank();
    }

    // --- Test createJob ---
    function test_CreateJob_Success() public {
        uint256 initialClientBalance = gpuCredit.balanceOf(client1);
        uint256 initialJobManagerBalance = gpuCredit.balanceOf(address(jobManager));
        uint256 deadline = block.timestamp + ONE_DAY_IN_SECONDS;
        string memory cid = "ipfs://job_cid_1";

        vm.startPrank(client1);
        vm.expectEmit(true, true, true, true); // Check indexed and non-indexed
        emit JobCreated(0, client1, cid, JOB_PAYMENT_AMOUNT, deadline);
        uint256 jobId = jobManager.createJob(cid, JOB_PAYMENT_AMOUNT, deadline);
        vm.stopPrank();

        assertEq(jobId, 0, "Job ID should be 0");
        JobManager.Job memory job = jobManager.getJob(jobId);
        assertEq(job.client, client1, "Job client mismatch");
        assertEq(job.jobDataCID, cid, "Job CID mismatch");
        assertEq(job.maxPaymentGPUCredit, JOB_PAYMENT_AMOUNT, "Job payment mismatch");
        assertEq(job.deadlineTimestamp, deadline, "Job deadline mismatch");
        assertEq(uint8(job.status), uint8(JobManager.JobStatus.Created), "Job status mismatch");
        assertEq(job.provider, address(0), "Job provider should be zero initially");

        assertEq(gpuCredit.balanceOf(client1), initialClientBalance - JOB_PAYMENT_AMOUNT, "Client balance incorrect");
        assertEq(gpuCredit.balanceOf(address(jobManager)), initialJobManagerBalance + JOB_PAYMENT_AMOUNT, "JobManager balance incorrect");
    }

    function testFail_CreateJob_NoApproval() public {
        // Client2 (stranger) has tokens but hasn't approved jobManager
        vm.startPrank(admin);
        gpuCredit.mint(stranger, JOB_PAYMENT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(stranger);
        vm.expectRevert(bytes("ERC20: insufficient allowance")); // Or a more generic TokenTransferFailed if OZ wraps it.
        jobManager.createJob("ipfs://no_approval_cid", JOB_PAYMENT_AMOUNT, block.timestamp + ONE_DAY_IN_SECONDS);
        vm.stopPrank();
    }

    function testFail_CreateJob_ZeroPayment() public {
        vm.startPrank(client1);
        vm.expectRevert(JobManager.EscrowAmountZero.selector);
        jobManager.createJob("ipfs://zero_payment_cid", 0, block.timestamp + ONE_DAY_IN_SECONDS);
        vm.stopPrank();
    }

    function testFail_CreateJob_DeadlineInPast() public {
        vm.startPrank(client1);
        vm.expectRevert(JobManager.DeadlineMustBeInFuture.selector);
        jobManager.createJob("ipfs://past_deadline_cid", JOB_PAYMENT_AMOUNT, block.timestamp - 1 seconds);
        vm.stopPrank();
    }

    // --- Test acceptJob ---
    function test_AcceptJob_Success() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);

        vm.startPrank(provider1);
        vm.expectEmit(true, true, false, false); // Only indexed params for JobAccepted
        emit JobAccepted(jobId, provider1);
        jobManager.acceptJob(jobId);
        vm.stopPrank();

        JobManager.Job memory job = jobManager.getJob(jobId);
        assertEq(job.provider, provider1, "Job provider mismatch");
        assertEq(uint8(job.status), uint8(JobManager.JobStatus.Accepted), "Job status should be Accepted");
    }

    function testFail_AcceptJob_NotRegisteredProvider() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        // Stranger is not staked in ProviderRegistry
        vm.startPrank(stranger);
        vm.expectRevert(JobManager.ProviderNotRegisteredOrInsufficientStake.selector);
        jobManager.acceptJob(jobId);
        vm.stopPrank();
    }

    function testFail_AcceptJob_InsufficientStake() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);

        vm.startPrank(admin);
        jobManager.setMinProviderStakeRequired(PROVIDER_STAKE_AMOUNT + 1); // Set higher than provider1's stake
        vm.stopPrank();

        vm.startPrank(provider1);
        vm.expectRevert(JobManager.ProviderNotRegisteredOrInsufficientStake.selector);
        jobManager.acceptJob(jobId);
        vm.stopPrank();
    }

    function testFail_AcceptJob_NotCreatedStatus() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManager.acceptJob(jobId); // Job is now Accepted

        vm.startPrank(provider2); // Another provider tries to accept
        vm.expectRevert(JobManager.InvalidJobStatus.selector);
        jobManager.acceptJob(jobId);
        vm.stopPrank();
    }

    function testFail_AcceptJob_DeadlinePassed() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, 1 seconds); // Short deadline
        vm.warp(block.timestamp + 2 seconds); // Fast forward time

        vm.startPrank(provider1);
        vm.expectRevert(JobManager.DeadlinePassed.selector);
        jobManager.acceptJob(jobId);
        vm.stopPrank();
    }

    // --- Test submitJobResult ---
    function test_SubmitJobResult_Success() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManager.acceptJob(jobId);

        string memory resultCID = "ipfs://result_cid";
        vm.startPrank(provider1); // The assigned provider
        vm.expectEmit(true, true, false, false);
        emit JobResultSubmitted(jobId, provider1, resultCID);
        jobManager.submitJobResult(jobId, resultCID);
        vm.stopPrank();

        JobManager.Job memory job = jobManager.getJob(jobId);
        assertEq(job.resultDataCID, resultCID, "Result CID mismatch");
        assertEq(uint8(job.status), uint8(JobManager.JobStatus.ResultSubmitted), "Job status should be ResultSubmitted");
    }

    function testFail_SubmitJobResult_NotAssignedProvider() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManager.acceptJob(jobId); // provider1 accepted

        vm.startPrank(provider2); // provider2 tries to submit
        vm.expectRevert(JobManager.OnlyAssignedProviderCanSubmit.selector);
        jobManager.submitJobResult(jobId, "ipfs://wrong_provider_result");
        vm.stopPrank();
    }

    function testFail_SubmitJobResult_NotAcceptedStatus() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        // Job is still in Created status

        vm.startPrank(provider1); // Even if it were the intended provider
        vm.expectRevert(JobManager.InvalidJobStatus.selector);
        jobManager.submitJobResult(jobId, "ipfs://not_accepted_result");
        vm.stopPrank();
    }

    function testFail_SubmitJobResult_DeadlinePassedAndRated() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, 1 seconds); // Short deadline
        vm.prank(provider1);
        jobManager.acceptJob(jobId);

        vm.warp(block.timestamp + 2 seconds); // Fast forward time past deadline

        ProviderRegistry.ProviderInfo memory pInfoBefore = registry.getProviderInfo(provider1);

        vm.startPrank(provider1);
        // Expect provider to be rated negatively
        vm.expectCall(
            address(registry),
            abi.encodeWithSelector(ProviderRegistry.rate.selector, provider1, false)
        );
        vm.expectRevert(JobManager.DeadlinePassed.selector);
        jobManager.submitJobResult(jobId, "ipfs://late_result");
        vm.stopPrank();

        ProviderRegistry.ProviderInfo memory pInfoAfter = registry.getProviderInfo(provider1);
        assertEq(pInfoAfter.jobsDone, pInfoBefore.jobsDone + 1, "JobsDone should increment");
        assertEq(pInfoAfter.successfulJobs, pInfoBefore.successfulJobs, "SuccessfulJobs should not increment");
    }


    // --- Test claimPaymentAndCompleteJob ---
    function test_ClaimPaymentAndCompleteJob_Success() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManager.acceptJob(jobId);
        vm.prank(provider1);
        jobManager.submitJobResult(jobId, "ipfs://final_result_cid");

        uint256 initialProviderBalance = gpuCredit.balanceOf(provider1);
        uint256 initialJobManagerBalance = gpuCredit.balanceOf(address(jobManager));
        ProviderRegistry.ProviderInfo memory providerInfoBefore = registry.getProviderInfo(provider1);

        vm.startPrank(client1); // Client claims
        // Expect provider to be rated positively
        vm.expectCall(
            address(registry),
            abi.encodeWithSelector(ProviderRegistry.rate.selector, provider1, true)
        );
        vm.expectEmit(true, true, false, false);
        emit JobCompletedAndPaid(jobId, provider1, JOB_PAYMENT_AMOUNT);
        jobManager.claimPaymentAndCompleteJob(jobId);
        vm.stopPrank();

        JobManager.Job memory job = jobManager.getJob(jobId);
        assertEq(uint8(job.status), uint8(JobManager.JobStatus.Completed), "Job status should be Completed");
        assertEq(gpuCredit.balanceOf(provider1), initialProviderBalance + JOB_PAYMENT_AMOUNT, "Provider balance incorrect");
        assertEq(gpuCredit.balanceOf(address(jobManager)), initialJobManagerBalance - JOB_PAYMENT_AMOUNT, "JobManager balance incorrect");

        ProviderRegistry.ProviderInfo memory providerInfoAfter = registry.getProviderInfo(provider1);
        assertEq(providerInfoAfter.jobsDone, providerInfoBefore.jobsDone + 1, "Provider jobsDone mismatch");
        assertEq(providerInfoAfter.successfulJobs, providerInfoBefore.successfulJobs + 1, "Provider successfulJobs mismatch");
    }

    function testFail_ClaimPayment_NotClient() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManager.acceptJob(jobId);
        vm.prank(provider1);
        jobManager.submitJobResult(jobId, "ipfs://result_cid_for_not_client_claim");

        vm.startPrank(provider1); // Provider tries to claim
        vm.expectRevert(JobManager.NotJobClient.selector);
        jobManager.claimPaymentAndCompleteJob(jobId);
        vm.stopPrank();
    }

    function testFail_ClaimPayment_NotResultSubmittedStatus() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManager.acceptJob(jobId); // Job is Accepted, not ResultSubmitted

        vm.startPrank(client1);
        vm.expectRevert(JobManager.InvalidJobStatus.selector);
        jobManager.claimPaymentAndCompleteJob(jobId);
        vm.stopPrank();
    }

    // --- Test cancelJob ---
    function test_CancelJob_Success() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        // Job is in Created status

        uint256 initialClientBalance = gpuCredit.balanceOf(client1);
        uint256 initialJobManagerBalance = gpuCredit.balanceOf(address(jobManager));

        vm.startPrank(client1);
        vm.expectEmit(true, true, true, true);
        emit JobCancelled(jobId, client1, JOB_PAYMENT_AMOUNT);
        jobManager.cancelJob(jobId);
        vm.stopPrank();

        JobManager.Job memory job = jobManager.getJob(jobId);
        assertEq(uint8(job.status), uint8(JobManager.JobStatus.Cancelled), "Job status should be Cancelled");
        assertEq(gpuCredit.balanceOf(client1), initialClientBalance + JOB_PAYMENT_AMOUNT, "Client balance not refunded correctly");
        assertEq(gpuCredit.balanceOf(address(jobManager)), initialJobManagerBalance - JOB_PAYMENT_AMOUNT, "JobManager balance not reduced correctly");
    }

    function testFail_CancelJob_NotClient() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.startPrank(provider1); // Someone else tries to cancel
        vm.expectRevert(JobManager.NotJobClient.selector);
        jobManager.cancelJob(jobId);
        vm.stopPrank();
    }

    function testFail_CancelJob_NotCreatedStatus() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManager.acceptJob(jobId); // Job is now Accepted

        vm.startPrank(client1);
        vm.expectRevert(JobManager.InvalidJobStatus.selector);
        jobManager.cancelJob(jobId);
        vm.stopPrank();
    }

    // --- Test Admin Functions ---
    function test_SetMinProviderStakeRequired() public {
        uint256 newMinStake = 750 * 1e18;
        vm.startPrank(admin);
        vm.expectEmit(true, false, false); // only oldStake, newStake (not indexed)
        emit MinProviderStakeRequiredChanged(jobManager.minProviderStakeRequired(), newMinStake);
        jobManager.setMinProviderStakeRequired(newMinStake);
        vm.stopPrank();
        assertEq(jobManager.minProviderStakeRequired(), newMinStake, "minProviderStakeRequired not set");
    }

    function testFail_SetMinProviderStakeRequired_NotAdmin() public {
        vm.startPrank(client1); // Not admin
        // vm.expectRevert("AccessControl: account "); // Revert message can vary
        vm.expectRevert();
        jobManager.setMinProviderStakeRequired(123 * 1e18);
        vm.stopPrank();
    }

    // --- Test Reentrancy Guard (Conceptual Example for createJob) ---
    // MaliciousContract would try to call back into JobManager during token transfer
    // For brevity, this is a conceptual placeholder. Real reentrancy tests are more involved.
    // contract MaliciousReentrantContract is IERC20 {
    //     JobManager internal jobManagerInstance;
    //     bool internal reentered = false;
    //     uint256 internal jobIdToTarget;

    //     constructor(address _jobManager) {
    //         jobManagerInstance = JobManager(_jobManager);
    //     }
    //     function transferFrom(address from, address to, uint256 amount) external returns (bool) {
    //         if (!reentered && from == address(this) && to == address(jobManagerInstance)) {
    //             reentered = true;
    //             // Try to re-enter a JobManager function, e.g., create another job
    //             // This would fail due to ReentrancyGuard on createJob
    //             // jobManagerInstance.createJob("reentrant_cid", 10e18, block.timestamp + 1 days);
    //         }
    //         return true; // Simulate success
    //     }
    //     // Implement other IERC20 functions as needed (balanceOf, approve, etc.)
    //     function balanceOf(address) external view returns (uint256) { return 1_000_000e18; }
    //     function allowance(address, address) external view returns (uint256) { return type(uint256).max; }
    //     function approve(address, uint256) external returns (bool) { return true; }
    //     function transfer(address, uint256) external returns (bool) { return true; }
    //     function totalSupply() external view returns (uint256) { return 1_000_000_000e18; }
    //     function decimals() external view returns (uint8) { return 18; }
    //     function name() external view returns (string memory) { return "Malicious"; }
    //     function symbol() external view returns (string memory) { return "MAL"; }
    // }

    // function test_Reentrancy_CreateJob() public {
    //     // Setup: Deploy MaliciousReentrantContract, mint it tokens, client approves it
    //     // Then have client try to createJob, where MaliciousReentrantContract is the jobPaymentToken
    //     // This is complex to set up correctly for a simple example here.
    //     // The ReentrancyGuard from OpenZeppelin is generally well-tested.
    // }
}