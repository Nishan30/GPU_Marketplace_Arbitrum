// host/src/main.rs
use risc0_zkvm::{default_prover, ExecutorEnv, Receipt,ProveInfo}; // Added ProverOutput
use methods::{ // Assuming you set up re-exports from methods/lib.rs
    JobInputs,
    JobOutputs,
    RISC0_RESNET_HASHER_ELF,
    RISC0_RESNET_HASHER_ID,
};

use serde::{Serialize}; // For JobInputs if defined here or re-exported with Serialize

// If JobInputs/JobOutputs are NOT re-exported from methods, define them here:
// use serde::Deserialize; // Also needed for JobOutputs
// #[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
// pub struct JobOutputs { /* ... fields ... */ }
// #[derive(Debug, Clone, Serialize)]
// pub struct JobInputs { /* ... fields ... */ }


fn main() {
    println!("RISC Zero ResNet Hasher - Host Program");

    // 1. Prepare Input Data
    let dummy_image_batch = vec![1u8; 1024];
    let dummy_model_weights = vec![2u8; 2048];

    let inputs = JobInputs {
        image_batch_data: dummy_image_batch.clone(),
        model_weights_data: dummy_model_weights.clone(),
    };

    // 2. Execute the Guest in the zkVM & Generate Proof
    println!("Setting up ExecutorEnv...");
    let env = ExecutorEnv::builder()
        .write(&inputs)
        .unwrap()
        .build()
        .unwrap();

    println!("Running the prover...");
    let prover = default_prover();
    let prove_info: ProveInfo = prover
        .prove(env, RISC0_RESNET_HASHER_ELF) // Assuming this is the method that returned ProveInfo
        .expect("Proving failed");
    let receipt: Receipt = prove_info.receipt; 
    println!("Proof generated successfully!");

    // 3. Verify the Proof Locally
    println!("Verifying the proof...");
    receipt
        .verify(RISC0_RESNET_HASHER_ID)
        .expect("Proof verification failed! Ensure Method ID and ELF match.");
    println!("Proof verified successfully locally!");

    // 4. Access Public Outputs from the Journal
    let outputs: JobOutputs = receipt.journal.decode().expect("Failed to decode journal output");

    println!("\n--- Guest Public Outputs ---");
    println!("Image Batch Hash:      0x{}", hex::encode(outputs.image_batch_hash));
    println!("Model Weights Hash:    0x{}", hex::encode(outputs.model_weights_hash));
    println!("Computation Out Hash:  0x{}", hex::encode(outputs.computation_output_hash));

    // 5. (Optional) Sanity Check: Calculate Hashes in Host
    use sha2::{Digest, Sha256}; // Ensure sha2 is in host/Cargo.toml

    let mut hasher = Sha256::new();
    hasher.update(&dummy_image_batch);
    let host_image_batch_hash: [u8; 32] = hasher.finalize_reset().into();

    hasher.update(&dummy_model_weights);
    let host_model_weights_hash: [u8; 32] = hasher.finalize_reset().into();

    let mut combined_host_data: Vec<u8> = Vec::new();
    combined_host_data.extend_from_slice(&host_image_batch_hash);
    combined_host_data.extend_from_slice(&host_model_weights_hash);
    hasher.update(&combined_host_data);
    let host_computation_output_hash: [u8; 32] = hasher.finalize().into();

    println!("\n--- Host Calculated Hashes (for comparison) ---");
    println!("Host Image Batch Hash:     0x{}", hex::encode(host_image_batch_hash));
    println!("Host Model Weights Hash:   0x{}", hex::encode(host_model_weights_hash));
    println!("Host Computation Out Hash: 0x{}", hex::encode(host_computation_output_hash));

    assert_eq!(outputs.image_batch_hash, host_image_batch_hash, "Image batch hash mismatch!");
    assert_eq!(outputs.model_weights_hash, host_model_weights_hash, "Model weights hash mismatch!");
    assert_eq!(outputs.computation_output_hash, host_computation_output_hash, "Computation output hash mismatch!");
    println!("\n✅ All hashes match between guest and host verification!");
}