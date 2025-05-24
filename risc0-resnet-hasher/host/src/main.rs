use dotenv::dotenv;
use eyre::Result;
use std::env;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use ethers::{
    prelude::*,
    utils::keccak256,
};

// Risc Zero 1.0.x style imports
use risc0_zkvm::{
    default_prover, ExecutorEnv, ProverOpts,
    ProveInfo, Receipt, InnerReceipt,
    // Journal, // Not needed as zk_full_receipt.journal is already this type
};
use methods::{
    JobInputs,
    JobOutputs,
    RISC0_RESNET_HASHER_ELF,
    RISC0_RESNET_HASHER_ID,
};
use risc0_zkvm::serde::to_vec as risc0_to_vec;

// Contract Bindings
abigen!(
    GPUCreditContract,
    "./abi/GPUCredit.json",
    event_derives (serde::Deserialize, serde::Serialize)
);
abigen!(
    JobManagerContract,
    "./abi/JobManager.json",
    event_derives (serde::Deserialize, serde::Serialize)
);
abigen!(
    ProviderRegistryContract,
    "./abi/ProviderRegistry.json",
    event_derives (serde::Deserialize, serde::Serialize)
);

// Constants
const DEFAULT_ARBITRUM_SEPOLIA_CHAIN_ID: u64 = 421614;
const ONE_DAY_IN_SECONDS_U64: u64 = 24 * 60 * 60;
// PROVIDER_STAKE_AMOUNT_WEIS will be U256 directly where used

// Helper
fn method_id_to_bytes_array(method_id: &[u32; 8]) -> [u8; 32] {
    let mut bytes = [0u8; 32];
    for (i, word) in method_id.iter().enumerate() {
        bytes[i * 4..(i + 1) * 4].copy_from_slice(&word.to_le_bytes());
    }
    bytes
}

