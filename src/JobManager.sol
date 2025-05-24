// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20; // Compatible with Risc0 contracts & OpenZeppelin v5

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Assuming ProviderRegistry.sol is in the same directory or path is adjusted
// If not using ProviderRegistry, you can comment out related lines and set its address to address(0)
import "./ProviderRegistry.sol";

// Import Risc Zero Verifier Interface - adjust path if risc0 contracts are in a subdir
// e.g., if you copied risc0-ethereum/contracts/src to ./risc0/
import "./risc0/groth16/RiscZeroGroth16Verifier.sol";

// Interface for ProviderRegistry (if used)
interface IProviderRegistry {
    function getProviderInfo(address _provider) external view returns (ProviderRegistry.ProviderInfo memory);
    function slash(address _provider, uint256 _amount) external;
    function rate(address _provider, bool _success) external;
}

contract JobManager is AccessControl, ReentrancyGuard {

    enum JobStatus {
        Created,        // Job created by client, payment escrowed
        Accepted,       // Provider accepted the job
        // ResultSubmitted, // Could be an intermediate step if result CID is submitted before proof
        Completed,      // Proof verified, provider paid
        Cancelled,      // Job cancelled by client (if allowed)
        Disputed        // Future: For dispute resolution
    }

    struct Job {
        uint256 id;
        address client;
        address provider;
        string jobDataCID;          // CID of input data/model
        uint256 maxPaymentGPUCredit; // Escrowed payment
        uint256 deadlineTimestamp;   // Deadline for proof submission
        JobStatus status;
        string resultDataCID;       // CID of output data from provider
        uint256 creationTimestamp;
        bytes32 methodId;           // Risc0 MethodID (ImageID) for this job's ZK program
    }

    IRiscZeroVerifier public verifier;         // Risc Zero Verifier (Router)
    IERC20 public jobPaymentToken;             // GPUCredit ERC20 token
    IProviderRegistry public providerRegistry; // Optional: For provider staking/rating

    mapping(uint256 => Job) public jobs;
    uint256 public nextJobId;
    uint256 public minProviderStakeRequired; // If using ProviderRegistry

    // --- Events ---
    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        string jobDataCID,
        uint256 maxPaymentGPUCredit,
        uint256 deadlineTimestamp,
        bytes32 indexed methodId // Risc0 MethodID
    );
    event JobAccepted(uint256 indexed jobId, address indexed provider);
    event JobProofVerified(uint256 indexed jobId, address indexed provider, bytes32 methodId, bytes32 journalHash);
    event JobCompletedAndPaid(uint256 indexed jobId, address indexed provider, uint256 paymentAmountGPUCredit);
    event JobCancelled(uint256 indexed jobId, address indexed client, uint256 refundAmountGPUCredit);
    event MinProviderStakeRequiredChanged(uint256 oldStake, uint256 newStake);

    // --- Errors ---
    error JobNotFound();
    error NotJobClient();
    error NotJobProvider();
    error InvalidJobStatus(JobStatus current, JobStatus required);
    error TokenTransferFailed();
    error DeadlinePassed();
    error DeadlineMustBeInFuture();
    error ProviderNotRegisteredOrInsufficientStake(); // If using ProviderRegistry
    error OnlyAssignedProviderCanSubmit();
    error EscrowAmountZero();
    error JobAlreadyHasProvider();
    error ZKProofVerificationFailed();
    error MethodIdMismatch(); // Should not happen if job.methodId is used

    constructor(
        address _providerRegistryAddress,   // Set to address(0) if not using ProviderRegistry
        address _jobPaymentTokenAddress,
        address _risc0VerifierRouterAddress, // Address of deployed RiscZeroVerifierRouter
        address _initialAdmin
    ) {
        if (_jobPaymentTokenAddress == address(0)) revert("JobPaymentToken address cannot be zero");
        if (_risc0VerifierRouterAddress == address(0)) revert("Risc0VerifierRouter address cannot be zero");
        if (_initialAdmin == address(0)) revert("Initial admin address cannot be zero");

        jobPaymentToken = IERC20(_jobPaymentTokenAddress);
        verifier = IRiscZeroVerifier(_risc0VerifierRouterAddress);

        if (_providerRegistryAddress != address(0)) {
            providerRegistry = IProviderRegistry(_providerRegistryAddress);
        }
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        minProviderStakeRequired = 0; // Default, can be changed by admin
    }

    modifier onlyJobClient(uint256 _jobId) {
        if (jobs[_jobId].client == address(0)) revert JobNotFound(); // Check if job exists
        if (jobs[_jobId].client != msg.sender) revert NotJobClient();
        _;
    }

    modifier onlyJobProvider(uint256 _jobId) {
        if (jobs[_jobId].client == address(0)) revert JobNotFound(); // Check if job exists
        if (jobs[_jobId].provider == address(0)) revert("JobNotAssignedToProvider");
        if (jobs[_jobId].provider != msg.sender) revert NotJobProvider();
        _;
    }

    // --- Client Functions ---
    function createJob(
        string memory _jobDataCID,
        uint256 _paymentAmountGPUCredit,
        uint256 _deadlineTimestamp,
        bytes32 _methodId // Risc0 MethodID (ImageID) for the ZK program
    ) public nonReentrant returns (uint256 jobId) {
        if (_paymentAmountGPUCredit == 0) revert EscrowAmountZero();
        if (_deadlineTimestamp <= block.timestamp) revert DeadlineMustBeInFuture();

        bool success = jobPaymentToken.transferFrom(msg.sender, address(this), _paymentAmountGPUCredit);
        if (!success) revert TokenTransferFailed();

        jobId = nextJobId;
        jobs[jobId] = Job({
            id: jobId,
            client: msg.sender,
            provider: address(0),
            jobDataCID: _jobDataCID,
            maxPaymentGPUCredit: _paymentAmountGPUCredit,
            deadlineTimestamp: _deadlineTimestamp,
            status: JobStatus.Created,
            resultDataCID: "",
            creationTimestamp: block.timestamp,
            methodId: _methodId
        });

        nextJobId++;
        emit JobCreated(jobId, msg.sender, _jobDataCID, _paymentAmountGPUCredit, _deadlineTimestamp, _methodId);
        // return jobId; // Named return variable
    }

    function cancelJob(uint256 _jobId) public nonReentrant onlyJobClient(_jobId) {
        Job storage job = jobs[_jobId];
        // Allow cancellation only if no provider has accepted OR if provider accepted but deadline passed without result
        if (job.status != JobStatus.Created) {
             if (!(job.status == JobStatus.Accepted && job.deadlineTimestamp <= block.timestamp)) {
                revert InvalidJobStatus(job.status, JobStatus.Created); // Or more specific error
             }
        }
        // More complex cancellation logic might be needed (e.g., if provider is actively working)

        uint256 refundAmount = job.maxPaymentGPUCredit;
        job.status = JobStatus.Cancelled;

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

        if (address(providerRegistry) != address(0)) {
            ProviderRegistry.ProviderInfo memory providerInfo = providerRegistry.getProviderInfo(msg.sender);
            if (!providerInfo.exists || providerInfo.stakeAmount < minProviderStakeRequired) {
                revert ProviderNotRegisteredOrInsufficientStake();
            }
        }

        job.provider = msg.sender;
        job.status = JobStatus.Accepted;
        emit JobAccepted(_jobId, msg.sender);
    }

    function submitProofAndClaim(
        uint256 _jobId,
        bytes calldata _seal,        // The GROTH16 proof seal (output of STARK-to-SNARK pipeline)
        bytes32 _journalHash,     // Keccak256 hash of the Risc0 journal's public output
        string memory _resultDataCID  // CID of the actual computation result
    ) public nonReentrant onlyJobProvider(_jobId) { // Ensures job exists and msg.sender is assigned provider
        Job storage job = jobs[_jobId];

        if (job.status != JobStatus.Accepted) revert InvalidJobStatus(job.status, JobStatus.Accepted);
        if (job.deadlineTimestamp <= block.timestamp) {
            if (address(providerRegistry) != address(0)) {
                providerRegistry.rate(job.provider, false); // Penalize for late submission
            }
            revert DeadlinePassed();
        }

        // --- On-chain ZK Proof Verification ---
        // The verifier.verify() function is expected to revert on failure.
        // The imageId (MethodID) for verification is stored in job.methodId
        try verifier.verify(_seal, job.methodId, _journalHash) {
        // good
        } catch {
        revert ZKProofVerificationFailed();
        }
        // If we reach here, the proof is valid.
        emit JobProofVerified(_jobId, msg.sender, job.methodId, _journalHash);


        // --- Proof Valid: Process payment and complete job ---
        job.resultDataCID = _resultDataCID;
        job.status = JobStatus.Completed;

        if (address(providerRegistry) != address(0)) {
            providerRegistry.rate(job.provider, true); // Rate provider as successful
        }

        uint256 paymentToProvider = job.maxPaymentGPUCredit;
        emit JobCompletedAndPaid(_jobId, job.provider, paymentToProvider);

        bool success = jobPaymentToken.transfer(job.provider, paymentToProvider);
        if (!success) {
            // Critical: Proof was valid, payment failed.
            // This state should ideally allow provider to retry claim or require admin intervention.
            // For now, revert. In a real system, you might set a flag like "PaymentPending".
            revert TokenTransferFailed();
        }
    }

    // --- Admin Functions ---
    function setMinProviderStakeRequired(uint256 _newMinStake) public onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 oldStake = minProviderStakeRequired;
        minProviderStakeRequired = _newMinStake;
        emit MinProviderStakeRequiredChanged(oldStake, _newMinStake);
    }

    function setVerifier(address _newVerifierRouterAddress) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newVerifierRouterAddress == address(0)) revert("Risc0VerifierRouter address cannot be zero");
        verifier = IRiscZeroVerifier(_newVerifierRouterAddress);
    }

    function setProviderRegistry(address _newProviderRegistryAddress) public onlyRole(DEFAULT_ADMIN_ROLE) {
        // Allow setting to address(0) if disabling provider registry integration
        providerRegistry = IProviderRegistry(_newProviderRegistryAddress);
    }


    // --- View Functions ---
    function getJob(uint256 _jobId) public view returns (Job memory) {
        if (jobs[_jobId].client == address(0)) revert JobNotFound();
        return jobs[_jobId];
    }

    function getRoleAdmin(bytes32 role) public view override returns (bytes32) {
        return DEFAULT_ADMIN_ROLE;
    }
}