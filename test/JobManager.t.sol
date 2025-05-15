// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "src/GPUCredit.sol";
import "src/ProviderRegistry.sol";
import "src/JobManager.sol"; // We will inherit from this
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// VVVVV MAKE THE TEST CONTRACT INHERIT FROM JobManager VVVVV
contract JobManagerTest is Test, JobManager {
    // --- Contracts ---
    // We will use the `jobManager` instance created by the `JobManager` constructor
    // when this test contract itself is deployed.
    // However, for clarity and control in `setUp`, we often deploy them separately
    // and then use a reference. Let's keep the separate deployment for now
    // and be mindful that `this` test contract *also is* a JobManager.
    // For event checking, inheriting makes the event definitions visible.

    GPUCredit public gpuCredit;
    ProviderRegistry public registry;
    JobManager public jobManagerInstance; // Renamed to avoid conflict if we were to use `this` as JobManager

    // --- Users ---
    address public admin = address(0x1);
    address public client1 = address(0x2);
    address public provider1 = address(0x3);
    address public provider2 = address(0x4);
    address public stranger = address(0x5);
    address public slashedFundsRecipient;

    // --- Constants ---
    uint256 constant INITIAL_MINT_AMOUNT = 1_000_000 * 1e18;
    uint256 constant PROVIDER_STAKE_AMOUNT = 1000 * 1e18;
    uint256 constant JOB_PAYMENT_AMOUNT = 100 * 1e18;
    // MIN_STAKE_FOR_JOB is defined in JobManager, we can access it via jobManagerInstance.minProviderStakeRequired()
    uint256 constant ONE_DAY_IN_SECONDS = 1 days;

    // --- Setup ---
    // Constructor for JobManager (from which we inherit) needs arguments.
    // We must provide them here. For testing, we can use dummy addresses or deploy
    // the real dependencies first and pass their addresses.
    // Let's deploy dependencies and then pass their addresses.
    constructor() JobManager(address(0), address(0), address(0)) { // Dummy values, will be set in setUp
        // This constructor is for the JobManager part of JobManagerTest.
        // We will primarily interact with `jobManagerInstance`.
    }


    function setUp() public {
        // Deployer / Admin
        vm.startPrank(admin);

        // 1. Deploy GPUCredit
        gpuCredit = new GPUCredit("Test GPU Credit", "TGPUC");

        // 2. Deploy ProviderRegistry
        slashedFundsRecipient = address(0x6);
        registry = new ProviderRegistry(address(gpuCredit), admin, admin, admin);
        registry.setSlashedFundsRecipient(slashedFundsRecipient);

        // 3. Deploy JobManager INSTANCE that we will test
        jobManagerInstance = new JobManager(address(registry), address(gpuCredit), admin);

        // 4. Grant necessary roles to jobManagerInstance on ProviderRegistry
        registry.grantRole(registry.RATER_ROLE(), address(jobManagerInstance));

        // 5. Mint GPUCredit to users
        gpuCredit.mint(client1, INITIAL_MINT_AMOUNT);
        gpuCredit.mint(provider1, INITIAL_MINT_AMOUNT);
        gpuCredit.mint(provider2, INITIAL_MINT_AMOUNT);

        vm.stopPrank();

        // 6. Providers approve registry and stake GPUCredit
        vm.startPrank(provider1);
        gpuCredit.approve(address(registry), PROVIDER_STAKE_AMOUNT);
        registry.stake(PROVIDER_STAKE_AMOUNT);
        vm.stopPrank();

        vm.startPrank(provider2);
        gpuCredit.approve(address(registry), PROVIDER_STAKE_AMOUNT);
        registry.stake(PROVIDER_STAKE_AMOUNT);
        vm.stopPrank();

        // 7. Client1 approves jobManagerInstance
        vm.startPrank(client1);
        gpuCredit.approve(address(jobManagerInstance), type(uint256).max);
        vm.stopPrank();
    }

    // --- Utility Functions ---
    function _createTestJob(address _client, uint256 _payment, uint256 _deadlineOffset) internal returns (uint256 jobId) {
        vm.startPrank(_client);
        // Interact with jobManagerInstance
        jobId = jobManagerInstance.createJob("ipfs://test_job_data_cid", _payment, block.timestamp + _deadlineOffset);
        vm.stopPrank();
    }

    // --- Test createJob ---
    function test_CreateJob_Success() public {
        uint256 initialClientBalance = gpuCredit.balanceOf(client1);
        uint256 initialJobManagerBalance = gpuCredit.balanceOf(address(jobManagerInstance));
        uint256 deadline = block.timestamp + ONE_DAY_IN_SECONDS;
        string memory cid = "ipfs://job_cid_1";
        uint256 expectedJobId = jobManagerInstance.nextJobId();

        vm.startPrank(client1);
        // Now that JobManagerTest inherits JobManager, JobCreated event is in scope
        vm.expectEmit(true, true, false, true, address(jobManagerInstance));
        emit JobCreated(expectedJobId, client1, cid, JOB_PAYMENT_AMOUNT, deadline);
        uint256 jobId = jobManagerInstance.createJob(cid, JOB_PAYMENT_AMOUNT, deadline);
        vm.stopPrank();

        assertEq(jobId, expectedJobId);
        JobManager.Job memory job = jobManagerInstance.getJob(jobId); // Use instance
        assertEq(job.client, client1);
        assertEq(job.jobDataCID, cid);
        // ... rest of assertions using jobManagerInstance ...
        assertEq(gpuCredit.balanceOf(client1), initialClientBalance - JOB_PAYMENT_AMOUNT);
        assertEq(gpuCredit.balanceOf(address(jobManagerInstance)), initialJobManagerBalance + JOB_PAYMENT_AMOUNT);
    }

    function testFail_CreateJob_NoApproval() public {
        vm.startPrank(admin);
        gpuCredit.mint(stranger, JOB_PAYMENT_AMOUNT);
        vm.stopPrank();

        vm.startPrank(stranger);
        vm.expectRevert(bytes("ERC20: insufficient allowance"));
        jobManagerInstance.createJob("ipfs://no_approval_cid", JOB_PAYMENT_AMOUNT, block.timestamp + ONE_DAY_IN_SECONDS);
        vm.stopPrank();
    }

    function testFail_CreateJob_ZeroPayment() public {
        vm.startPrank(client1);
        vm.expectRevert(JobManager.EscrowAmountZero.selector);
        jobManagerInstance.createJob("ipfs://zero_payment_cid", 0, block.timestamp + ONE_DAY_IN_SECONDS);
        vm.stopPrank();
    }

    function testFail_CreateJob_DeadlineInPast() public {
        vm.startPrank(client1);
        vm.expectRevert(JobManager.DeadlineMustBeInFuture.selector);
        jobManagerInstance.createJob("ipfs://past_deadline_cid", JOB_PAYMENT_AMOUNT, block.timestamp - 1 seconds);
        vm.stopPrank();
    }

    // --- Test acceptJob ---
    function test_AcceptJob_Success() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);

        vm.startPrank(provider1);
        vm.expectEmit(true, true, false, false, address(jobManagerInstance));
        emit JobAccepted(jobId, provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.stopPrank();

        JobManager.Job memory job = jobManagerInstance.getJob(jobId);
        assertEq(job.provider, provider1);
        assertEq(uint8(job.status), uint8(JobManager.JobStatus.Accepted));
    }

    function testFail_AcceptJob_NotRegisteredProvider() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.startPrank(stranger);
        vm.expectRevert(JobManager.ProviderNotRegisteredOrInsufficientStake.selector);
        jobManagerInstance.acceptJob(jobId);
        vm.stopPrank();
    }

    function testFail_AcceptJob_InsufficientStake() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.startPrank(admin);
        jobManagerInstance.setMinProviderStakeRequired(PROVIDER_STAKE_AMOUNT + 1);
        vm.stopPrank();
        vm.startPrank(provider1);
        vm.expectRevert(JobManager.ProviderNotRegisteredOrInsufficientStake.selector);
        jobManagerInstance.acceptJob(jobId);
        vm.stopPrank();
    }

    function testFail_AcceptJob_NotCreatedStatus() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.startPrank(provider2);
        vm.expectRevert(JobManager.InvalidJobStatus.selector);
        jobManagerInstance.acceptJob(jobId);
        vm.stopPrank();
    }

    function testFail_AcceptJob_DeadlinePassed() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, 1 seconds);
        vm.warp(block.timestamp + 2 seconds);
        vm.startPrank(provider1);
        vm.expectRevert(JobManager.DeadlinePassed.selector);
        jobManagerInstance.acceptJob(jobId);
        vm.stopPrank();
    }

    // --- Test submitJobResult ---
    function test_SubmitJobResult_Success() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        string memory resultCID = "ipfs://result_cid";
        vm.startPrank(provider1);
        vm.expectEmit(true, true, false, true, address(jobManagerInstance));
        emit JobResultSubmitted(jobId, provider1, resultCID);
        jobManagerInstance.submitJobResult(jobId, resultCID);
        vm.stopPrank();
        JobManager.Job memory job = jobManagerInstance.getJob(jobId);
        assertEq(job.resultDataCID, resultCID);
        assertEq(uint8(job.status), uint8(JobManager.JobStatus.ResultSubmitted));
    }

    function testFail_SubmitJobResult_NotAssignedProvider() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.startPrank(provider2);
        vm.expectRevert(JobManager.OnlyAssignedProviderCanSubmit.selector);
        jobManagerInstance.submitJobResult(jobId, "ipfs://wrong_provider_result");
        vm.stopPrank();
    }

    function testFail_SubmitJobResult_NotAcceptedStatus() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.startPrank(provider1);
        // Note: OnlyAssignedProviderCanSubmit will revert first because job.provider is address(0)
        vm.expectRevert(JobManager.OnlyAssignedProviderCanSubmit.selector);
        jobManagerInstance.submitJobResult(jobId, "ipfs://not_accepted_result");
        vm.stopPrank();
    }

    function testFail_SubmitJobResult_DeadlinePassedAndRated() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, 1 seconds);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.warp(block.timestamp + 2 seconds);
        ProviderRegistry.ProviderInfo memory pInfoBefore = registry.getProviderInfo(provider1);
        vm.startPrank(provider1);
        vm.expectCall(address(registry), abi.encodeWithSelector(ProviderRegistry.rate.selector, provider1, false));
        vm.expectRevert(JobManager.DeadlinePassed.selector);
        jobManagerInstance.submitJobResult(jobId, "ipfs://late_result");
        vm.stopPrank();
        ProviderRegistry.ProviderInfo memory pInfoAfter = registry.getProviderInfo(provider1);
        assertEq(pInfoAfter.jobsDone, pInfoBefore.jobsDone + 1);
        assertEq(pInfoAfter.successfulJobs, pInfoBefore.successfulJobs);
    }

    // --- Test claimPaymentAndCompleteJob ---
    function test_ClaimPaymentAndCompleteJob_Success() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.prank(provider1);
        jobManagerInstance.submitJobResult(jobId, "ipfs://final_result_cid");
        uint256 initialProviderBalance = gpuCredit.balanceOf(provider1);
        uint256 initialJobManagerBalance = gpuCredit.balanceOf(address(jobManagerInstance));
        ProviderRegistry.ProviderInfo memory providerInfoBefore = registry.getProviderInfo(provider1);
        vm.startPrank(client1);
        vm.expectCall(address(registry), abi.encodeWithSelector(ProviderRegistry.rate.selector, provider1, true));
        vm.expectEmit(true, true, false, true, address(jobManagerInstance));
        emit JobCompletedAndPaid(jobId, provider1, JOB_PAYMENT_AMOUNT);
        jobManagerInstance.claimPaymentAndCompleteJob(jobId);
        vm.stopPrank();
        JobManager.Job memory job = jobManagerInstance.getJob(jobId);
        assertEq(uint8(job.status), uint8(JobManager.JobStatus.Completed));
        assertEq(gpuCredit.balanceOf(provider1), initialProviderBalance + JOB_PAYMENT_AMOUNT);
        assertEq(gpuCredit.balanceOf(address(jobManagerInstance)), initialJobManagerBalance - JOB_PAYMENT_AMOUNT);
        ProviderRegistry.ProviderInfo memory providerInfoAfter = registry.getProviderInfo(provider1);
        assertEq(providerInfoAfter.jobsDone, providerInfoBefore.jobsDone + 1);
        assertEq(providerInfoAfter.successfulJobs, providerInfoBefore.successfulJobs + 1);
    }

    function testFail_ClaimPayment_NotClient() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.prank(provider1);
        jobManagerInstance.submitJobResult(jobId, "ipfs://result_cid_for_not_client_claim");
        vm.startPrank(provider1);
        vm.expectRevert(JobManager.NotJobClient.selector);
        jobManagerInstance.claimPaymentAndCompleteJob(jobId);
        vm.stopPrank();
    }

    function testFail_ClaimPayment_NotResultSubmittedStatus() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.startPrank(client1);
        vm.expectRevert(JobManager.InvalidJobStatus.selector);
        jobManagerInstance.claimPaymentAndCompleteJob(jobId);
        vm.stopPrank();
    }

    // --- Test cancelJob ---
    function test_CancelJob_Success() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        uint256 initialClientBalance = gpuCredit.balanceOf(client1);
        uint256 initialJobManagerBalance = gpuCredit.balanceOf(address(jobManagerInstance));
        vm.startPrank(client1);
        vm.expectEmit(true, true, false, true, address(jobManagerInstance));
        emit JobCancelled(jobId, client1, JOB_PAYMENT_AMOUNT);
        jobManagerInstance.cancelJob(jobId);
        vm.stopPrank();
        JobManager.Job memory job = jobManagerInstance.getJob(jobId);
        assertEq(uint8(job.status), uint8(JobManager.JobStatus.Cancelled));
        assertEq(gpuCredit.balanceOf(client1), initialClientBalance + JOB_PAYMENT_AMOUNT);
        assertEq(gpuCredit.balanceOf(address(jobManagerInstance)), initialJobManagerBalance - JOB_PAYMENT_AMOUNT);
    }

    function testFail_CancelJob_NotClient() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.startPrank(provider1);
        vm.expectRevert(JobManager.NotJobClient.selector);
        jobManagerInstance.cancelJob(jobId);
        vm.stopPrank();
    }

    function testFail_CancelJob_NotCreatedStatus() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.startPrank(client1);
        vm.expectRevert(JobManager.InvalidJobStatus.selector);
        jobManagerInstance.cancelJob(jobId);
        vm.stopPrank();
    }

    // --- Test Admin Functions ---
    function test_SetMinProviderStakeRequired() public {
        uint256 currentMinStake = jobManagerInstance.minProviderStakeRequired();
        uint256 newMinStake = 750 * 1e18;
        vm.startPrank(admin);
        vm.expectEmit(false, false, false, true, address(jobManagerInstance)); // Both params are non-indexed
        emit MinProviderStakeRequiredChanged(currentMinStake, newMinStake);
        jobManagerInstance.setMinProviderStakeRequired(newMinStake);
        vm.stopPrank();
        assertEq(jobManagerInstance.minProviderStakeRequired(), newMinStake);
    }

    function testFail_SetMinProviderStakeRequired_NotAdmin() public {
        vm.startPrank(client1);
        vm.expectRevert(); // AccessControl revert
        jobManagerInstance.setMinProviderStakeRequired(123 * 1e18);
        vm.stopPrank();
    }
}