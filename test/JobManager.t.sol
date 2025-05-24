// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
// Assuming correct paths if your contracts are in src/ and risc0 is in src/risc0/
import {GPUCredit} from "src/GPUCredit.sol";
import {ProviderRegistry} from "src/ProviderRegistry.sol"; // Import for ProviderRegistry type
import {JobManager} from "src/JobManager.sol";     // Import for JobManager type and its events/structs
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRiscZeroVerifier, Receipt} from "src/risc0/IRiscZeroVerifier.sol"; // Import Receipt struct too

// Mock Verifier for testing purposes
contract MockRiscZeroVerifier is IRiscZeroVerifier {
    bool public shouldRevert = false;


    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    // Implementation for the first verify function
    function verify(
        bytes calldata seal, /* lastSeal = seal; */ // Example of recording
        bytes32 imageId, /* lastImageId = imageId; */
        bytes32 journalHash /* lastJournalHash = journalHash; */
    ) external view override {
        // verifyCalled = true;
        if (shouldRevert) {
            revert("MockVerifier: verify(seal,imageId,journalHash) intentionally failed");
        }
        // If not reverting, do nothing (proof is considered valid by mock)
    }

    // Implementation for the second verify function (verifyIntegrity)
    function verifyIntegrity(
        Receipt calldata receipt_ // receiptStruct was the name in the error, IRiscZeroVerifier.sol uses 'receipt'
                                // lastReceiptStruct = receipt_; // Example of recording
    ) external view override {
        // verifyIntegrityCalled = true;
        if (shouldRevert) {
            revert("MockVerifier: verifyIntegrity(receipt) intentionally failed");
        }
        // If not reverting, do nothing (proof is considered valid by mock)
    }
}

