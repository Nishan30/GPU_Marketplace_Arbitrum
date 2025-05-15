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
    GPUCredit public gpuCredit;
    ProviderRegistry public registry;
    JobManager public jobManagerInstance;

    // --- Users ---
    address public admin = vm.addr(0x1);
    address public client1 = vm.addr(0x2);
    address public provider1 = vm.addr(0x3);
    address public provider2 = vm.addr(0x4);
    address public stranger = vm.addr(0x5);
    address public slashedFundsRecipient;

    // --- Constants ---
    uint256 constant INITIAL_MINT_AMOUNT = 1_000_000 * 1e18;
    uint256 constant PROVIDER_STAKE_AMOUNT = 1000 * 1e18;
    uint256 constant JOB_PAYMENT_AMOUNT = 100 * 1e18;
    uint256 constant ONE_DAY_IN_SECONDS = 1 days;

    // --- Setup ---
    constructor() JobManager(vm.addr(0xBAD1), vm.addr(0xBAD2), vm.addr(0xBAD3)) {}

    function setUp() public {
        vm.startPrank(admin);

        gpuCredit = new GPUCredit("Test GPU Credit", "TGPUC");
        slashedFundsRecipient = vm.addr(0x6);
        registry = new ProviderRegistry(address(gpuCredit), admin, admin, admin);
        registry.setSlashedFundsRecipient(slashedFundsRecipient);
        jobManagerInstance = new JobManager(address(registry), address(gpuCredit), admin);
        registry.grantRole(registry.RATER_ROLE(), address(jobManagerInstance));
        gpuCredit.mint(client1, INITIAL_MINT_AMOUNT);
        gpuCredit.mint(provider1, INITIAL_MINT_AMOUNT);
        gpuCredit.mint(provider2, INITIAL_MINT_AMOUNT);
        gpuCredit.mint(admin, INITIAL_MINT_AMOUNT);
        gpuCredit.mint(stranger, INITIAL_MINT_AMOUNT);

        vm.stopPrank();

        vm.startPrank(provider1);
        gpuCredit.approve(address(registry), PROVIDER_STAKE_AMOUNT);
        registry.stake(PROVIDER_STAKE_AMOUNT);
        vm.stopPrank();

        vm.startPrank(provider2);
        gpuCredit.approve(address(registry), PROVIDER_STAKE_AMOUNT);
        registry.stake(PROVIDER_STAKE_AMOUNT);
        vm.stopPrank();

        vm.startPrank(client1);
        gpuCredit.approve(address(jobManagerInstance), type(uint256).max);
        vm.stopPrank();

        vm.deal(admin, 10 ether);
        vm.deal(client1, 10 ether);
        vm.deal(provider1, 10 ether);
        vm.deal(provider2, 10 ether);
        vm.deal(stranger, 10 ether);
        vm.deal(slashedFundsRecipient, 10 ether);
    }

    // --- Utility Functions ---
    function _createTestJob(address _client, uint256 _payment, uint256 _deadlineOffset) internal returns (uint256 jobId) {
        vm.startPrank(_client);
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
        vm.expectEmit(true, true, false, true, address(jobManagerInstance));
        emit JobCreated(expectedJobId, client1, cid, JOB_PAYMENT_AMOUNT, deadline);
        uint256 jobId = jobManagerInstance.createJob(cid, JOB_PAYMENT_AMOUNT, deadline);
        vm.stopPrank();

        assertEq(jobId, expectedJobId);
        JobManager.Job memory job = jobManagerInstance.getJob(jobId);
        assertEq(job.client, client1);
        assertEq(job.jobDataCID, cid);
        assertEq(job.maxPaymentGPUCredit, JOB_PAYMENT_AMOUNT);
        assertEq(job.deadlineTimestamp, deadline);
        assertEq(uint8(job.status), uint8(JobManager.JobStatus.Created));
        assertEq(gpuCredit.balanceOf(client1), initialClientBalance - JOB_PAYMENT_AMOUNT);
        assertEq(gpuCredit.balanceOf(address(jobManagerInstance)), initialJobManagerBalance + JOB_PAYMENT_AMOUNT);
    }

    function test_CreateJob_NoApproval_Reverts() public {
        vm.startPrank(stranger);
        // FIX: Expect the ERC20 custom error with arguments
        // The spender is jobManagerInstance, allowance is 0, needed is JOB_PAYMENT_AMOUNT
        bytes memory expectedRevertData = abi.encodeWithSelector(
            bytes4(keccak256("ERC20InsufficientAllowance(address,uint256,uint256)")),
            address(jobManagerInstance), // spender
            0,                           // allowance
            JOB_PAYMENT_AMOUNT           // needed
        );
        vm.expectRevert(expectedRevertData);
        jobManagerInstance.createJob("ipfs://no_approval_cid", JOB_PAYMENT_AMOUNT, block.timestamp + ONE_DAY_IN_SECONDS);
        vm.stopPrank();
    }

    function test_CreateJob_ZeroPayment_Reverts() public {
        vm.startPrank(client1);
        vm.expectRevert(JobManager.EscrowAmountZero.selector);
        jobManagerInstance.createJob("ipfs://zero_payment_cid", 0, block.timestamp + ONE_DAY_IN_SECONDS);
        vm.stopPrank();
    }

    function test_CreateJob_DeadlineInPast_Reverts() public {
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

    function test_AcceptJob_NotRegisteredProvider_Reverts() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.startPrank(stranger);
        vm.expectRevert(JobManager.ProviderNotRegisteredOrInsufficientStake.selector);
        jobManagerInstance.acceptJob(jobId);
        vm.stopPrank();
    }

    function test_AcceptJob_InsufficientStake_Reverts() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.startPrank(admin);
        jobManagerInstance.setMinProviderStakeRequired(PROVIDER_STAKE_AMOUNT + 1);
        vm.stopPrank();
        vm.startPrank(provider1);
        vm.expectRevert(JobManager.ProviderNotRegisteredOrInsufficientStake.selector);
        jobManagerInstance.acceptJob(jobId);
        vm.stopPrank();
    }

    function test_AcceptJob_NotCreatedStatus_Reverts() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.startPrank(provider2);
        JobManager.JobStatus currentStatus = JobManager.JobStatus.Accepted;
        JobManager.JobStatus requiredStatus = JobManager.JobStatus.Created;
        vm.expectRevert(abi.encodeWithSelector(JobManager.InvalidJobStatus.selector, currentStatus, requiredStatus));
        jobManagerInstance.acceptJob(jobId);
        vm.stopPrank();
    }

    function test_AcceptJob_JobAlreadyHasProvider_Reverts() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);

        vm.startPrank(provider2);
        JobManager.JobStatus currentStatus = JobManager.JobStatus.Accepted;
        JobManager.JobStatus requiredStatus = JobManager.JobStatus.Created;
        vm.expectRevert(abi.encodeWithSelector(JobManager.InvalidJobStatus.selector, currentStatus, requiredStatus));
        jobManagerInstance.acceptJob(jobId);
        vm.stopPrank();
    }

    function test_AcceptJob_DeadlinePassed_Reverts() public {
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

    function test_SubmitJobResult_NotAssignedProvider_Reverts() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.startPrank(provider2);
        vm.expectRevert(JobManager.OnlyAssignedProviderCanSubmit.selector);
        jobManagerInstance.submitJobResult(jobId, "ipfs://wrong_provider_result");
        vm.stopPrank();
    }

    function test_SubmitJobResult_NotAcceptedStatus_JobCreated_Reverts() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.startPrank(provider1);
        vm.expectRevert(JobManager.OnlyAssignedProviderCanSubmit.selector);
        jobManagerInstance.submitJobResult(jobId, "ipfs://not_accepted_result");
        vm.stopPrank();
    }

    function test_SubmitJobResult_NotAcceptedStatus_JobCompleted_Reverts() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.prank(provider1);
        jobManagerInstance.submitJobResult(jobId, "ipfs://some_result");
        vm.prank(client1);
        jobManagerInstance.claimPaymentAndCompleteJob(jobId);

        vm.startPrank(provider1);
        JobManager.JobStatus currentStatus = JobManager.JobStatus.Completed;
        JobManager.JobStatus requiredStatus = JobManager.JobStatus.Accepted;
        vm.expectRevert(abi.encodeWithSelector(JobManager.InvalidJobStatus.selector, currentStatus, requiredStatus));
        jobManagerInstance.submitJobResult(jobId, "ipfs://too_late_result");
        vm.stopPrank();
    }

    function test_SubmitJobResult_DeadlinePassedAndRated_Reverts() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, 1 seconds);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.warp(block.timestamp + 2 seconds);
        ProviderRegistry.ProviderInfo memory pInfoBefore = registry.getProviderInfo(provider1);
        vm.startPrank(provider1);
        vm.expectCall(address(registry), abi.encodeWithSelector(IProviderRegistry.rate.selector, provider1, false));
        vm.expectRevert(JobManager.DeadlinePassed.selector);
        jobManagerInstance.submitJobResult(jobId, "ipfs://late_result");
        vm.stopPrank();
        ProviderRegistry.ProviderInfo memory pInfoAfter = registry.getProviderInfo(provider1);
        // FIX: If submitJobResult reverts, state changes from rate() are also reverted.
        assertEq(pInfoAfter.jobsDone, pInfoBefore.jobsDone, "Jobs done should NOT change if transaction reverts");
        assertEq(pInfoAfter.successfulJobs, pInfoBefore.successfulJobs, "Successful jobs should NOT change if transaction reverts");
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
        vm.expectCall(address(registry), abi.encodeWithSelector(IProviderRegistry.rate.selector, provider1, true));
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

    function test_ClaimPayment_NotClient_Reverts() public {
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

    function test_ClaimPayment_NotResultSubmittedStatus_Reverts() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.startPrank(client1);
        JobManager.JobStatus currentStatus = JobManager.JobStatus.Accepted;
        JobManager.JobStatus requiredStatus = JobManager.JobStatus.ResultSubmitted;
        vm.expectRevert(abi.encodeWithSelector(JobManager.InvalidJobStatus.selector, currentStatus, requiredStatus));
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

    function test_CancelJob_NotClient_Reverts() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.startPrank(provider1);
        vm.expectRevert(JobManager.NotJobClient.selector);
        jobManagerInstance.cancelJob(jobId);
        vm.stopPrank();
    }

    function test_CancelJob_NotCreatedStatus_Reverts() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.startPrank(client1);
        JobManager.JobStatus currentStatus = JobManager.JobStatus.Accepted;
        JobManager.JobStatus requiredStatus = JobManager.JobStatus.Created;
        vm.expectRevert(abi.encodeWithSelector(JobManager.InvalidJobStatus.selector, currentStatus, requiredStatus));
        jobManagerInstance.cancelJob(jobId);
        vm.stopPrank();
    }

    // --- Test Admin Functions ---
    function test_SetMinProviderStakeRequired() public {
        uint256 currentMinStake = jobManagerInstance.minProviderStakeRequired();
        uint256 newMinStake = 750 * 1e18;
        vm.startPrank(admin);
        vm.expectEmit(false, false, false, true, address(jobManagerInstance));
        emit MinProviderStakeRequiredChanged(currentMinStake, newMinStake);
        jobManagerInstance.setMinProviderStakeRequired(newMinStake);
        vm.stopPrank();
        assertEq(jobManagerInstance.minProviderStakeRequired(), newMinStake);
    }

    function test_SetMinProviderStakeRequired_NotAdmin_Reverts() public {
        vm.startPrank(client1);
        bytes32 adminRole = jobManagerInstance.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                client1,
                adminRole
            )
        );
        jobManagerInstance.setMinProviderStakeRequired(123 * 1e18);
        vm.stopPrank();
    }

    // --- Test Constructor Reverts ---
    function test_Constructor_ZeroProviderRegistry_Reverts() public {
        vm.expectRevert("ProviderRegistry address cannot be zero");
        new JobManager(address(0), address(gpuCredit), admin);
    }

    function test_Constructor_ZeroJobPaymentToken_Reverts() public {
        vm.expectRevert("JobPaymentToken address cannot be zero");
        new JobManager(address(registry), address(0), admin);
    }

    function test_Constructor_ZeroInitialAdmin_Reverts() public {
        vm.expectRevert("Initial admin address cannot be zero");
        new JobManager(address(registry), address(gpuCredit), address(0));
    }

    // --- Test GetJob ---
    function test_GetJob_Success() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS);
        JobManager.Job memory job = jobManagerInstance.getJob(jobId);
        assertEq(job.id, jobId);
        assertEq(job.client, client1);
    }

    function test_GetJob_NotFound_Reverts() public {
        uint256 nonExistentJobId = jobManagerInstance.nextJobId() + 100;
        vm.expectRevert(JobManager.JobNotFound.selector);
        jobManagerInstance.getJob(nonExistentJobId);
    }
}