#[tokio::main]
async fn main() -> Result<()> {
    dotenv().ok();

    // --- Load Configuration ---
    let rpc_url = env::var("TESTNET_RPC_URL").expect("TESTNET_RPC_URL not set");
    let provider_private_key_str = env::var("PROVIDER_PRIVATE_KEY").expect("PROVIDER_PRIVATE_KEY not set");
    let client_private_key_str = env::var("CLIENT_PRIVATE_KEY").expect("CLIENT_PRIVATE_KEY not set");
    let gpu_credit_address_str = env::var("GPU_CREDIT_ADDRESS").expect("GPU_CREDIT_ADDRESS not set");
    let job_manager_address_str = env::var("JOB_MANAGER_ADDRESS").expect("JOB_MANAGER_ADDRESS not set");
    let provider_registry_address_str = env::var("PROVIDER_REGISTRY_ADDRESS")
        .expect("PROVIDER_REGISTRY_ADDRESS not set (can be address(0) string if not used by JobManager)");
    let chain_id: u64 = env::var("CHAIN_ID")
        .unwrap_or_else(|_| DEFAULT_ARBITRUM_SEPOLIA_CHAIN_ID.to_string()).parse()?;

    println!("Host Program - Week 7 (Provider Staking & R0 Groth16 Proof)");
    println!("Using RPC URL: {}", rpc_url);
    println!("Chain ID: {}", chain_id);

    // --- Setup Ethers Provider and Signers ---
    let http_provider = Provider::<Http>::try_from(rpc_url)?;
    let arc_provider = Arc::new(http_provider);
    let client_wallet = client_private_key_str.parse::<LocalWallet>()?.with_chain_id(chain_id);
    let client_signer = Arc::new(SignerMiddleware::new(arc_provider.clone(), client_wallet.clone()));
    let provider_wallet = provider_private_key_str.parse::<LocalWallet>()?.with_chain_id(chain_id);
    let provider_signer = Arc::new(SignerMiddleware::new(arc_provider.clone(), provider_wallet.clone()));
    
    println!("Client Address: {:?}", client_signer.address());
    println!("Provider Address: {:?}", provider_signer.address());

    // --- Parse Contract Addresses ---
    let gpu_credit_address: Address = gpu_credit_address_str.parse()?;
    let job_manager_address: Address = job_manager_address_str.parse()?;
    let provider_registry_address: Address = provider_registry_address_str.parse()?;
    
    println!("GPUCredit Address: {:?}", gpu_credit_address);
    println!("JobManager Address: {:?}", job_manager_address);
    println!("ProviderRegistry Address: {:?}", provider_registry_address);

    // --- Instantiate Contract Clients ---
    let gpu_credit_client_contract = GPUCreditContract::new(gpu_credit_address, client_signer.clone());
    let job_manager_client_contract = JobManagerContract::new(job_manager_address, client_signer.clone());
    let gpu_credit_provider_contract = GPUCreditContract::new(gpu_credit_address, provider_signer.clone());
    let provider_registry_provider_contract = ProviderRegistryContract::new(provider_registry_address, provider_signer.clone());
    let job_manager_provider_contract = JobManagerContract::new(job_manager_address, provider_signer.clone());

    // --- Provider Staking Setup ---
    let desired_stake_amount = U256::from(5) * U256::from(10).pow(U256::from(18)); // 1000 GPUCredit as U256

    if provider_registry_address != Address::zero() {
        println!("\n--- Provider Staking Phase ---");
        let provider_gcredit_balance = gpu_credit_provider_contract.balance_of(provider_signer.address()).call().await?;
        println!("Provider current GPUCredit balance: {}", ethers::utils::format_units(provider_gcredit_balance, "ether")?);

        if provider_gcredit_balance < desired_stake_amount {
            eyre::bail!("Provider has insufficient GPUCredit ({}) to meet desired stake ({}). Please mint tokens.",
                ethers::utils::format_units(provider_gcredit_balance, "ether")?,
                ethers::utils::format_units(desired_stake_amount, "ether")?);
        }

        let provider_info_before_stake = provider_registry_provider_contract
            .get_provider_info(provider_signer.address())
            .call().await?;
        println!("Provider current stake: {}, Exists: {}", provider_info_before_stake.stake_amount, provider_info_before_stake.exists);

        if !provider_info_before_stake.exists || provider_info_before_stake.stake_amount < desired_stake_amount {
            println!("Provider needs to stake or increase stake to {}.", ethers::utils::format_units(desired_stake_amount, "ether")?);
            let amount_to_stake_now = desired_stake_amount; // Stake the full desired amount

            println!("Provider approving {} GPUCredit for ProviderRegistry...", ethers::utils::format_units(amount_to_stake_now, "ether")?);
            let approve_stake_call = gpu_credit_provider_contract.approve(provider_registry_address, amount_to_stake_now);
            let approve_stake_receipt = approve_stake_call.send().await?.await?.ok_or_else(|| eyre::eyre!("Stake approval tx mined but no receipt"))?;
            if approve_stake_receipt.status != Some(1.into()) { eyre::bail!("GPUCredit approval for staking FAILED. Tx: {:?}", approve_stake_receipt.transaction_hash); }
            println!("Stake approval successful. Tx: {:?}", approve_stake_receipt.transaction_hash);

            println!("Provider calling stake() on ProviderRegistry with amount: {}", amount_to_stake_now);
            let stake_call = provider_registry_provider_contract.stake(amount_to_stake_now);
            let stake_receipt = stake_call.send().await?.await?.ok_or_else(|| eyre::eyre!("Staking tx mined but no receipt"))?;
            if stake_receipt.status != Some(1.into()) { eyre::bail!("Provider's stake() transaction FAILED. Tx: {:?}", stake_receipt.transaction_hash); }
            println!("Provider stake successful. Tx: {:?}", stake_receipt.transaction_hash);
            
            println!("Waiting 15 seconds for stake state to propagate...");
            tokio::time::sleep(Duration::from_secs(15)).await;

            let provider_info_after_stake = provider_registry_provider_contract.get_provider_info(provider_signer.address()).call().await?;
            println!("Provider Info after stake: exists={}, stakeAmount={}", provider_info_after_stake.exists, provider_info_after_stake.stake_amount);
            if !provider_info_after_stake.exists || provider_info_after_stake.stake_amount < desired_stake_amount {
                 eyre::bail!("Stake amount still insufficient after staking attempt.");
            }
        } else {
            println!("Provider ({:?}) already has sufficient stake: {}", provider_signer.address(), provider_info_before_stake.stake_amount);
        }
    } else {
        println!("\nProviderRegistry not configured. Skipping provider staking.");
    }

    // --- Step A: Client Approves GPUCredit and Creates Job ---
    let job_reward = U256::from(10) * U256::from(10).pow(U256::from(18));
    let job_cid_str = "QmRisc0StakingAndProofJob";
    let risc0_method_id_as_bytes_array: [u8; 32] = method_id_to_bytes_array(&RISC0_RESNET_HASHER_ID);
    let current_timestamp_secs = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let deadline_timestamp_ethers = U256::from(current_timestamp_secs + ONE_DAY_IN_SECONDS_U64);

    println!("\nClient approving GPUCredit for JobManager...");
    gpu_credit_client_contract.approve(job_manager_address, job_reward).send().await?.await?.ok_or_else(|| eyre::eyre!("Approve tx failed"))?;
    println!("GPUCredit approved.");
    println!("Client creating job on JobManager...");
    let create_job_call = job_manager_client_contract.create_job(
        job_cid_str.to_string(), job_reward, deadline_timestamp_ethers, risc0_method_id_as_bytes_array.into());
    let job_creation_receipt = create_job_call.send().await?.await?.ok_or_else(|| eyre::eyre!("Create job tx failed"))?;
    println!("Job created! Tx hash: {:?}", job_creation_receipt.transaction_hash);
    
    let mut parsed_job_id_opt: Option<U256> = None; /* ... your robust parsing ... */
    let event_name_to_decode = "JobCreated";
    let job_created_event_signature_topic0 = job_manager_client_contract.abi().event(event_name_to_decode)?.signature();
    for log_entry in job_creation_receipt.logs.iter() {
        if log_entry.address == job_manager_address && !log_entry.topics.is_empty() && log_entry.topics[0] == job_created_event_signature_topic0 {
            if log_entry.topics.len() > 1 { parsed_job_id_opt = Some(U256::from_big_endian(log_entry.topics[1].as_bytes())); break; }
        }
    }
    let job_id = parsed_job_id_opt.ok_or_else(|| eyre::eyre!("Failed to parse JobId. Logs: {:?}", job_creation_receipt.logs))?;
    println!("Using Job ID: {}", job_id);

    // --- Provider Accepts the Job ---
    println!("\nProvider ({:?}) reading on-chain job #{} details before accepting...", provider_signer.address(), job_id);
    let job_details_before_accept: job_manager_contract::Job = job_manager_provider_contract.get_job(job_id).call().await?;
    println!("  On-chain client:   {:?}", job_details_before_accept.client);
    println!("  On-chain provider: {:?}", job_details_before_accept.provider);
    println!("  On-chain status:   {:?}", job_details_before_accept.status); // This is U256

    if job_details_before_accept.provider != Address::zero() {
        eyre::bail!("Job {} ALREADY HAS PROVIDER before acceptJob. State unclean.", job_id);
    }
    // Assuming job_details_before_accept.status is U256 from abigen
    if job_details_before_accept.status != 0u8  { // Compare U256 with U256 from u8
         eyre::bail!("Job {} not in 'Created' status (0). Status: {}. Aborting.", job_id, job_details_before_accept.status);
    }

    println!("Provider attempting to accept Job ID: {}...", job_id);
    let accept_job_call = job_manager_provider_contract.accept_job(job_id);
    let estimated_gas_accept_job = match accept_job_call.estimate_gas().await {
        Ok(gas) => { println!("Estimated gas for acceptJob: {}", gas); gas * 12 / 10 }
        Err(e) => { println!("Gas estimation for acceptJob FAILED: {:?}. Fallback.", e); U256::from(800_000) }
    };
    let prepared_accept_tx = accept_job_call.gas(estimated_gas_accept_job);
    let pending_accept_tx = prepared_accept_tx.send().await?;
    let accept_job_receipt = pending_accept_tx.await?.ok_or_else(|| eyre::eyre!("Accept job tx not mined"))?;

    if accept_job_receipt.status == Some(1.into()) { // 1.into() gives U64::from(1)
        println!("Job ID: {} accepted. Tx: {:?}", job_id, accept_job_receipt.transaction_hash);
        println!("Waiting 30 seconds for state propagation...");
        tokio::time::sleep(Duration::from_secs(30)).await;
    } else {
        eyre::bail!("acceptJob for Job ID {} REVERTED. Tx: {:?}. Check Arbiscan.", job_id, accept_job_receipt.transaction_hash);
    }

    // --- Step B: Provider Generates Groth16 SNARK-Wrapped STARK Proof ---
    println!("\nProvider generating SNARK-wrapped STARK proof for Job ID: {}", job_id);
    let zk_guest_inputs = JobInputs { image_batch_data: vec![1u8; 1024], model_weights_data: vec![2u8; 2048] };
    let serialized_zk_inputs = risc0_to_vec(&zk_guest_inputs)?;
    let env = ExecutorEnv::builder().write_slice(&serialized_zk_inputs).build().map_err(|e| eyre::eyre!("Env build: {:?}", e))?;
    
    println!("Running Risc Zero prover with ProverOpts::groth16()...");
    let opts = ProverOpts::groth16();
    let prove_info_data: ProveInfo = default_prover().prove_with_opts(env, RISC0_RESNET_HASHER_ELF, &opts)
        .map_err(|e| eyre::eyre!("R0 proving (groth16): {:?}", e))?;
    let zk_full_receipt: Receipt = prove_info_data.receipt;
    println!("R0 proof (groth16 wrapper) successful.");

    // --- Step C: Provider Extracts Groth16 Seal and Prepares Data ---
    println!("Extracting Groth16 seal from receipt...");
    let groth16_seal_bytes: Vec<u8> = match zk_full_receipt.inner {
        InnerReceipt::Groth16(g16_data) => g16_data.seal.clone(),
        _ => eyre::bail!("Expected Groth16 InnerReceipt, found: {:?}.", zk_full_receipt.inner),
    };
    let seal_for_contract = Bytes::from(groth16_seal_bytes);
    println!("Groth16 Seal extracted. Size: {} bytes", seal_for_contract.len());
    
    let journal_bytes_for_hash: Vec<u8> = zk_full_receipt.journal.bytes.clone(); // Access .bytes field directly
    let journal_hash_for_contract_array: [u8; 32] = keccak256(&journal_bytes_for_hash);
    println!("JournalHash for contract: 0x{}", hex::encode(journal_hash_for_contract_array));

    // --- Step D: Provider Submits Groth16 SNARK Proof to JobManager ---
    let provider_balance_before_submit = gpu_credit_provider_contract.balance_of(provider_signer.address()).call().await?;
    println!("\nProvider GPUCredit balance before submit: {}", ethers::utils::format_units(provider_balance_before_submit, "ether")?);
    let result_cid_for_contract = "QmRisc0Groth16FinalResult";
    println!("Provider submitting proof data to JobManager (Job ID: {})...", job_id);
    let submit_proof_call = job_manager_provider_contract.submit_proof_and_claim(
        job_id, seal_for_contract.clone(), journal_hash_for_contract_array.into(), result_cid_for_contract.to_string());
    let estimated_gas_submit = match submit_proof_call.estimate_gas().await {
        Ok(gas) => { println!("Estimated gas for submitProofAndClaim (Groth16): {}", gas); gas * 12 / 10 }
        Err(e) => { println!("Gas estimation for submitProofAndClaim (Groth16) FAILED: {:?}. Fallback.", e); U256::from(3_000_000) }
    };
    let prepared_submit_tx = submit_proof_call.gas(estimated_gas_submit);
    let pending_submit_tx = prepared_submit_tx.send().await?;
    let submit_proof_receipt_mined = pending_submit_tx.await?.ok_or_else(|| eyre::eyre!("Submit proof tx not mined"))?;
    
    if submit_proof_receipt_mined.status == Some(1.into()) {
        println!("Proof data submitted and transaction SUCCEEDED! Tx: {:?}", submit_proof_receipt_mined.transaction_hash);
    } else {
        eyre::bail!("submitProofAndClaim for Job ID {} REVERTED. Tx: {:?}. Check Arbiscan.", job_id, submit_proof_receipt_mined.transaction_hash);
    }

    // --- Step E: Check Provider's GPUCredit Balance After Reward ---
    tokio::time::sleep(Duration::from_secs(10)).await;
    let provider_balance_after_submit = gpu_credit_provider_contract.balance_of(provider_signer.address()).call().await?;
    if provider_balance_after_submit > provider_balance_before_submit {
        println!("✅ Success! Provider received GPUCredit. On-chain ZK verification passed!");
    } else {
        println!("❌ Error: Provider balance did not increase AFTER successful submitProofAndClaim tx. Check payment logic in contract or events.");
    }

    // --- Sanity Check Guest Outputs ---
    let guest_outputs: JobOutputs = zk_full_receipt.journal.decode().map_err(|e| eyre::eyre!("Journal decode failed: {:?}", e))?;
    println!("\n--- Guest Public Outputs (from Risc0 Journal) ---");
    println!("Image Batch Hash:      0x{}", hex::encode(guest_outputs.image_batch_hash));
    println!("Model Weights Hash:    0x{}", hex::encode(guest_outputs.model_weights_hash));
    println!("Computation Out Hash:  0x{}", hex::encode(guest_outputs.computation_output_hash));

    Ok(())
}