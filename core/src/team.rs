//! Tim: admin membagikan host ke beberapa akun Google lewat satu file di Google Drive miliknya.
//!
//! File tim (`<nama>.ztermteam`, mime [`MIME`]) berisi:
//!
//! ```text
//! { "format": "zterm-team", "v": 1,
//!   "signed":   base64(JSON SignedDoc)  — ditandatangani admin (Ed25519)
//!   "sig":      base64(tanda tangan)
//!   "requests": [{ "email", "box" }]     — permintaan kunci dari anggota (tidak ditandatangani) }
//! ```
//!
//! `SignedDoc.payload` = host + SSH key yang dibagikan, dienkripsi XChaCha20-Poly1305 dengan kunci tim K.
//! K dibungkus untuk tiap anggota memakai X25519 (kunci publik anggota) — Google hanya melihat ciphertext.
//! Anggota yang dikeluarkan → K diganti (epoch naik) dan izin Drive-nya dicabut.
//!
//! Alur: admin membuat tim → mengundang email (izin Drive "writer" + email undangan dari Google) →
//! anggota membuka file sekali lewat Google Picker (halaman Gabung tim) → app anggota menulis
//! permintaan berisi kunci publiknya → app admin membungkus K untuk anggota itu → host muncul di app anggota.

use std::collections::HashSet;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey as BoxPublic, StaticSecret};

use crate::crypto::{self, Key};
use crate::model::{Host, Record, SshKey, VaultData, now_ms};
use crate::vault::Vault;
use crate::CoreError;

pub const MIME: &str = "application/vnd.zterm.team";
const ADMIN_KEY_MISSING: &str = "kamu masuk sebagai admin tim ini, tapi kunci admin tidak ada di vault ini — buka Zterm di perangkat tempat tim dibuat lalu sinkronkan, atau buat tim baru";
const JOIN_PAGE: &str = "https://latiefahmad.github.io/zterm/team.html";

// ---------- Data tersimpan di vault ----------

/// Kunci pribadi untuk Tim: X25519 (menerima kunci tim) + Ed25519 (admin menandatangani file tim).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Identity {
    box_secret: String,
    sign_secret: String,
    created_at: i64,
}

impl Identity {
    fn new() -> Self {
        Self {
            box_secret: B64.encode(crypto::random::<32>()),
            sign_secret: B64.encode(crypto::random::<32>()),
            created_at: now_ms(),
        }
    }
    fn box_secret(&self) -> StaticSecret {
        StaticSecret::from(decode32(&self.box_secret).unwrap_or_default())
    }
    fn box_pub(&self) -> String {
        B64.encode(BoxPublic::from(&self.box_secret()).as_bytes())
    }
    fn sign_key(&self) -> SigningKey {
        SigningKey::from_bytes(&decode32(&self.sign_secret).unwrap_or_default())
    }
    fn sign_pub(&self) -> String {
        B64.encode(self.sign_key().verifying_key().as_bytes())
    }
}

/// Gabungkan identitas dari perangkat lain agar semua perangkat sama: kunci yang menandatangani salah satu
/// tim di vault (kunci admin) menang; selain itu yang lebih dulu dibuat.
pub fn merge_identity(local: &mut Option<Identity>, remote: Option<Identity>, teams: &[TeamState]) -> (bool, bool) {
    match (local.as_ref(), remote) {
        (None, Some(r)) => {
            *local = Some(r);
            (true, false)
        }
        (Some(_), None) => (false, true),
        (Some(l), Some(r)) if l != &r => {
            let rank = |i: &Identity| {
                let signer = i.sign_pub();
                let is_admin_key = teams.iter().any(|t| !t.deleted && t.owner_sign == signer);
                (!is_admin_key, i.created_at, i.box_secret.clone())
            };
            if rank(&r) < rank(l) {
                *local = Some(r);
                (true, false)
            } else {
                (false, true)
            }
        }
        _ => (false, false),
    }
}

/// Siapkan record tim sebelum digabung last-write-wins: record admin yang masih hidup tidak boleh kalah dari
/// record anggota tim yang sama (terjadi saat satu vault dipakai beberapa akun Google). Waktunya dimajukan
/// agar menang di perangkat lain juga. Mengembalikan (lokal berubah, remote tertinggal).
pub fn protect_owner(local: &mut [TeamState], remote: &mut [TeamState]) -> (bool, bool) {
    let mut changed = (false, false);
    for r in remote.iter_mut() {
        let Some(l) = local.iter_mut().find(|l| l.id == r.id) else { continue };
        if l.is_owner && !l.deleted && !r.is_owner && r.updated_at >= l.updated_at {
            l.updated_at = r.updated_at + 1;
            changed = (true, true);
        } else if r.is_owner && !r.deleted && !l.is_owner && l.updated_at >= r.updated_at {
            r.updated_at = l.updated_at + 1;
            changed = (true, true);
        }
    }
    changed
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MemberEntry {
    pub email: String,
    /// "admin" | "member"
    pub role: String,
    /// Kunci publik X25519 anggota (kosong = belum membuka undangan).
    #[serde(default, rename = "box")]
    pub box_pub: Option<String>,
    /// K yang dibungkus untuk anggota ini (epoch saat ini).
    #[serde(default)]
    pub wrapped: Option<String>,
}

/// Satu tim yang diikuti (atau dimiliki) user. Disimpan di vault pribadi (terenkripsi).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TeamState {
    pub id: String,
    pub name: String,
    pub file_id: String,
    pub owner_email: String,
    /// Kunci publik Ed25519 admin — dipin saat bergabung.
    pub owner_sign: String,
    pub is_owner: bool,
    #[serde(default)]
    pub my_email: String,
    /// Kunci tim K (base64), None = belum diterima.
    #[serde(default)]
    pub key: Option<String>,
    #[serde(default)]
    pub epoch: u32,
    #[serde(default)]
    pub members: Vec<MemberEntry>,
    /// Admin: id host pribadi yang dibagikan.
    #[serde(default)]
    pub shared_host_ids: Vec<String>,
    /// Anggota: salinan host & key dari tim.
    #[serde(default)]
    pub hosts: Vec<Host>,
    #[serde(default)]
    pub keys: Vec<SshKey>,
    /// "active" | "waiting" | "revoked"
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub last_sync: i64,
    #[serde(default)]
    pub error: Option<String>,
    pub updated_at: i64,
    pub deleted: bool,
}

impl Record for TeamState {
    fn id(&self) -> &str { &self.id }
    fn ts(&self) -> i64 { self.updated_at }
    fn set_id(&mut self, id: String) { self.id = id; }
    fn touch(&mut self, deleted: bool) { self.updated_at = now_ms(); self.deleted = deleted; }
}

