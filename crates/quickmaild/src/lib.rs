//! QuickMail daemon implementation.

pub mod daemon;
// Provider constructors are wired by the production factory in the next
// integration step; keep their independently tested protocol surfaces private.
#[allow(dead_code)]
pub mod providers;
pub mod storage;
