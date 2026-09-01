//! Provider-neutral contracts shared by the daemon, clients, and adapters.
//!
//! This crate deliberately contains no storage, UI, or credential backend.

pub mod models;
pub mod provider;
pub mod rpc;

pub use models::*;
pub use provider::*;
pub use rpc::*;