contract JobManagerTest is Test {
    // --- Contracts --- (as before)
    GPUCredit public gpuCredit;
    ProviderRegistry public registry; // Instance of the actual ProviderRegistry
    JobManager public jobManagerInstance;
    MockRiscZeroVerifier public mockVerifier;

    // --- Users & Constants --- (as before)
    address public admin = vm.addr(0x1);
    address public client1 = vm.addr(0x2);
    address public provider1 = vm.addr(0x3);
    // ...
    bytes32 constant TEST_METHOD_ID = keccak256("test_method_id");
    bytes32 constant TEST_JOURNAL_HASH = keccak256("test_journal_data");
    bytes   constant TEST_SEAL = hex"0102030405060708";
    uint256 constant JOB_PAYMENT_AMOUNT = 100 * 1e18;
    uint256 constant ONE_DAY_IN_SECONDS = 1 days;


    function setUp() public { // as before
        vm.startPrank(admin);
        gpuCredit = new GPUCredit("Test GPU Credit", "TGPUC");
        registry = new ProviderRegistry(address(gpuCredit), admin, admin, admin); // Deploy real registry
        mockVerifier = new MockRiscZeroVerifier();
        jobManagerInstance = new JobManager(
            address(registry),
            address(gpuCredit),
            address(mockVerifier),
            admin
        );
        if (address(registry) != address(0)) {
            registry.grantRole(registry.RATER_ROLE(), address(jobManagerInstance));
        }
        gpuCredit.mint(client1, 1_000_000 * 1e18);
        gpuCredit.mint(provider1, 1_000_000 * 1e18);
        vm.stopPrank();

        vm.startPrank(provider1);
        gpuCredit.approve(address(registry), 1000 * 1e18);
        registry.stake(1000 * 1e18);
        vm.stopPrank();

        vm.startPrank(client1);
        gpuCredit.approve(address(jobManagerInstance), type(uint256).max);
        vm.stopPrank();
        // ... other setup ...
    }

    function _createTestJob(address _client, uint256 _payment, uint256 _deadlineOffset, bytes32 _methodId) internal returns (uint256 jobId) {
        vm.startPrank(_client);
        // Use jobManagerInstance to call createJob
        jobId = jobManagerInstance.createJob("ipfs://test_job_data_cid", _payment, block.timestamp + _deadlineOffset, _methodId);
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
        // vm.expectEmit checks for events emitted BY jobManagerInstance during the *next call*
        // The arguments to vm.expectEmit are booleans: checkTopic1, checkTopic2, checkTopic3, checkData
        // JobCreated(uint256 indexed jobId, address indexed client, string jobDataCID, uint256 maxPaymentGPUCredit, uint256 deadlineTimestamp, bytes32 indexed methodId)
        // Topic0: event signature
        // Topic1: jobId (expectedJobId)
        // Topic2: client (client1)
        // Topic3: methodId (TEST_METHOD_ID)
        // Data: jobDataCID, maxPaymentGPUCredit, deadlineTimestamp
        // So, we check all 3 indexed topics and the data.
        vm.expectEmit(true, true, true, true, address(jobManagerInstance));
        // The 'emit' keyword here inside vm.expectEmit IS NOT a Solidity emit statement.
        // It's a Foundry cheatcode syntax to specify WHICH event to expect.
        // You need to qualify the event name with the contract it's defined in if it's not in the current scope.
        emit JobManager.JobCreated(expectedJobId, client1, cid, JOB_PAYMENT_AMOUNT, deadline, TEST_METHOD_ID);
        uint256 jobId = jobManagerInstance.createJob(cid, JOB_PAYMENT_AMOUNT, deadline, TEST_METHOD_ID);
        vm.stopPrank();

        assertEq(jobId, expectedJobId);
        JobManager.Job memory job = jobManagerInstance.getJob(jobId);
        assertEq(job.client, client1);
        // ... other asserts ...
        assertEq(job.methodId, TEST_METHOD_ID);
    }

    // ... (test_CreateJob_NoApproval_Reverts and others are fine but REMOVE `emit ...` lines from them) ...
    // Example for acceptJob:
    function test_AcceptJob_Success() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS, TEST_METHOD_ID);

        vm.startPrank(provider1);
        // JobAccepted(uint256 indexed jobId, address indexed provider)
        // Topic1: jobId, Topic2: provider
        vm.expectEmit(true, true, false, true, address(jobManagerInstance)); // checkTopic1, checkTopic2, NO checkTopic3, checkData (data is empty)
        emit JobManager.JobAccepted(jobId, provider1); // Qualify with JobManager
        jobManagerInstance.acceptJob(jobId);
        vm.stopPrank();

        JobManager.Job memory job = jobManagerInstance.getJob(jobId);
        assertEq(job.provider, provider1);
        assertEq(uint8(job.status), uint8(JobManager.JobStatus.Accepted));
    }


    // --- Test submitProofAndClaim ---
    function test_SubmitProofAndClaim_Success() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS, TEST_METHOD_ID);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);

        string memory resultCID = "ipfs://final_result_cid";
        // ... (initial balances, etc.) ...

        vm.startPrank(provider1);
        vm.expectCall(
            address(mockVerifier),
            abi.encodeWithSelector(IRiscZeroVerifier.verify.selector, TEST_SEAL, TEST_METHOD_ID, TEST_JOURNAL_HASH)
        );

        // JobProofVerified(uint256 indexed jobId, address indexed provider, bytes32 methodId, bytes32 journalHash)
        // methodId and journalHash are NOT indexed in your event. Provider IS.
        // So, Topic1: jobId, Topic2: provider. Data: methodId, journalHash
        vm.expectEmit(true, true, false, true, address(jobManagerInstance));
        emit JobManager.JobProofVerified(jobId, provider1, TEST_METHOD_ID, TEST_JOURNAL_HASH);

        // JobCompletedAndPaid(uint256 indexed jobId, address indexed provider, uint256 paymentAmountGPUCredit)
        // Topic1: jobId, Topic2: provider. Data: paymentAmountGPUCredit
        vm.expectEmit(true, true, false, true, address(jobManagerInstance));
        emit JobManager.JobCompletedAndPaid(jobId, provider1, JOB_PAYMENT_AMOUNT);

        if (address(registry) != address(0)) {
            // To use IProviderRegistry.rate.selector, IProviderRegistry needs to be known.
            // If IProviderRegistry is defined globally in ProviderRegistry.sol, this might work.
            // Otherwise, you might need to define/import it in JobManagerTest.sol
            // Let's assume it's globally accessible from the ProviderRegistry import for now.
            // If IProviderRegistry is an interface defined *inside* ProviderRegistry contract,
            // then it would be ProviderRegistry.IProviderRegistry.rate.selector
            // For now, let's assume it's top-level in ProviderRegistry.sol or its own file and imported.
            // If not, we need `import {IProviderRegistry} from "src/interfaces/IProviderRegistry.sol";` (example path)
            // and then use `IProviderRegistry.rate.selector`.
            // For now, to get it compiling, let's assume ProviderRegistry itself exposes the selector correctly.
            // This is often the tricky part. If `ProviderRegistry.rate.selector` works, it means `rate` is public on `ProviderRegistry`.
            vm.expectCall(address(registry), abi.encodeWithSelector(ProviderRegistry.rate.selector, provider1, true));
        }

        jobManagerInstance.submitProofAndClaim(jobId, TEST_SEAL, TEST_JOURNAL_HASH, resultCID);
        vm.stopPrank();
        // ... (asserts) ...
    }

    function test_SubmitJobResult_DeadlinePassedAndRated_Reverts() public {
        // ... (setup) ...
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, 1 seconds, TEST_METHOD_ID);
        vm.prank(provider1);
        jobManagerInstance.acceptJob(jobId);
        vm.warp(block.timestamp + 2 seconds); // Warp time past deadline

        vm.startPrank(provider1);
        if (address(registry) != address(0)) {
            // Similar to above, ensure ProviderRegistry.rate.selector is accessible
            vm.expectCall(address(registry), abi.encodeWithSelector(ProviderRegistry.rate.selector, provider1, false));
        }
        vm.expectRevert(JobManager.DeadlinePassed.selector);
        jobManagerInstance.submitProofAndClaim(jobId, TEST_SEAL, TEST_JOURNAL_HASH, "ipfs://late_result"); // Changed to submitProofAndClaim
        vm.stopPrank();
        // ... (asserts about provider rating NOT changing due to revert)
    }


    // Test cancelJob
    function test_CancelJob_Success() public {
        uint256 jobId = _createTestJob(client1, JOB_PAYMENT_AMOUNT, ONE_DAY_IN_SECONDS, TEST_METHOD_ID);
        // ... (initial balances) ...
        vm.startPrank(client1);
        // JobCancelled(uint256 indexed jobId, address indexed client, uint256 refundAmountGPUCredit)
        // Topic1: jobId, Topic2: client. Data: refundAmount
        vm.expectEmit(true, true, false, true, address(jobManagerInstance));
        emit JobManager.JobCancelled(jobId, client1, JOB_PAYMENT_AMOUNT); // Qualify with JobManager
        jobManagerInstance.cancelJob(jobId);
        vm.stopPrank();
        // ... (asserts) ...
    }

    // ... other tests ...
    // Make sure all `emit EventName(...)` lines used with `vm.expectEmit` are qualified with `JobManager.EventName(...)`
    // And for `vm.expectCall` with selectors, ensure the interface/contract type is correctly referenced.
}