// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol"; // Correct path for OZ v5+

import "./ProviderRegistry.sol";

// Interface definition moved outside the contract
interface IProviderRegistry {
    function getProviderInfo(address _provider) external view returns (ProviderRegistry.ProviderInfo memory);
    function slash(address _provider, uint256 _amount) external;
    function rate(address _provider, bool _success) external;
}

contract JobManager is AccessControl, ReentrancyGuard {

    enum JobStatus {
        Created,
        Accepted,
        ResultSubmitted,
        Completed,
        Cancelled,
        Disputed
    }

    struct Job {
        uint256 id;
        address client;
        address provider;
        string jobDataCID;
        uint256 maxPaymentGPUCredit;
        uint256 deadlineTimestamp;
        JobStatus status;
        string resultDataCID;
        uint256 creationTimestamp;
    }

    IProviderRegistry public providerRegistry;
    IERC20 public jobPaymentToken;

    mapping(uint256 => Job) public jobs;
    uint256 public nextJobId;
    uint256 public minProviderStakeRequired;

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

    error JobNotFound();
    error NotJobClient();
    error NotJobProvider();
    error InvalidJobStatus(JobStatus current, JobStatus required);
    error TokenTransferFailed();
    error DeadlinePassed();
    error DeadlineMustBeInFuture();
    error ProviderNotRegisteredOrInsufficientStake();
    error OnlyAssignedProviderCanSubmit(); // Changed from OnlyProviderCanSubmit for clarity
    error OnlyClientCanClaim();
    error EscrowAmountZero();
    error JobAlreadyHasProvider();

    constructor(
        address _providerRegistryAddress,
        address _jobPaymentTokenAddress,
        address _initialAdmin
    ) {
        if (_providerRegistryAddress == address(0)) revert("ProviderRegistry address cannot be zero");
        if (_jobPaymentTokenAddress == address(0)) revert("JobPaymentToken address cannot be zero");
        if (_initialAdmin == address(0)) revert("Initial admin address cannot be zero");

        providerRegistry = IProviderRegistry(_providerRegistryAddress);
        jobPaymentToken = IERC20(_jobPaymentTokenAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        minProviderStakeRequired = 0;
    }

    modifier onlyJobClient(uint256 _jobId) {
        if (jobs[_jobId].client == address(0)) revert JobNotFound();
        if (jobs[_jobId].client != msg.sender) revert NotJobClient();
        _;
    }

    modifier onlyJobProvider(uint256 _jobId) {
        if (jobs[_jobId].provider == address(0)) revert JobNotFound(); // Or specific error like JobNotAssigned
        if (jobs[_jobId].provider != msg.sender) revert NotJobProvider();
        _;
    }

    // --- Client Functions ---
    function createJob(
        string memory _jobDataCID,
        uint256 _paymentAmountGPUCredit,
        uint256 _deadlineTimestamp
    ) public nonReentrant returns (uint256 jobId) { // <<<<< FIXED: Added returns (uint256 jobId)
        if (_paymentAmountGPUCredit == 0) revert EscrowAmountZero();
        if (_deadlineTimestamp <= block.timestamp) revert DeadlineMustBeInFuture();

        bool success = jobPaymentToken.transferFrom(msg.sender, address(this), _paymentAmountGPUCredit);
        if (!success) revert TokenTransferFailed();

        jobId = nextJobId; // Assign to the named return variable
        jobs[jobId] = Job({
            id: jobId,
            client: msg.sender,
            provider: address(0),
            jobDataCID: _jobDataCID,
            maxPaymentGPUCredit: _paymentAmountGPUCredit,
            deadlineTimestamp: _deadlineTimestamp,
            status: JobStatus.Created,
            resultDataCID: "",
            creationTimestamp: block.timestamp
        });

        nextJobId++;
        emit JobCreated(jobId, msg.sender, _jobDataCID, _paymentAmountGPUCredit, _deadlineTimestamp);
        // Implicitly returns jobId because it's a named return variable and assigned.
    }

    function claimPaymentAndCompleteJob(uint256 _jobId)
        public
        nonReentrant
        onlyJobClient(_jobId)
    {
        Job storage job = jobs[_jobId];
        if (job.status != JobStatus.ResultSubmitted) revert InvalidJobStatus(job.status, JobStatus.ResultSubmitted);
        if (job.provider == address(0)) revert ProviderNotRegisteredOrInsufficientStake(); // Should be caught by status check

        uint256 paymentToProvider = job.maxPaymentGPUCredit;
        job.status = JobStatus.Completed;
        providerRegistry.rate(job.provider, true);
        emit JobCompletedAndPaid(_jobId, job.provider, paymentToProvider);

        bool success = jobPaymentToken.transfer(job.provider, paymentToProvider);
        if (!success) {
            revert TokenTransferFailed();
        }
    }

    function cancelJob(uint256 _jobId) public nonReentrant onlyJobClient(_jobId) {
        Job storage job = jobs[_jobId];
        if (job.status != JobStatus.Created) {
            revert InvalidJobStatus(job.status, JobStatus.Created);
        }

        uint256 refundAmount = job.maxPaymentGPUCredit;
        job.status = JobStatus.Cancelled;
        // job.maxPaymentGPUCredit = 0; // Optional

        emit JobCancelled(_jobId, msg.sender, refundAmount);

        bool success = jobPaymentToken.transfer(job.client, refundAmount);
        if (!success) {
            revert TokenTransferFailed();
        }
    }

    // --- Provider Functions ---
    function acceptJob(uint256 _jobId) public nonReentrant {
        Job storage job = jobs[_jobId];
        if (job.client == address(0)) revert JobNotFound();
        if (job.status != JobStatus.Created) revert InvalidJobStatus(job.status, JobStatus.Created);
        if (job.deadlineTimestamp <= block.timestamp) revert DeadlinePassed();
        if (job.provider != address(0)) revert JobAlreadyHasProvider();

        ProviderRegistry.ProviderInfo memory providerInfo = providerRegistry.getProviderInfo(msg.sender);
        if (!providerInfo.exists || providerInfo.stakeAmount < minProviderStakeRequired) {
            revert ProviderNotRegisteredOrInsufficientStake();
        }

        job.provider = msg.sender;
        job.status = JobStatus.Accepted;
        emit JobAccepted(_jobId, msg.sender);
    }

    function submitJobResult(uint256 _jobId, string memory _resultDataCID)
        public
        nonReentrant
    {
        Job storage job = jobs[_jobId];
        if (job.client == address(0)) revert JobNotFound();
        if (job.provider != msg.sender) revert OnlyAssignedProviderCanSubmit();
        if (job.status != JobStatus.Accepted) revert InvalidJobStatus(job.status, JobStatus.Accepted);

        if (job.deadlineTimestamp <= block.timestamp) {
            providerRegistry.rate(job.provider, false);
            revert DeadlinePassed();
        }

        job.resultDataCID = _resultDataCID;
        job.status = JobStatus.ResultSubmitted;
        emit JobResultSubmitted(_jobId, msg.sender, _resultDataCID);
    }

    // --- Admin Functions ---
    function setMinProviderStakeRequired(uint256 _newMinStake) public onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldStake = minProviderStakeRequired;
        minProviderStakeRequired = _newMinStake;
        emit MinProviderStakeRequiredChanged(oldStake, _newMinStake);
    }

    // --- View Functions ---
    function getJob(uint256 _jobId) public view returns (Job memory) {
        if (jobs[_jobId].client == address(0)) revert JobNotFound();
        return jobs[_jobId];
    }
}