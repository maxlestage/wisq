//! wisq's local virtual machine: an interpreted rv32ima that boots a real
//! Linux kernel, with no JIT and no platform dependencies.
//!
//! Rust here is not a preference, it is the shape of the problem. This is pure
//! computation over a byte array with a small device model bolted on: no UI, no
//! platform framework, nothing that wants a runtime. That makes it the part of
//! wisq that can be one implementation compiled for every target — the iPhone
//! app links it as a static library through [`ffi`], the host tools link it as
//! a normal crate, and the benchmark measures the same code all of them run.

pub mod core;
pub mod desktop;
pub mod dtb;
pub mod ffi;
pub mod kernel_image;
pub mod machine;
pub mod snapshot;
pub mod store;
pub mod virtio;
pub mod x86;
pub mod x86_wasm;

pub use crate::core::{Bus, Core, StepResult, RAM_BASE};
pub use crate::machine::{Handle, LoadError, Machine, Outcome, OutputSink, DEFAULT_RAM_SIZE};
pub use crate::snapshot::SnapshotError;
