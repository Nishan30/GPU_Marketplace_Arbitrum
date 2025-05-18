include!(concat!(env!("OUT_DIR"), "/methods.rs"));

// methods/src/lib.rs

use risc0_zkvm::sha::DIGEST_WORDS;
pub use method::{JobInputs, JobOutputs};

// Re-export GUEST_ELF under the name your host program expects.
pub const RISC0_RESNET_HASHER_ELF: &[u8] = METHOD_ELF;

// Re-export GUEST_ID under the name your host program expects.
// GUEST_ID is typically already in the [u32; DIGEST_WORDS] format.
pub const RISC0_RESNET_HASHER_ID: [u32; 8] = METHOD_ID;