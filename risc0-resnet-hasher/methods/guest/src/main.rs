// methods/guest/src/main.rs
#![no_main]
#![no_std]

extern crate alloc;

use alloc::vec::Vec;
// No need to import Box anymore
// use alloc::boxed::Box;

use risc0_zkvm::guest::env;
use risc0_zkvm::sha::Impl as ShaImpl;     // The concrete SHA implementation
use risc0_zkvm::sha::Digest as Risc0Digest; // The Digest type
use risc0_zkvm::sha::Sha256;              // The Sha256 trait

use method::{JobInputs, JobOutputs};

risc0_zkvm::guest::entry!(main);

pub fn main() {
    let inputs: JobInputs = env::read();

    // ShaImpl::hash_bytes returns &'static mut Risc0Digest.
    // We dereference it to get the Risc0Digest value.
    let image_digest_ref: &mut Risc0Digest = ShaImpl::hash_bytes(&inputs.image_batch_data);
    let image_digest_val: Risc0Digest = *image_digest_ref; // Dereference the mutable reference
    let image_hash_bytes: [u8; 32] = image_digest_val.into();

    let weights_digest_ref: &mut Risc0Digest = ShaImpl::hash_bytes(&inputs.model_weights_data);
    let weights_digest_val: Risc0Digest = *weights_digest_ref;
    let weights_hash_bytes: [u8; 32] = weights_digest_val.into();

    let mut combined_hashes_data: Vec<u8> = Vec::new();
    combined_hashes_data.extend_from_slice(&image_hash_bytes);
    combined_hashes_data.extend_from_slice(&weights_hash_bytes);

    let computation_output_digest_ref: &mut Risc0Digest = ShaImpl::hash_bytes(&combined_hashes_data);
    let computation_output_digest_val: Risc0Digest = *computation_output_digest_ref;
    let computation_output_hash_bytes: [u8; 32] = computation_output_digest_val.into();

    let outputs = JobOutputs {
        image_batch_hash: image_hash_bytes,
        model_weights_hash: weights_hash_bytes,
        computation_output_hash: computation_output_hash_bytes,
    };
    env::commit(&outputs);
}