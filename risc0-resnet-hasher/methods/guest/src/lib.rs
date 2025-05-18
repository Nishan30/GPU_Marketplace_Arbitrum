// methods/guest/src/lib.rs
#![no_std]
extern crate alloc; // If JobInputs/JobOutputs use Vec, etc.

use serde::{Deserialize, Serialize};
use alloc::vec::Vec; // Assuming your structs use Vec<u8>

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JobInputs {
    pub image_batch_data: Vec<u8>,
    pub model_weights_data: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct JobOutputs {
    pub image_batch_hash: [u8; 32],
    pub model_weights_hash: [u8; 32],
    pub computation_output_hash: [u8; 32],
}