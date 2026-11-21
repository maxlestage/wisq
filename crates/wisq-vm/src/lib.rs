//! wisq's local virtual machine: an interpreted rv32ima that boots a real
//! Linux kernel, with no JIT and no platform dependencies.
//!
//! Rust here is not a preference, it is the shape of the problem. This is pure
//! computation over a byte array with a small device model bolted on: no UI, no
//! platform framework, nothing that wants a runtime. That makes it the part of
//! wisq that can be one implementation compiled for every target — the iPhone
//! app links it as a static library through [`ffi`], the host tools link it as
//! a normal crate, and the benchmark measures the same code all of them run.
//!
//! **La cible `wasm32-unknown-unknown` ne prend que ce qu'une page peut
//! porter.** L'émetteur x86-64 → WebAssembly se compile aussi en WebAssembly,
//! pour tourner dans la page WebKit à côté de la boucle hôte (`crates/wisq-page`)
//! au lieu de répondre par le pont Swift. Quatre modules restent dehors sur
//! cette cible, et seulement sur elle : `ffi` (le C ABI de l'application, que la
//! page n'appelle pas), `store` (des fichiers, par `std::os::unix`, qu'une page
//! n'a pas), et `machine` et `virtio`, la machine rv32 et ses disques, bâtis sur
//! `store`. En natif, rien ne change : ni la liste, ni l'ordre, ni le
//! comportement.

pub mod census;
pub mod core;
pub mod desktop;
pub mod dtb;
pub mod emitter_machine;
#[cfg(not(target_arch = "wasm32"))]
pub mod ffi;
pub mod iso9660;
pub mod kernel_image;
#[cfg(not(target_arch = "wasm32"))]
pub mod machine;
pub mod pc;
pub mod progress;
pub mod rate;
pub mod snapshot;
#[cfg(not(target_arch = "wasm32"))]
pub mod store;
pub mod symbols;
#[cfg(not(target_arch = "wasm32"))]
pub mod virtio;
pub mod x86;
pub mod x86_paging;
pub mod x86_wasm;

pub use crate::core::{Bus, Core, StepResult, RAM_BASE};
#[cfg(not(target_arch = "wasm32"))]
pub use crate::machine::{Handle, LoadError, Machine, Outcome, OutputSink, DEFAULT_RAM_SIZE};
pub use crate::snapshot::SnapshotError;
