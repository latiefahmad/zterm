//! zterm-core — inti bersama Zterm untuk macOS (Swift) dan Windows (C#).
//!
//! Diekspor lewat UniFFI. Modul:
//! - [`model`]  : struktur data (Host, AuthMethod, ...)
//! - [`vault`]  : penyimpanan terenkripsi (Argon2id + XChaCha20-Poly1305)
//! - [`crypto`] : primitif enkripsi & format file

mod admin;
mod backup;
mod crypto;
mod db;
mod docker;
mod error;
mod keys;
mod model;
mod proxy;
mod remote_run;
mod server_info;
mod sftp;
mod ssh;
mod stack;
mod team;
mod vault;

pub use admin::{cron_describe, cron_valid, AdminSystem, CronJob, CronLine, LogChunk, LogSource, ServerProcess, ServerAdmin, ServiceUnit};
pub use backup::{backup_database, backup_extension, backup_supported, drive_upload_backup, restore_database, BackupResult};
pub use error::CoreError;
pub use docker::{ComposeProject, DockerClient, DockerContainer, DockerDetail, DockerImage, DockerInfo, DockerNetwork, DockerPort, DockerStat, DockerVolume};
pub use db::{DbFilter, DbSession, DbTable, QueryResult};
pub use model::{AuthMethod, DbConnection, DbEngine, EnvVar, ForwardKind, Host, HostProxy, PortForward, ProxyKind, SessionLog, Snippet, SshKey, SyncOutcome};
pub use proxy::proxy_stdio;
pub use remote_run::{run_remote, RemoteRun};
pub use server_info::{DiskInfo, ServerInfo, ServerMonitor, ServerSample};
pub use sftp::{RemoteEntry, SftpClient, TransferProgress};
pub use ssh::{forget_known_host, SshTarget};
pub use stack::{LocalStack, StackComponent, StackService, StackSettings, StackState};
pub use team::{MemberStatus, TeamInfo, TeamInvite, TeamMember, TeamStatus};
pub use vault::{Vault, vault_exists};

uniffi::setup_scaffolding!();

/// Versi core, ditampilkan di Settings / About.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
