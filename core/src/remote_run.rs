//! Jalankan satu perintah (non-interaktif) di server lewat SSH — untuk "Jalankan di banyak server".

use std::time::{Duration, Instant};

use russh::ChannelMsg;

use crate::ssh::{self, SshTarget};
use crate::CoreError;

/// Batas output yang disimpan per server (sisanya dibuang, `truncated` = true).
const MAX_OUTPUT: usize = 256 * 1024;

/// Hasil satu perintah di satu server.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct RemoteRun {
    /// Kode keluar; None bila perintah dihentikan (timeout) atau server tidak mengirim status.
    pub exit_code: Option<u32>,
    /// stdout + stderr sesuai urutan datang.
    pub output: String,
    pub duration_ms: u64,
    pub timed_out: bool,
    pub truncated: bool,
}

/// Sambung, jalankan `command`, tunggu selesai (maks. `timeout_secs`), lalu putus.
/// Gagal sambung / login → Err; perintah yang gagal tetap Ok dengan exit_code ≠ 0.
#[uniffi::export(async_runtime = "tokio")]
pub async fn run_remote(target: SshTarget, command: String, timeout_secs: u32) -> Result<RemoteRun, CoreError> {
    let start = Instant::now();
    let handle = tokio::time::timeout(Duration::from_secs(20), ssh::connect(&target))
        .await
        .map_err(|_| CoreError::Ssh { msg: "server tidak menjawab (20 detik)".into() })??;
    let mut out: Vec<u8> = Vec::new();
    let mut truncated = false;
    let mut exit_code = None;
    let mut push = |data: &[u8], out: &mut Vec<u8>| {
        let room = MAX_OUTPUT.saturating_sub(out.len());
        if data.len() > room {
            truncated = true;
        }
        out.extend_from_slice(&data[..data.len().min(room)]);
    };
    let run = async {
        let mut ch = handle.channel_open_session().await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
        ch.exec(true, command.as_bytes()).await.map_err(|e| CoreError::Ssh { msg: e.to_string() })?;
        while let Some(msg) = ch.wait().await {
            match msg {
                ChannelMsg::Data { data } => push(&data, &mut out),
                ChannelMsg::ExtendedData { data, .. } => push(&data, &mut out),
                ChannelMsg::ExitStatus { exit_status } => exit_code = Some(exit_status),
                ChannelMsg::Close => break,
                _ => {}
            }
        }
        Ok::<_, CoreError>(())
    };
    let limit = Duration::from_secs(timeout_secs.max(1) as u64);
    let timed_out = match tokio::time::timeout(limit, run).await {
        Ok(r) => {
            r?;
            false
        }
        Err(_) => true,
    };
    let _ = handle.disconnect(russh::Disconnect::ByApplication, "", "en").await;
    Ok(RemoteRun {
        exit_code: if timed_out { None } else { exit_code },
        output: String::from_utf8_lossy(&out).into_owned(),
        duration_ms: start.elapsed().as_millis() as u64,
        timed_out,
        truncated,
    })
}