// ---------- Tipe untuk UI ----------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TeamStatus {
    /// Host tim tersedia.
    Active,
    /// Menunggu admin membuka Zterm untuk mengirim kunci.
    Waiting,
    /// Akses dicabut / tim dihapus.
    Revoked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MemberStatus {
    /// Diundang, belum membuka undangan.
    Invited,
    /// Sudah bergabung dan menerima kunci.
    Joined,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TeamMember {
    pub email: String,
    pub is_admin: bool,
    pub status: MemberStatus,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TeamInfo {
    pub id: String,
    pub name: String,
    pub file_id: String,
    pub owner_email: String,
    pub is_owner: bool,
    pub status: TeamStatus,
    pub members: Vec<TeamMember>,
    pub shared_host_ids: Vec<String>,
    pub host_count: u32,
    pub last_sync: i64,
    pub error: Option<String>,
}

/// File tim yang bisa dibuka user ini tapi belum diikuti.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TeamInvite {
    pub file_id: String,
    pub name: String,
    pub owner_email: String,
}

impl TeamState {
    fn info(&self) -> TeamInfo {
        TeamInfo {
            id: self.id.clone(),
            name: self.name.clone(),
            file_id: self.file_id.clone(),
            owner_email: self.owner_email.clone(),
            is_owner: self.is_owner,
            status: match self.status.as_str() {
                "active" => TeamStatus::Active,
                "revoked" => TeamStatus::Revoked,
                _ => TeamStatus::Waiting,
            },
            members: self
                .members
                .iter()
                .map(|m| TeamMember {
                    email: m.email.clone(),
                    is_admin: m.role == "admin",
                    status: if m.wrapped.is_some() { MemberStatus::Joined } else { MemberStatus::Invited },
                })
                .collect(),
            shared_host_ids: self.shared_host_ids.clone(),
            host_count: if self.is_owner { self.shared_host_ids.len() } else { self.hosts.len() } as u32,
            last_sync: self.last_sync,
            error: self.error.clone(),
        }
    }

    fn key(&self) -> Result<Key, CoreError> {
        self.key.as_deref().and_then(decode32).ok_or_else(|| team_err("kunci tim belum tersedia"))
    }
}

// ---------- Format file ----------

#[derive(Debug, Clone, Serialize, Deserialize)]
struct TeamFile {
    format: String,
    v: u32,
    signed: String,
    sig: String,
    #[serde(default)]
    requests: Vec<JoinRequest>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct JoinRequest {
    email: String,
    #[serde(rename = "box")]
    box_pub: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SignedDoc {
    team_id: String,
    name: String,
    owner_email: String,
    owner_sign: String,
    epoch: u32,
    members: Vec<MemberEntry>,
    payload: String,
    updated_at: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
struct Payload {
    hosts: Vec<Host>,
    keys: Vec<SshKey>,
}

fn team_err(msg: impl Into<String>) -> CoreError {
    CoreError::Team { msg: msg.into() }
}

fn decode32(s: &str) -> Option<[u8; 32]> {
    B64.decode(s).ok()?.try_into().ok()
}

fn norm_email(e: &str) -> String {
    e.trim().to_lowercase()
}

fn payload_aad(team_id: &str, epoch: u32) -> Vec<u8> {
    format!("zterm-team-payload|{team_id}|{epoch}").into_bytes()
}

fn wrap_aad(team_id: &str, epoch: u32, email: &str) -> Vec<u8> {
    format!("zterm-team-wrap|{team_id}|{epoch}|{}", norm_email(email)).into_bytes()
}

fn wrap_kdf(shared: &[u8; 32], eph: &[u8; 32], recipient: &[u8; 32]) -> Key {
    let mut h = Sha256::new();
    h.update(b"zterm-team-wrap-v1");
    h.update(shared);
    h.update(eph);
    h.update(recipient);
    h.finalize().into()
}

/// Bungkus K untuk satu anggota: `eph_pub:32 | nonce | ciphertext`.
fn wrap(k: &Key, box_pub: &str, aad: &[u8]) -> Result<String, CoreError> {
    let recipient = BoxPublic::from(decode32(box_pub).ok_or_else(|| team_err("kunci publik anggota tidak valid"))?);
    let eph = StaticSecret::from(crypto::random::<32>());
    let eph_pub = BoxPublic::from(&eph);
    let shared = eph.diffie_hellman(&recipient);
    if !shared.was_contributory() {
        return Err(team_err("kunci publik anggota tidak valid"));
    }
    let wk = wrap_kdf(shared.as_bytes(), eph_pub.as_bytes(), recipient.as_bytes());
    let mut out = eph_pub.as_bytes().to_vec();
    out.extend(crypto::seal_raw(&wk, aad, k));
    Ok(B64.encode(out))
}

fn unwrap(secret: &StaticSecret, wrapped: &str, aad: &[u8]) -> Option<Key> {
    let raw = B64.decode(wrapped).ok()?;
    if raw.len() < 32 {
        return None;
    }
    let eph: [u8; 32] = raw[..32].try_into().ok()?;
    let me = BoxPublic::from(secret);
    let shared = secret.diffie_hellman(&BoxPublic::from(eph));
    let wk = wrap_kdf(shared.as_bytes(), &eph, me.as_bytes());
    crypto::open_raw(&wk, aad, &raw[32..])?.try_into().ok()
}

fn parse_file(bytes: &[u8]) -> Result<(TeamFile, SignedDoc), CoreError> {
    let file: TeamFile = serde_json::from_slice(bytes).map_err(|_| team_err("bukan file tim Zterm"))?;
    if file.format != "zterm-team" {
        return Err(team_err("bukan file tim Zterm"));
    }
    if file.v != 1 {
        return Err(team_err(format!("format tim versi {} belum didukung — perbarui Zterm", file.v)));
    }
    let signed = B64.decode(&file.signed).map_err(|_| team_err("file tim rusak"))?;
    let doc: SignedDoc = serde_json::from_slice(&signed).map_err(|_| team_err("file tim rusak"))?;
    Ok((file, doc))
}

fn verify(file: &TeamFile, owner_sign: &str) -> bool {
    let (Some(pk), Ok(signed), Ok(sig)) = (decode32(owner_sign), B64.decode(&file.signed), B64.decode(&file.sig)) else {
        return false;
    };
    let (Ok(vk), Ok(sig)) = (VerifyingKey::from_bytes(&pk), Signature::from_slice(&sig)) else { return false };
    vk.verify(&signed, &sig).is_ok()
}

fn open_payload(doc: &SignedDoc, k: &Key) -> Option<Payload> {
    let blob = B64.decode(&doc.payload).ok()?;
    serde_json::from_slice(&crypto::open_raw(k, &payload_aad(&doc.team_id, doc.epoch), &blob)?).ok()
}

/// Host & key pribadi yang dibagikan admin ke tim.
fn payload_for(data: &VaultData, shared: &[String]) -> Payload {
    let ids: HashSet<&str> = shared.iter().map(String::as_str).collect();
    let mut hosts: Vec<Host> =
        data.hosts.iter().filter(|h| !h.deleted && ids.contains(h.id.as_str())).cloned().collect();
    for h in hosts.iter_mut() {
        if h.jump_host_id.as_deref().is_some_and(|j| !ids.contains(j)) {
            h.jump_host_id = None;
        }
    }
    let key_ids: HashSet<&str> = hosts.iter().filter_map(|h| h.key_id.as_deref()).collect();
    let keys = data.keys.iter().filter(|k| !k.deleted && key_ids.contains(k.id.as_str())).cloned().collect();
    hosts.sort_by(|a, b| a.id.cmp(&b.id));
    Payload { hosts, keys }
}

/// Susun & tandatangani file tim dari state admin.
fn build_file(state: &TeamState, ident: &Identity, payload: &Payload) -> Result<Vec<u8>, CoreError> {
    let k = state.key()?;
    let doc = SignedDoc {
        team_id: state.id.clone(),
        name: state.name.clone(),
        owner_email: state.owner_email.clone(),
        owner_sign: state.owner_sign.clone(),
        epoch: state.epoch,
        members: state.members.clone(),
        payload: B64.encode(crypto::seal_raw(&k, &payload_aad(&state.id, state.epoch), &serde_json::to_vec(payload)?)),
        updated_at: now_ms(),
    };
    let signed = serde_json::to_vec(&doc)?;
    let sig = ident.sign_key().sign(&signed);
    let file = TeamFile {
        format: "zterm-team".into(),
        v: 1,
        signed: B64.encode(&signed),
        sig: B64.encode(sig.to_bytes()),
        requests: vec![],
    };
    Ok(serde_json::to_vec_pretty(&file)?)
}

/// Bungkus K untuk anggota yang sudah punya kunci publik tapi belum menerima kunci.
fn wrap_missing(state: &mut TeamState) -> Result<bool, CoreError> {
    let k = state.key()?;
    let mut changed = false;
    for m in state.members.iter_mut() {
        if let (Some(b), None) = (&m.box_pub, &m.wrapped) {
            m.wrapped = Some(wrap(&k, b, &wrap_aad(&state.id, state.epoch, &m.email))?);
            changed = true;
        }
    }
    Ok(changed)
}

/// Ganti kunci tim (setelah anggota dikeluarkan): kunci lama tidak bisa membuka isi baru.
fn rotate(state: &mut TeamState) -> Result<(), CoreError> {
    state.key = Some(B64.encode(crypto::random::<32>()));
    state.epoch += 1;
    for m in state.members.iter_mut() {
        m.wrapped = None;
    }
    wrap_missing(state)?;
    Ok(())
}

/// Admin: proses permintaan kunci & tentukan apakah file di Drive perlu ditulis ulang.
fn owner_reconcile(state: &mut TeamState, ident: &Identity, remote: Option<(&TeamFile, &SignedDoc)>, payload: &Payload) -> Result<bool, CoreError> {
    let mut dirty = remote.is_none();
    if let Some((file, doc)) = remote {
        for r in &file.requests {
            if let Some(m) = state.members.iter_mut().find(|m| norm_email(&m.email) == norm_email(&r.email)) {
                if m.box_pub.as_deref() != Some(r.box_pub.as_str()) {
                    m.box_pub = Some(r.box_pub.clone());
                    m.wrapped = None;
                }
            }
        }
        dirty |= !file.requests.is_empty()
            || !verify(file, &ident.sign_pub())
            || doc.epoch != state.epoch
            || doc.name != state.name
            || doc.members != state.members
            || state.key().ok().and_then(|k| open_payload(doc, &k)).as_ref() != Some(payload);
    }
    dirty |= wrap_missing(state)?;
    Ok(dirty)
}

/// Anggota: terapkan isi file. Kembalikan permintaan kunci yang perlu ditambahkan ke file (jika ada).
fn member_apply(state: &mut TeamState, ident: &Identity, file: &TeamFile, doc: &SignedDoc) -> Result<Option<JoinRequest>, CoreError> {
    if doc.team_id != state.id || !verify(file, &state.owner_sign) {
        return Err(team_err("tanda tangan admin pada file tim tidak cocok — isi tim tidak dipakai"));
    }
    state.name = doc.name.clone();
    state.owner_email = doc.owner_email.clone();
    state.members = doc.members.clone();
    let me = norm_email(&state.my_email);
    let Some(entry) = doc.members.iter().find(|m| norm_email(&m.email) == me) else {
        revoke(state);
        return Ok(None);
    };
    let my_box = ident.box_pub();
    if entry.box_pub.as_deref() == Some(my_box.as_str()) {
        if let Some(k) = entry.wrapped.as_deref().and_then(|w| unwrap(&ident.box_secret(), w, &wrap_aad(&doc.team_id, doc.epoch, &me))) {
            let payload = open_payload(doc, &k).ok_or_else(|| team_err("isi tim tidak bisa dibuka"))?;
            state.key = Some(B64.encode(k));
            state.epoch = doc.epoch;
            state.hosts = payload.hosts;
            state.keys = payload.keys;
            state.status = "active".into();
            return Ok(None);
        }
    }
    // Belum punya kunci (baru bergabung, atau kunci tim diganti) — minta ke admin.
    if state.status != "active" || state.epoch != doc.epoch {
        state.status = "waiting".into();
    }
    let req = JoinRequest { email: me, box_pub: my_box };
    Ok((!file.requests.contains(&req)).then_some(req))
}

/// Bukti bahwa vault ini milik admin tim: file ditandatangani kunci vault ini, sama dengan kunci yang dipin,
/// dan kunci tim bisa dibuka dari entri admin. Email saja bukan bukti.
fn admin_proof(state: &TeamState, ident: &Identity, file: &TeamFile, doc: &SignedDoc) -> Option<(Key, Payload)> {
    let me = ident.sign_pub();
    // Epoch lebih lama = file lama yang ditulis ulang: jangan hidupkan lagi daftar anggota lama.
    if doc.team_id != state.id || doc.epoch < state.epoch || state.owner_sign != me || !verify(file, &me) {
        return None;
    }
    let owner = norm_email(&doc.owner_email);
    let wrapped = doc.members.iter().find(|m| norm_email(&m.email) == owner)?.wrapped.as_deref()?;
    let k = unwrap(&ident.box_secret(), wrapped, &wrap_aad(&doc.team_id, doc.epoch, &owner))?;
    let payload = open_payload(doc, &k)?;
    Some((k, payload))
}

/// Kembalikan record yang turun jadi anggota menjadi admin. Host tim yang tidak ada di vault ditambahkan
/// supaya tidak hilang saat file tim ditulis ulang; yang sudah ada atau sudah dihapus tidak disentuh.
fn restore_admin(state: &mut TeamState, data: &mut VaultData, doc: &SignedDoc, k: &Key, payload: Payload) {
    state.is_owner = true;
    state.name = doc.name.clone();
    state.owner_email = doc.owner_email.clone();
    state.my_email = norm_email(&doc.owner_email);
    state.key = Some(B64.encode(k));
    state.epoch = doc.epoch;
    state.members = doc.members.clone();
    state.shared_host_ids = payload.hosts.iter().map(|h| h.id.clone()).collect();
    state.hosts.clear();
    state.keys.clear();
    state.status = "active".into();
    for h in payload.hosts {
        if !data.hosts.iter().any(|x| x.id == h.id) {
            data.hosts.push(h);
        }
    }
    for key in payload.keys {
        if !data.keys.iter().any(|x| x.id == key.id) {
            data.keys.push(key);
        }
    }
}

fn revoke(state: &mut TeamState) {
    state.status = "revoked".into();
    state.key = None;
    state.hosts.clear();
    state.keys.clear();
}

fn team_prefix(team_id: &str) -> String {
    format!("team:{team_id}:")
}

// ---------- Google Drive ----------

struct Drive {
    http: reqwest::Client,
    token: String,
}

/// Alamat Google Drive. `ZTERM_DRIVE_BASE` (hanya alamat lokal) dipakai tes dengan server tiruan.
pub(crate) fn drive_base() -> String {
    match std::env::var("ZTERM_DRIVE_BASE") {
        Ok(b) if b.starts_with("http://127.0.0.1:") || b.starts_with("http://10.211.55.2:") => b,
        _ => "https://www.googleapis.com".into(),
    }
}

impl Drive {
    fn new(token: String) -> Self {
        Self { http: reqwest::Client::new(), token }
    }

    async fn send(&self, req: reqwest::RequestBuilder) -> Result<Vec<u8>, CoreError> {
        let resp = req
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| team_err(format!("tidak bisa terhubung ke Google Drive: {e}")))?;
        let code = resp.status().as_u16();
        let body = resp.bytes().await.map(|b| b.to_vec()).unwrap_or_default();
        if (200..300).contains(&code) {
            return Ok(body);
        }
        let text = String::from_utf8_lossy(&body);
        let msg = serde_json::from_slice::<serde_json::Value>(&body)
            .ok()
            .and_then(|v| v["error"]["message"].as_str().map(str::to_string))
            .unwrap_or_else(|| text.chars().take(160).collect());
        Err(match code {
            401 => CoreError::GoogleAuth,
            403 if text.contains("insufficient") || text.contains("SCOPE") => CoreError::GoogleScope,
            403 if text.contains("ateLimit") => team_err(format!("Google Drive sedang sibuk, coba lagi sebentar ({msg})")),
            403 | 404 => CoreError::NotFound,
            _ => team_err(format!("Google Drive {code}: {msg}")),
        })
    }

    async fn create(&self, name: &str, team_id: &str, data: Vec<u8>) -> Result<String, CoreError> {
        let meta = serde_json::json!({
            "name": format!("{name}.ztermteam"),
            "mimeType": MIME,
            "description": "Tim Zterm — buka dengan Zterm. Isinya terenkripsi.",
            "appProperties": { "ztermTeam": team_id },
            "writersCanShare": false,
        });
        let boundary = format!("zterm-{}", uuid::Uuid::new_v4().simple());
        let mut body = format!("--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{meta}\r\n--{boundary}\r\nContent-Type: {MIME}\r\n\r\n").into_bytes();
        body.extend(data);
        body.extend(format!("\r\n--{boundary}--\r\n").into_bytes());
        let out = self
            .send(
                self.http
                    .post(format!("{}/upload/drive/v3/files?uploadType=multipart&fields=id", drive_base()))
                    .header("Content-Type", format!("multipart/related; boundary={boundary}"))
                    .body(body),
            )
            .await?;
        let v: serde_json::Value = serde_json::from_slice(&out)?;
        v["id"].as_str().map(str::to_string).ok_or_else(|| team_err("Google Drive tidak mengembalikan id file"))
    }

    async fn update(&self, file_id: &str, data: Vec<u8>) -> Result<(), CoreError> {
        self.send(
            self.http
                .patch(format!("{}/upload/drive/v3/files/{file_id}?uploadType=media", drive_base()))
                .header("Content-Type", MIME)
                .body(data),
        )
        .await
        .map(|_| ())
    }

    async fn download(&self, file_id: &str) -> Result<Vec<u8>, CoreError> {
        self.send(self.http.get(format!("{}/drive/v3/files/{file_id}?alt=media", drive_base()))).await
    }

    async fn share(&self, file_id: &str, email: &str, message: &str) -> Result<(), CoreError> {
        let body = serde_json::json!({ "type": "user", "role": "writer", "emailAddress": email });
        self.send(
            self.http
                .post(format!("{}/drive/v3/files/{file_id}/permissions", drive_base()))
                .query(&[("sendNotificationEmail", "true"), ("emailMessage", message)])
                .header("Content-Type", "application/json")
                .body(body.to_string()),
        )
        .await
        .map(|_| ())
    }

    async fn unshare(&self, file_id: &str, email: &str) -> Result<(), CoreError> {
        let out = self
            .send(self.http.get(format!("{}/drive/v3/files/{file_id}/permissions?fields=permissions(id,emailAddress,role)", drive_base())))
            .await?;
        let v: serde_json::Value = serde_json::from_slice(&out)?;
        for p in v["permissions"].as_array().into_iter().flatten() {
            let same = p["emailAddress"].as_str().is_some_and(|e| norm_email(e) == norm_email(email));
            if same && p["role"].as_str() != Some("owner") {
                if let Some(id) = p["id"].as_str() {
                    self.send(self.http.delete(format!("{}/drive/v3/files/{file_id}/permissions/{id}", drive_base()))).await?;
                }
            }
        }
        Ok(())
    }

    async fn find(&self) -> Result<Vec<TeamInvite>, CoreError> {
        let q = format!("mimeType = '{MIME}' and trashed = false");
        let out = self
            .send(self.http.get(format!("{}/drive/v3/files", drive_base())).query(&[
                ("q", q.as_str()),
                ("fields", "files(id,name,owners(emailAddress))"),
                ("pageSize", "50"),
            ]))
            .await?;
        let v: serde_json::Value = serde_json::from_slice(&out)?;
        Ok(v["files"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|f| {
                Some(TeamInvite {
                    file_id: f["id"].as_str()?.to_string(),
                    name: f["name"].as_str().unwrap_or("Tim").trim_end_matches(".ztermteam").to_string(),
                    owner_email: f["owners"][0]["emailAddress"].as_str().unwrap_or("").to_string(),
                })
            })
            .collect())
    }

    async fn trash(&self, file_id: &str) -> Result<(), CoreError> {
        self.send(
            self.http
                .patch(format!("{}/drive/v3/files/{file_id}", drive_base()))
                .header("Content-Type", "application/json")
                .body(r#"{"trashed":true}"#),
        )
        .await
        .map(|_| ())
    }
}

// ---------- API untuk app ----------

/// Data Tim (tanpa jaringan).
#[uniffi::export]
impl Vault {
    /// Semua tim yang dimiliki / diikuti.
    pub fn teams(&self) -> Vec<TeamInfo> {
        let data = self.data.lock().unwrap();
        let mut v: Vec<TeamInfo> = data.teams.iter().filter(|t| !t.deleted).map(TeamState::info).collect();
        v.sort_by_key(|t| t.name.to_lowercase());
        v
    }

    /// Host dari tim yang diikuti (bukan milik sendiri). Id diberi awalan `team:<id>:` agar tidak bentrok.
    pub fn team_hosts(&self) -> Vec<Host> {
        let data = self.data.lock().unwrap();
        let mut out = vec![];
        for t in data.teams.iter().filter(|t| !t.deleted && !t.is_owner && t.status == "active") {
            let p = team_prefix(&t.id);
            for h in &t.hosts {
                let mut h = h.clone();
                h.id = format!("{p}{}", h.id);
                h.key_id = h.key_id.map(|k| format!("{p}{k}"));
                h.jump_host_id = h.jump_host_id.map(|j| format!("{p}{j}"));
                h.group = Some(format!("Tim · {}", t.name));
                out.push(h);
            }
        }
        out.sort_by_key(|h| h.label.to_lowercase());
        out
    }

    /// SSH key milik host tim (id berawalan `team:<id>:`).
    pub fn team_keys(&self) -> Vec<SshKey> {
        let data = self.data.lock().unwrap();
        let mut out = vec![];
        for t in data.teams.iter().filter(|t| !t.deleted && !t.is_owner && t.status == "active") {
            for k in &t.keys {
                let mut k = k.clone();
                k.id = format!("{}{}", team_prefix(&t.id), k.id);
                out.push(k);
            }
        }
        out
    }

    /// Tandai id host tim (awalan `team:`) — host ini hanya bisa diubah admin.
    pub fn is_team_host(&self, id: String) -> bool {
        id.starts_with("team:")
    }
}

/// Operasi Tim lewat Google Drive. `token` = access token Google (scope drive.file).
#[uniffi::export(async_runtime = "tokio")]
impl Vault {
    /// Buat tim baru; file tim dibuat di Google Drive admin.
    pub async fn team_create(&self, token: String, name: String, my_email: String) -> Result<TeamInfo, CoreError> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(team_err("nama tim wajib diisi"));
        }
        let me = norm_email(&my_email);
        let ident = self.identity()?;
        let mut state = TeamState {
            id: uuid::Uuid::new_v4().to_string(),
            name: name.clone(),
            file_id: String::new(),
            owner_email: me.clone(),
            owner_sign: ident.sign_pub(),
            is_owner: true,
            my_email: me.clone(),
            key: Some(B64.encode(crypto::random::<32>())),
            epoch: 1,
            members: vec![MemberEntry { email: me, role: "admin".into(), box_pub: Some(ident.box_pub()), wrapped: None }],
            shared_host_ids: vec![],
            hosts: vec![],
            keys: vec![],
            status: "active".into(),
            last_sync: now_ms(),
            error: None,
            updated_at: now_ms(),
            deleted: false,
        };
        wrap_missing(&mut state)?;
        let bytes = build_file(&state, &ident, &Payload::default())?;
        state.file_id = Drive::new(token).create(&name, &state.id, bytes).await?;
        let info = state.info();
        self.put_team(state)?;
        Ok(info)
    }

    /// Admin: undang email. Google mengirim email undangan; anggota lalu membuka halaman Gabung tim.
    pub async fn team_invite(&self, token: String, team_id: String, email: String) -> Result<TeamInfo, CoreError> {
        let email = norm_email(&email);
        if !email.contains('@') || email.contains(' ') {
            return Err(team_err("alamat email tidak valid"));
        }
        let mut state = self.owned_team(&team_id)?;
        if state.members.iter().any(|m| norm_email(&m.email) == email) {
            return Err(team_err(format!("{email} sudah ada di tim")));
        }
        let drive = Drive::new(token);
        let msg = format!(
            "Kamu diundang ke tim \"{}\" di Zterm 👋\n\n\
             Cara bergabung:\n\
             1. Buka Zterm → Tim → Gabung tim\n\
             2. Ikuti petunjuknya, atau buka: {JOIN_PAGE}\n\n\
             Belum punya Zterm? Unduh gratis: https://latiefahmad.github.io/zterm/\n\
             🔒 Host & password di tim ini terenkripsi end-to-end.",
            state.name
        );
        drive.share(&state.file_id, &email, &msg).await?;
        state.members.push(MemberEntry { email, role: "member".into(), box_pub: None, wrapped: None });
        self.owner_upload(&drive, state).await
    }

    /// Admin: keluarkan anggota — kunci tim diganti dan izin Drive dicabut.
    pub async fn team_remove_member(&self, token: String, team_id: String, email: String) -> Result<TeamInfo, CoreError> {
        let email = norm_email(&email);
        let mut state = self.owned_team(&team_id)?;
        if norm_email(&state.owner_email) == email {
            return Err(team_err("admin tidak bisa dikeluarkan"));
        }
        let before = state.members.len();
        state.members.retain(|m| norm_email(&m.email) != email);
        if state.members.len() == before {
            return Err(CoreError::NotFound);
        }
        rotate(&mut state)?;
        let drive = Drive::new(token);
        let info = self.owner_upload(&drive, state.clone()).await?;
        match drive.unshare(&state.file_id, &email).await {
            Ok(()) | Err(CoreError::NotFound) => Ok(info),
            Err(e) => Err(e),
        }
    }

    /// Admin: pilih host pribadi yang dibagikan ke tim (password & SSH key ikut, terenkripsi).
    pub async fn team_share_hosts(&self, token: String, team_id: String, host_ids: Vec<String>) -> Result<TeamInfo, CoreError> {
        let mut state = self.owned_team(&team_id)?;
        let mut ids = host_ids;
        ids.sort();
        ids.dedup();
        state.shared_host_ids = ids;
        self.owner_upload(&Drive::new(token), state).await
    }

    /// File tim yang sudah bisa dibuka akun ini (lewat Gabung tim) tapi belum diikuti.
    pub async fn team_find_invites(&self, token: String) -> Result<Vec<TeamInvite>, CoreError> {
        let known: HashSet<String> = {
            let data = self.data.lock().unwrap();
            data.teams.iter().filter(|t| !t.deleted).map(|t| t.file_id.clone()).collect()
        };
        Ok(Drive::new(token).find().await?.into_iter().filter(|i| !known.contains(&i.file_id)).collect())
    }

    /// Gabung ke tim dari file id (hasil Google Picker / `team_find_invites`).
    pub async fn team_join(&self, token: String, file_id: String, my_email: String) -> Result<TeamInfo, CoreError> {
        let ident = self.identity()?;
        let drive = Drive::new(token);
        let bytes = match drive.download(&file_id).await {
            Err(CoreError::NotFound) => {
                return Err(team_err("file tim belum bisa dibuka akun ini — buka halaman Gabung tim dan pilih file tim dulu"));
            }
            r => r?,
        };
        let (file, doc) = parse_file(&bytes)?;
        let me = norm_email(&my_email);
        if norm_email(&doc.owner_email) == me {
            return Err(team_err(format!(
                "\"{}\" adalah tim milikmu — kamu adminnya. Rekan bergabung dari Zterm di perangkat mereka, \
                 yang masuk dengan akun Google yang kamu undang",
                doc.name
            )));
        }
        if self.data.lock().unwrap().teams.iter().any(|t| !t.deleted && t.id == doc.team_id) {
            return Err(team_err(format!("kamu sudah bergabung di tim \"{}\"", doc.name)));
        }
        let mut state = TeamState {
            id: doc.team_id.clone(),
            name: doc.name.clone(),
            file_id: file_id.clone(),
            owner_email: doc.owner_email.clone(),
            owner_sign: doc.owner_sign.clone(),
            is_owner: false,
            my_email: norm_email(&my_email),
            key: None,
            epoch: 0,
            members: vec![],
            shared_host_ids: vec![],
            hosts: vec![],
            keys: vec![],
            status: "waiting".into(),
            last_sync: now_ms(),
            error: None,
            updated_at: now_ms(),
            deleted: false,
        };
        if !doc.members.iter().any(|m| norm_email(&m.email) == state.my_email) {
            return Err(team_err(format!(
                "akun {} tidak diundang ke tim \"{}\". Masuk ke Zterm dengan akun Google yang menerima email undangan",
                state.my_email, doc.name
            )));
        }
        if let Some(req) = member_apply(&mut state, &ident, &file, &doc)? {
            let mut file = file;
            file.requests.push(req);
            drive.update(&file_id, serde_json::to_vec_pretty(&file)?).await?;
        }
        let info = state.info();
        self.put_team(state)?;
        Ok(info)
    }

    /// Sinkronkan semua tim. Kembalikan `true` jika ada perubahan (host tim baru, anggota bergabung, …).
    pub async fn team_sync(&self, token: String) -> Result<bool, CoreError> {
        let teams: Vec<TeamState> = self.data.lock().unwrap().teams.iter().filter(|t| !t.deleted).cloned().collect();
        if teams.is_empty() {
            return Ok(false);
        }
        let ident = self.identity()?;
        let drive = Drive::new(token);
        let mut any = false;
        for original in teams {
            let mut state = original.clone();
            let result = if state.is_owner {
                self.owner_sync(&drive, &ident, &mut state).await
            } else {
                self.member_sync(&drive, &ident, &mut state).await
            };
            match result {
                Ok(()) => state.error = None,
                Err(e @ (CoreError::GoogleAuth | CoreError::GoogleScope)) => return Err(e),
                Err(e) => state.error = Some(e.to_string()),
            }
            state.last_sync = now_ms();
            let content_changed = strip_volatile(&state) != strip_volatile(&original);
            if content_changed {
                state.updated_at = now_ms();
                any = true;
            }
            let mut data = self.data.lock().unwrap();
            if let Some(slot) = data.teams.iter_mut().find(|t| t.id == state.id) {
                // Jangan timpa perubahan lokal yang terjadi selama sinkron (mis. host dibagikan).
                if slot.updated_at == original.updated_at {
                    *slot = state;
                }
            }
            self.persist(&data)?;
        }
        Ok(any)
    }

    /// Keluar dari tim. Admin: tim dihapus (file tim dipindah ke sampah Drive).
    pub async fn team_leave(&self, token: String, team_id: String) -> Result<(), CoreError> {
        let state = self
            .data
            .lock()
            .unwrap()
            .teams
            .iter()
            .find(|t| t.id == team_id && !t.deleted)
            .cloned()
            .ok_or(CoreError::NotFound)?;
        let drive = Drive::new(token);
        let r = if state.is_owner { drive.trash(&state.file_id).await } else { drive.unshare(&state.file_id, &state.my_email).await };
        match r {
            Ok(()) | Err(CoreError::NotFound) => {}
            Err(e @ (CoreError::GoogleAuth | CoreError::GoogleScope)) => return Err(e),
            Err(_) if !state.is_owner => {}
            Err(e) => return Err(e),
        }
        let mut data = self.data.lock().unwrap();
        if let Some(t) = data.teams.iter_mut().find(|t| t.id == team_id) {
            revoke(t);
            t.members.clear();
            t.touch(true);
        }
        self.persist(&data)
    }
}

/// Field yang berubah tiap sinkron — diabaikan saat menentukan apakah isi tim berubah.
fn strip_volatile(t: &TeamState) -> TeamState {
    let mut t = t.clone();
    t.last_sync = 0;
    t.error = None;
    t
}

impl Vault {
    /// Identitas Tim; dibuat sekali lalu ikut tersinkron ke perangkat sendiri.
    fn identity(&self) -> Result<Identity, CoreError> {
        let mut data = self.data.lock().unwrap();
        if let Some(i) = &data.identity {
            return Ok(i.clone());
        }
        let i = Identity::new();
        data.identity = Some(i.clone());
        self.persist(&data)?;
        Ok(i)
    }

    fn put_team(&self, mut state: TeamState) -> Result<(), CoreError> {
        state.updated_at = now_ms();
        let mut data = self.data.lock().unwrap();
        data.teams.retain(|t| t.id != state.id);
        data.teams.push(state);
        self.persist(&data)
    }

    fn owned_team(&self, team_id: &str) -> Result<TeamState, CoreError> {
        let data = self.data.lock().unwrap();
        let t = data.teams.iter().find(|t| t.id == team_id && !t.deleted).ok_or(CoreError::NotFound)?;
        if !t.is_owner {
            return Err(team_err("hanya admin yang bisa mengubah tim"));
        }
        Ok(t.clone())
    }

    /// Admin: tulis file tim dari state lokal (permintaan kunci di Drive ikut diproses).
    async fn owner_upload(&self, drive: &Drive, mut state: TeamState) -> Result<TeamInfo, CoreError> {
        let ident = self.identity()?;
        if let Ok(bytes) = drive.download(&state.file_id).await {
            if let Ok((file, doc)) = parse_file(&bytes) {
                let payload = payload_for(&self.data.lock().unwrap(), &state.shared_host_ids);
                owner_reconcile(&mut state, &ident, Some((&file, &doc)), &payload)?;
            }
        }
        wrap_missing(&mut state)?;
        let payload = payload_for(&self.data.lock().unwrap(), &state.shared_host_ids);
        drive.update(&state.file_id, build_file(&state, &ident, &payload)?).await?;
        state.last_sync = now_ms();
        state.error = None;
        let info = state.info();
        self.put_team(state)?;
        Ok(info)
    }

    async fn owner_sync(&self, drive: &Drive, ident: &Identity, state: &mut TeamState) -> Result<(), CoreError> {
        let bytes = match drive.download(&state.file_id).await {
            Err(CoreError::NotFound) => return Err(team_err("file tim tidak ditemukan di Google Drive (terhapus?)")),
            r => r?,
        };
        let parsed = parse_file(&bytes).ok();
        let payload = payload_for(&self.data.lock().unwrap(), &state.shared_host_ids);
        if owner_reconcile(state, ident, parsed.as_ref().map(|(f, d)| (f, d)), &payload)? {
            drive.update(&state.file_id, build_file(state, ident, &payload)?).await?;
        }
        Ok(())
    }

    async fn member_sync(&self, drive: &Drive, ident: &Identity, state: &mut TeamState) -> Result<(), CoreError> {
        let bytes = match drive.download(&state.file_id).await {
            Err(CoreError::NotFound) => {
                revoke(state);
                return Ok(());
            }
            r => r?,
        };
        let (mut file, doc) = parse_file(&bytes)?;
        if let Some((k, payload)) = admin_proof(state, ident, &file, &doc) {
            {
                let mut data = self.data.lock().unwrap();
                restore_admin(state, &mut data, &doc, &k, payload);
                self.persist(&data)?;
            }
            return self.owner_sync(drive, ident, state).await;
        }
        let request = member_apply(state, ident, &file, &doc)?;
        // Admin tanpa kunci adminnya: jangan menyuruhnya menunggu dirinya sendiri atau meminta kunci ke dirinya.
        if state.status == "waiting" && self.account_email().is_some_and(|e| norm_email(&e) == norm_email(&doc.owner_email)) {
            return Err(team_err(ADMIN_KEY_MISSING));
        }
        if let Some(req) = request {
            file.requests.retain(|r| norm_email(&r.email) != req.email);
            file.requests.push(req);
            drive.update(&state.file_id, serde_json::to_vec_pretty(&file)?).await?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::AuthMethod;

    fn host(label: &str, key: Option<&str>) -> Host {
        Host {
            id: format!("h-{label}"),
            label: label.into(),
            hostname: "10.0.0.1".into(),
            group: None,
            port: 22,
            username: "root".into(),
            auth: if key.is_some() { AuthMethod::Key } else { AuthMethod::Password },
            password: Some("rahasia".into()),
            key_id: key.map(str::to_string),
            agent_forwarding: false,
            startup_snippet: None,
            jump_host_id: Some("h-tidak-dibagikan".into()),
            proxy: None,
            env: vec![],
            charset: "UTF-8".into(),
            terminal_theme: None,
            tags: vec![],
            color: "#3fd0b4".into(),
            updated_at: 1,
            deleted: false,
        }
    }

    fn key(id: &str) -> SshKey {
        SshKey {
            id: id.into(),
            label: "deploy".into(),
            key_type: "ssh-ed25519".into(),
            public_key: "ssh-ed25519 AAAA".into(),
            private_key: "-----BEGIN OPENSSH PRIVATE KEY-----".into(),
            passphrase: None,
            fingerprint: "SHA256:x".into(),
            updated_at: 1,
            deleted: false,
        }
    }

    fn owner_state(ident: &Identity) -> TeamState {
        let mut s = TeamState {
            id: "team-1".into(),
            name: "Ops".into(),
            file_id: "file-1".into(),
            owner_email: "admin@x.com".into(),
            owner_sign: ident.sign_pub(),
            is_owner: true,
            my_email: "admin@x.com".into(),
            key: Some(B64.encode(crypto::random::<32>())),
            epoch: 1,
            members: vec![MemberEntry { email: "admin@x.com".into(), role: "admin".into(), box_pub: Some(ident.box_pub()), wrapped: None }],
            shared_host_ids: vec!["h-web".into(), "h-db".into()],
            hosts: vec![],
            keys: vec![],
            status: "active".into(),
            last_sync: 0,
            error: None,
            updated_at: 1,
            deleted: false,
        };
        wrap_missing(&mut s).unwrap();
        s
    }

    fn member_state(owner: &TeamState, email: &str) -> TeamState {
        TeamState {
            is_owner: false,
            my_email: email.into(),
            key: None,
            epoch: 0,
            members: vec![],
            shared_host_ids: vec![],
            status: "waiting".into(),
            ..owner.clone()
        }
    }

    /// Simulasi Drive: satu file bersama yang dibaca/ditulis admin & anggota.
    fn member_round(state: &mut TeamState, ident: &Identity, drive_file: &mut Vec<u8>) {
        let (mut file, doc) = parse_file(drive_file).unwrap();
        if let Some(req) = member_apply(state, ident, &file, &doc).unwrap() {
            file.requests.push(req);
            *drive_file = serde_json::to_vec(&file).unwrap();
        }
    }

    fn owner_round(state: &mut TeamState, ident: &Identity, data: &VaultData, drive_file: &mut Vec<u8>) -> bool {
        let parsed = parse_file(drive_file).ok();
        let payload = payload_for(data, &state.shared_host_ids);
        let dirty = owner_reconcile(state, ident, parsed.as_ref().map(|(f, d)| (f, d)), &payload).unwrap();
        if dirty {
            *drive_file = build_file(state, ident, &payload).unwrap();
        }
        dirty
    }

    #[test]
    fn invite_join_share_and_remove() {
        let admin = Identity::new();
        let budi = Identity::new();
        let sari = Identity::new();
        let mut data = VaultData::default();
        data.hosts = vec![host("web", Some("k-1")), host("db", None), host("pribadi", None)];
        data.keys = vec![key("k-1"), key("k-lain")];

        let mut owner = owner_state(&admin);
        owner.members.push(MemberEntry { email: "budi@x.com".into(), role: "member".into(), box_pub: None, wrapped: None });
        owner.members.push(MemberEntry { email: "Sari@X.com".into(), role: "member".into(), box_pub: None, wrapped: None });
        let mut drive = build_file(&owner, &admin, &payload_for(&data, &owner.shared_host_ids)).unwrap();
        assert!(!owner_round(&mut owner, &admin, &data, &mut drive), "file baru tidak perlu ditulis ulang");

        // Anggota bergabung → menunggu kunci, menulis permintaan
        let mut b = member_state(&owner, "budi@x.com");
        let mut s = member_state(&owner, "sari@x.com");
        member_round(&mut b, &budi, &mut drive);
        member_round(&mut s, &sari, &mut drive);
        assert_eq!(b.status, "waiting");
        assert!(b.hosts.is_empty());
        assert_eq!(parse_file(&drive).unwrap().0.requests.len(), 2);

        // Admin memproses permintaan → anggota menerima host
        assert!(owner_round(&mut owner, &admin, &data, &mut drive));
        assert!(owner.info().members.iter().all(|m| m.status == MemberStatus::Joined));
        member_round(&mut b, &budi, &mut drive);
        member_round(&mut s, &sari, &mut drive);
        assert_eq!(b.status, "active");
        let mut labels: Vec<_> = b.hosts.iter().map(|h| h.label.clone()).collect();
        labels.sort();
        assert_eq!(labels, vec!["db", "web"]);
        assert_eq!(b.hosts[0].password.as_deref(), Some("rahasia"));
        assert!(b.hosts.iter().all(|h| h.jump_host_id.is_none()), "jump host yang tidak dibagikan dibuang");
        assert_eq!(b.keys.iter().map(|k| k.id.as_str()).collect::<Vec<_>>(), vec!["k-1"]);
        assert_eq!(s.status, "active");
        assert!(parse_file(&drive).unwrap().0.requests.is_empty());

        // Tidak ada perubahan → tidak menulis ulang
        assert!(!owner_round(&mut owner, &admin, &data, &mut drive));

        // Admin mengubah host yang dibagikan → anggota menerima versi baru
        data.hosts[1].hostname = "10.9.9.9".into();
        assert!(owner_round(&mut owner, &admin, &data, &mut drive));
        member_round(&mut b, &budi, &mut drive);
        assert!(b.hosts.iter().any(|h| h.hostname == "10.9.9.9"));

        // Sari dikeluarkan → kunci diganti; Budi tetap bisa membaca, kunci lama Sari tidak berlaku
        let old_key = s.key.clone();
        owner.members.retain(|m| m.email != "Sari@X.com");
        rotate(&mut owner).unwrap();
        assert!(owner_round(&mut owner, &admin, &data, &mut drive));
        member_round(&mut b, &budi, &mut drive);
        assert_eq!(b.status, "active");
        assert_eq!(b.epoch, 2);
        member_round(&mut s, &sari, &mut drive);
        assert_eq!(s.status, "revoked");
        assert!(s.hosts.is_empty() && s.key.is_none());
        let (_, doc) = parse_file(&drive).unwrap();
        assert!(open_payload(&doc, &decode32(old_key.as_deref().unwrap()).unwrap()).is_none());
    }

    #[test]
    fn rejects_tampered_file() {
        let admin = Identity::new();
        let budi = Identity::new();
        let attacker = Identity::new();
        let data = VaultData { hosts: vec![host("web", None)], ..Default::default() };
        let mut owner = owner_state(&admin);
        owner.members.push(MemberEntry { email: "budi@x.com".into(), role: "member".into(), box_pub: Some(budi.box_pub()), wrapped: None });
        wrap_missing(&mut owner).unwrap();
        let mut drive = build_file(&owner, &admin, &payload_for(&data, &owner.shared_host_ids)).unwrap();
        let mut b = member_state(&owner, "budi@x.com");
        member_round(&mut b, &budi, &mut drive);
        assert_eq!(b.status, "active");

        // Anggota lain (writer di Drive) menulis ulang file dengan kunci sendiri → ditolak
        let mut fake = owner.clone();
        fake.owner_sign = attacker.sign_pub();
        fake.shared_host_ids = vec![];
        let forged = build_file(&fake, &attacker, &Payload::default()).unwrap();
        let (file, doc) = parse_file(&forged).unwrap();
        assert!(matches!(member_apply(&mut b, &budi, &file, &doc), Err(CoreError::Team { .. })));
        assert_eq!(b.hosts.len(), 1, "host lama tetap");

        // Admin melihat file diubah orang lain → ditulis ulang dengan tanda tangannya
        let mut forged_drive = forged;
        assert!(owner_round(&mut owner, &admin, &data, &mut forged_drive));
        assert!(verify(&parse_file(&forged_drive).unwrap().0, &admin.sign_pub()));
    }

    #[test]
    fn wrap_is_bound_to_recipient() {
        let a = Identity::new();
        let b = Identity::new();
        let k: Key = crypto::random();
        let w = wrap(&k, &a.box_pub(), b"aad").unwrap();
        assert_eq!(unwrap(&a.box_secret(), &w, b"aad"), Some(k));
        assert_eq!(unwrap(&b.box_secret(), &w, b"aad"), None);
        assert_eq!(unwrap(&a.box_secret(), &w, b"lain"), None);
    }

    #[test]
    fn identity_merge_converges() {
        let older = Identity { created_at: 1, ..Identity::new() };
        let newer = Identity { created_at: 2, ..Identity::new() };
        let mut x = Some(newer.clone());
        assert_eq!(merge_identity(&mut x, Some(older.clone()), &[]), (true, false));
        assert_eq!(x, Some(older.clone()));
        let mut y = Some(older.clone());
        assert_eq!(merge_identity(&mut y, Some(newer), &[]), (false, true));
        let mut z = None;
        assert_eq!(merge_identity(&mut z, Some(older.clone()), &[]), (true, false));
    }

    #[test]
    fn admin_key_beats_older_identity() {
        let other = Identity { created_at: 1, ..Identity::new() };
        let admin = Identity { created_at: 2, ..Identity::new() };
        let teams = [owner_state(&admin)];
        let mut x = Some(other.clone());
        assert_eq!(merge_identity(&mut x, Some(admin.clone()), &teams), (true, false));
        let mut y = Some(admin.clone());
        assert_eq!(merge_identity(&mut y, Some(other), &teams), (false, true));
    }

    #[test]
    fn owner_record_wins_both_directions() {
        let owner = owner_state(&Identity::new());
        let member = TeamState { updated_at: 9, ..member_state(&owner, "budi@x.com") };
        let (mut l, mut r) = (vec![owner.clone()], vec![member.clone()]);
        assert_eq!(protect_owner(&mut l, &mut r), (true, true));
        assert!(l[0].updated_at > r[0].updated_at);
        let (mut l, mut r) = (vec![member.clone()], vec![owner.clone()]);
        assert_eq!(protect_owner(&mut l, &mut r), (true, true));
        assert!(r[0].updated_at > l[0].updated_at);

        // Tim yang dihapus admin tetap mengikuti last-write-wins
        let (mut l, mut r) = (vec![TeamState { deleted: true, ..owner }], vec![member]);
        assert_eq!(protect_owner(&mut l, &mut r), (false, false));
    }

    #[test]
    fn admin_proof_needs_key_and_current_epoch() {
        let admin = Identity::new();
        let owner = owner_state(&admin);
        let bytes = build_file(&owner, &admin, &Payload::default()).unwrap();
        let (file, doc) = parse_file(&bytes).unwrap();
        let demoted = member_state(&owner, "budi@x.com");
        assert!(admin_proof(&demoted, &admin, &file, &doc).is_some());
        assert!(admin_proof(&demoted, &Identity::new(), &file, &doc).is_none());
        let newer = TeamState { epoch: doc.epoch + 1, ..demoted };
        assert!(admin_proof(&newer, &admin, &file, &doc).is_none(), "file lama yang diputar ulang");
    }
}
