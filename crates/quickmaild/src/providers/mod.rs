//! Remote mail provider adapters.
//!
//! Provider implementations deliberately separate protocol decisions from I/O.
//! The small transport traits in this module make the adapters deterministic in
//! tests and allow the production transports to be replaced without changing
//! synchronization semantics.

pub(crate) mod agenda;
pub(crate) mod auth;
mod factory;
pub(crate) mod gmail;
pub(crate) mod imap_smtp;
pub(crate) mod microsoft_graph;
pub(crate) mod mime;

pub use factory::ProductionProviderFactory;

/// Upper bound for any single remote message or provider response retained in
/// memory. This preserves the existing Gmail transport ceiling and applies the
/// same finite budget to IMAP full-message fetches and MIME parsing.
pub(crate) const MAX_MAIL_MESSAGE_BYTES: usize = 64 * 1024 * 1024;

/// Upper bound for decoded attachment bytes retained or written to the private
/// attachment cache. The daemon checks this even when a provider already did.
pub(crate) const MAX_MAIL_ATTACHMENT_BYTES: usize = 64 * 1024 * 1024;

/// A raw message is byte-bounded, but a separate part-count bound prevents a
/// tiny-part MIME tree from causing disproportionate allocation and traversal.
pub(crate) const MAX_MIME_ATTACHMENTS: usize = 256;
