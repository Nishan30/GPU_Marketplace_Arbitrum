// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; // Correct path for OZ v5+
// If using older OZ, it might be "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Assuming ProviderRegistry.sol is in the same directory or correctly remapped
import "./ProviderRegistry.sol"; // Or: import {ProviderRegistry} from "src/ProviderRegistry.sol";


contract JobManager is AccessControl, ReentrancyGuard {

    // --- Interfaces ---
    // Using the full ProviderRegistry contract definition through import also works.
    // An interface is slightly cleaner if you only need specific functions from it.
    // Ensure the ProviderInfo struct path is correct if ProviderRegistry is in a different file/path.
    interface IProviderRegistry {
        function getProviderInfo(address _provider) external view returns (ProviderRegistry.ProviderInfo memory);
        function slash(address _provider, uint256 _amount) external; // Assuming JobManager will be granted SLASHER_ROLE
        function rate(address _provider, bool _success) external;    // Assuming JobManager will be granted RATER_ROLE
    }

    // --- Structs & Enums ---
    enum JobStatus {
        Created,        // Job posted by client, awaiting provider
        Accepted,       // Provider has accepted the job
        ResultSubmitted,// Provider has submitted results/proof
        Completed,      // Client has claimed/approved, payment released
        Cancelled,      // Job cancelled
        Disputed        // (Future Scope) For dispute resolution
    }

    struct Job {
        uint256 id;
        address client;
        address provider;
        string jobDataCID;          // IPFS Content ID for job data/model
        uint256 maxPaymentGPUCredit; // Escrowed amount of GPUCredit token
        uint256 deadlineTimestamp;   // Unix timestamp for job completion
        JobStatus status;
        string resultDataCID;       // IPFS CID for results/proof from provider
        uint256 creationTimestamp;   // Timestamp when job was created
    }

    // --- State Variables ---
    IProviderRegistry public immutable providerRegistry;
    IERC20 public immutable jobPaymentToken; // This will be your GPUCredit token

    mapping(uint256 => Job) public jobs;
    uint256 public nextJobId; // Simple counter for job IDs

    // Minimum stake a provider must have (in GPUCredit) to accept a job
    uint256 public minProviderStakeRequired;
    // Optional: Platform fee percentage (e.g., 100 for 1.00% -> 100/10000)
    // uint16 public platformFeePercentageBPS; // BPS = Basis Points (1% = 100 BPS)
    // address public platformFeeRecipient;

    // --- Roles ---
    // DEFAULT_ADMIN_ROLE from AccessControl can manage settings

    // --- Events ---
    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        string jobDataCID,
        uint256 maxPaymentGPUCredit,
        uint256 deadlineTimestamp
    );
    event JobAccepted(uint256 indexed jobId, address indexed provider);
    event JobResultSubmitted(uint256 indexed jobId, address indexed provider, string resultDataCID);
    event JobCompletedAndPaid(uint256 indexed jobId, address indexed provider, uint256 paymentAmountGPUCredit);
    event JobCancelled(uint256 indexed jobId, address indexed client, uint256 refundAmountGPUCredit);
    event MinProviderStakeRequiredChanged(uint256 oldStake, uint256 newStake);
    // event PlatformFeeChanged(uint16 oldFeeBPS, uint16 newFeeBPS, address oldRecipient, address newRecipient);

    // --- Errors ---
    error JobNotFound();
    error NotJobClient();
    error NotJobProvider();
    error InvalidJobStatus(JobStatus current, JobStatus required);
    error TokenTransferFailed();
    error DeadlinePassed();
    error DeadlineMustBeInFuture();
    error ProviderNotRegisteredOrInsufficientStake();
    error OnlyProviderCanSubmit();
    error OnlyAssignedProviderCanSubmit();
    error OnlyClientCanClaim();
    error EscrowAmountZero();
    error JobAlreadyHasProvider();


    // --- Constructor ---
    constructor(
        address _providerRegistryAddress,
        address _jobPaymentTokenAddress, // Address of your GPUCredit token
        address _initialAdmin
        // address _initialFeeRecipient // Optional
    ) {
        if (_providerRegistryAddress == address(0)) revert("ProviderRegistry address cannot be zero");
        if (_jobPaymentTokenAddress == address(0)) revert("JobPaymentToken address cannot be zero");
        if (_initialAdmin == address(0)) revert("Initial admin address cannot be zero");

        providerRegistry = IProviderRegistry(_providerRegistryAddress);
        jobPaymentToken = IERC20(_jobPaymentTokenAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        minProviderStakeRequired = 0; // Admin can set this later using a dedicated function
        // platformFeeRecipient = _initialFeeRecipient; // Optional
        // platformFeePercentageBPS = 0; // Default to 0, admin can set
    }

    // --- Modifiers ---
    modifier onlyJobClient(uint256 _jobId) {
        if (jobs[_jobId].client == address(0)) revert JobNotFound(); // Also check job exists
        if (jobs[_jobId].client != msg.sender) revert NotJobClient();
        _;
    }

    modifier onlyJobProvider(uint256 _jobId) {
        if (jobs[_jobId].provider == address(0)) revert JobNotFound(); // Also check job exists and has provider
        if (jobs[_jobId].provider != msg.sender) revert NotJobProvider();
        _;
    }

    // --- Client Functions ---

    /**
     * @notice Creates a new job, escrowing GPUCredit payment.
     * @dev Client must have approved JobManager to spend their GPUCredits.
     * @param _jobDataCID IPFS CID of the job description/model.
     * @param _paymentAmountGPUCredit Amount of GPUCredit to escrow.
     * @param _deadlineTimestamp Unix timestamp by which the job should be completed.
     */
    function createJob(
        string memory _jobDataCID,
        uint256 _paymentAmountGPUCredit,
        uint256 _deadlineTimestamp
    ) public nonReentrant {
        if (_paymentAmountGPUCredit == 0) revert EscrowAmountZero();
        if (_deadlineTimestamp <= block.timestamp) revert DeadlineMustBeInFuture();

        // Escrow GPUCredit tokens from client to this contract
        bool success = jobPaymentToken.transferFrom(msg.sender, address(this), _paymentAmountGPUCredit);
        if (!success) revert TokenTransferFailed();

        uint256 jobId = nextJobId;
        jobs[jobId] = Job({
            id: jobId,
            client: msg.sender,
            provider: address(0), // No provider yet
            jobDataCID: _jobDataCID,
            maxPaymentGPUCredit: _paymentAmountGPUCredit,
            deadlineTimestamp: _deadlineTimestamp,
            status: JobStatus.Created,
            resultDataCID: "",
            creationTimestamp: block.timestamp
        });

        nextJobId++;
        emit JobCreated(jobId, msg.sender, _jobDataCID, _paymentAmountGPUCredit, _deadlineTimestamp);
    }

    /**
     * @notice Client claims the job as complete and releases payment to the provider.
     * @param _jobId The ID of the job.
     */
    function claimPaymentAndCompleteJob(uint256 _jobId)
        public
        nonReentrant
        onlyJobClient(_jobId)
    {
        Job storage job = jobs[_jobId]; // Existence and client check by modifier
        if (job.status != JobStatus.ResultSubmitted) revert InvalidJobStatus(job.status, JobStatus.ResultSubmitted);
        if (job.provider == address(0)) revert ProviderNotRegisteredOrInsufficientStake(); // Should not happen if ResultSubmitted

        uint256 paymentToProvider = job.maxPaymentGPUCredit;
        // Optional: Platform Fee Logic
        // uint256 feeAmount = (paymentToProvider * platformFeePercentageBPS) / 10000;
        // if (feeAmount > 0) {
        //     paymentToProvider -= feeAmount;
        //     bool feeSuccess = jobPaymentToken.transfer(platformFeeRecipient, feeAmount);
        //     if (!feeSuccess) revert TokenTransferFailed(); // Or handle differently
        // }

        job.status = JobStatus.Completed;

        // Rate provider as successful. JobManager needs RATER_ROLE on ProviderRegistry.
        providerRegistry.rate(job.provider, true);

        emit JobCompletedAndPaid(_jobId, job.provider, paymentToProvider);

        // Transfer payment to provider
        bool success = jobPaymentToken.transfer(job.provider, paymentToProvider);
        if (!success) {
            // If payment fails, the job is marked Completed but payment is stuck.
            // This is a complex failure case. For v0, a revert might be chosen,
            // but it leaves the job in ResultSubmitted state.
            // A better approach might be an admin recovery or allowing provider to retry claim.
            // For now, let's revert, which means client can try again.
            revert TokenTransferFailed();
        }
    }

    /**
     * @notice Allows a client to cancel their job if it hasn't been accepted yet.
     * @dev Refunds escrowed GPUCredits.
     * @param _jobId The ID of the job to cancel.
     */
    function cancelJob(uint256 _jobId) public nonReentrant onlyJobClient(_jobId) {
        Job storage job = jobs[_jobId]; // Existence and client check by modifier

        // Only allow cancellation if job is still in Created state
        if (job.status != JobStatus.Created) {
            revert InvalidJobStatus(job.status, JobStatus.Created);
        }
        // Alternative: Allow cancellation if deadline passed and not yet fully completed? More complex.

        uint256 refundAmount = job.maxPaymentGPUCredit;
        job.status = JobStatus.Cancelled;
        // job.maxPaymentGPUCredit = 0; // Optionally clear the amount in the struct

        emit JobCancelled(_jobId, msg.sender, refundAmount);

        // Refund GPUCredits to client
        bool success = jobPaymentToken.transfer(job.client, refundAmount);
        if (!success) {
            // If refund fails, job is Cancelled but funds are stuck.
            // This is a critical issue. Reverting keeps funds in escrow but job not truly cancelled.
            // An admin recovery function might be needed for such cases.
            // For v0, a revert is the simplest way to indicate failure.
            revert TokenTransferFailed();
        }
    }


    // --- Provider Functions ---

    /**
     * @notice Allows a registered provider to accept a created job.
     * @param _jobId The ID of the job to accept.
     */
    function acceptJob(uint256 _jobId) public nonReentrant {
        Job storage job = jobs[_jobId];
        if (job.client == address(0)) revert JobNotFound(); // Check if job ID is valid
        if (job.status != JobStatus.Created) revert InvalidJobStatus(job.status, JobStatus.Created);
        if (job.deadlineTimestamp <= block.timestamp) revert DeadlinePassed();
        if (job.provider != address(0)) revert JobAlreadyHasProvider(); // Ensure not already accepted

        // Check provider registration and stake via ProviderRegistry
        ProviderRegistry.ProviderInfo memory providerInfo = providerRegistry.getProviderInfo(msg.sender);
        if (!providerInfo.exists || providerInfo.stakeAmount < minProviderStakeRequired) {
            revert ProviderNotRegisteredOrInsufficientStake();
        }

        job.provider = msg.sender;
        job.status = JobStatus.Accepted;

        emit JobAccepted(_jobId, msg.sender);
    }

    /**
     * @notice Provider submits the result (e.g., IPFS CID of output/proof).
     * @param _jobId The ID of the job.
     * @param _resultDataCID IPFS CID of the job result/proof.
     */
    function submitJobResult(uint256 _jobId, string memory _resultDataCID)
        public
        nonReentrant
        // onlyJobProvider(_jobId) // Using custom check below for clearer error
    {
        Job storage job = jobs[_jobId];
        if (job.client == address(0)) revert JobNotFound(); // Check if job ID is valid
        if (job.provider != msg.sender) revert OnlyAssignedProviderCanSubmit(); // Modified from onlyJobProvider
        if (job.status != JobStatus.Accepted) revert InvalidJobStatus(job.status, JobStatus.Accepted);
        if (job.deadlineTimestamp <= block.timestamp) {
            // If deadline passed, provider failed. JobManager (via admin or automated process)
            // might need to slash the provider and refund the client or allow client to cancel.
            // For v0, we just prevent submission. Provider can be rated negatively by client not claiming.
            // Or JobManager could have a function for client to mark as 'failed by provider'.
            providerRegistry.rate(job.provider, false); // Rate negatively if deadline missed for submission
            revert DeadlinePassed();
        }

        job.resultDataCID = _resultDataCID;
        job.status = JobStatus.ResultSubmitted;

        emit JobResultSubmitted(_jobId, msg.sender, _resultDataCID);
    }


    // --- Admin Functions (Step 3 from plan) ---

    /**
     * @notice Sets the minimum stake (in GPUCredit) required for a provider to accept jobs.
     * @param _newMinStake The new minimum stake amount.
     */
    function setMinProviderStakeRequired(uint256 _newMinStake) public onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldStake = minProviderStakeRequired;
        minProviderStakeRequired = _newMinStake;
        emit MinProviderStakeRequiredChanged(oldStake, _newMinStake);
    }

    // Optional: Update ProviderRegistry or JobPaymentToken addresses (requires careful consideration)
    // function setProviderRegistryAddress(address _newAddress) public onlyRole(DEFAULT_ADMIN_ROLE) {
    //     if (_newAddress == address(0)) revert("Cannot set to zero address");
    //     providerRegistry = IProviderRegistry(_newAddress);
    // }
    // function setJobPaymentTokenAddress(address _newAddress) public onlyRole(DEFAULT_ADMIN_ROLE) {
    //     if (_newAddress == address(0)) revert("Cannot set to zero address");
    //     jobPaymentToken = IERC20(_newAddress);
    // }

    // Optional: Platform Fee Configuration
    // function setPlatformFee(uint16 _newFeeBPS, address _newRecipient) public onlyRole(DEFAULT_ADMIN_ROLE) {
    //     if (_newRecipient == address(0)) revert("Recipient cannot be zero address");
    //     if (_newFeeBPS > 10000) revert("Fee cannot exceed 100%"); // Max 10000 BPS for 100%
    //     emit PlatformFeeChanged(platformFeePercentageBPS, _newFeeBPS, platformFeeRecipient, _newRecipient);
    //     platformFeePercentageBPS = _newFeeBPS;
    //     platformFeeRecipient = _newRecipient;
    // }

    // --- View Functions ---
    function getJob(uint256 _jobId) public view returns (Job memory) {
        if (jobs[_jobId].client == address(0)) revert JobNotFound(); // Ensure job exists
        return jobs[_jobId];
    }
}