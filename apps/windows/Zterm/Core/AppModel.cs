using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using uniffi.zterm_core;

namespace Zterm;

internal enum Phase { Welcome, CreatePassword, Restore, Locked, Main }

internal enum Section { Dashboard, Hosts, ServerAdmin, Team, Keychain, Forwarding, Sftp, Database, LocalServer, Docker, Snippets, KnownHosts, Logs, About, Account }

internal enum SyncKind { Off, Idle, Syncing, Synced, Failed, NeedsLogin }

internal static class SectionInfo
{
    public static readonly Section[] Main = [Section.Dashboard, Section.Hosts, Section.ServerAdmin, Section.Team, Section.Keychain, Section.Forwarding, Section.Sftp, Section.Database, Section.LocalServer, Section.Docker, Section.Snippets, Section.KnownHosts, Section.Logs];
    public static readonly Section[] Community = [Section.About];

    public static string Title(this Section s) => L.T(s switch
    {
        Section.Dashboard => "Dashboard", Section.Hosts => "Hosts", Section.ServerAdmin => "Kelola Server", Section.Team => "Tim", Section.Keychain => "Keychain", Section.Forwarding => "Port Forwarding", Section.Sftp => "SFTP",
        Section.Database => "Database", Section.LocalServer => "Server Lokal", Section.Docker => "Docker", Section.Snippets => "Snippets", Section.KnownHosts => "Known Hosts", Section.Logs => "Logs",
        Section.About => "Tentang", _ => "Akun",
    });

    public static string Glyph(this Section s) => s switch
    {
        Section.Dashboard => G.Gauge, Section.Hosts => G.Server, Section.ServerAdmin => G.Wrench, Section.Team => G.People, Section.Keychain => G.Key, Section.Forwarding => G.Forward, Section.Sftp => G.Folder,
        Section.Database => G.Database, Section.LocalServer => G.Stack, Section.Docker => G.Apps, Section.Snippets => G.Code, Section.KnownHosts => G.Fingerprint, Section.Logs => G.History,
        Section.About => G.Info, _ => G.Person,
    };

    /// <summary>Nama ikon Phosphor Duotone untuk sidebar.</summary>
    public static string Ph(this Section s) => s switch
    {
        Section.Dashboard => "gauge", Section.Hosts => "hard-drives", Section.ServerAdmin => "wrench", Section.Team => "users-three",
        Section.Keychain => "key", Section.Forwarding => "arrows-left-right", Section.Sftp => "folder-open", Section.Database => "database",
        Section.LocalServer => "stack", Section.Docker => "cube", Section.Snippets => "brackets-curly", Section.KnownHosts => "fingerprint",
        Section.Logs => "clock", Section.About => "info", _ => "user-circle",
    };

    public static string Tint(this Section s) => s switch
    {
        Section.Dashboard => "#F43F5E", Section.Hosts => "#3B82F6", Section.ServerAdmin => "#0EA5E9", Section.Team => "#22C55E", Section.Keychain => "#F59E0B", Section.Forwarding => "#10B981", Section.Sftp => "#06B6D4",
        Section.Database => "#F97316", Section.LocalServer => "#EAB308", Section.Docker => "#2496ED", Section.Snippets => "#8B5CF6", Section.KnownHosts => "#EC4899", Section.Logs => "#64748B",
        Section.About => "#6366F1", _ => "#14B8A6",
    };
}

/// <summary>State utama app. Semua data persisten lewat Vault (zterm-core, Rust) — sama dengan AppModel.swift.</summary>
internal sealed class AppModel
{
    public Phase Phase { get; private set; }
    public Section Section { get; private set; } = Section.Hosts;
    public Host[] Hosts { get; private set; } = [];
    public SshKey[] Keys { get; private set; } = [];
    public Snippet[] Snippets { get; private set; } = [];
    public PortForward[] Forwards { get; private set; } = [];
    public SessionLog[] Logs { get; private set; } = [];
    public DbConnection[] Databases { get; private set; } = [];
    /// <summary>Tim yang dimiliki / diikuti, key milik host tim (terpisah dari Keychain), dan undangan yang belum diterima.</summary>
    public TeamInfo[] Teams { get; private set; } = [];
    public SshKey[] TeamKeys { get; private set; } = [];
    public TeamInvite[] TeamInvites { get; private set; } = [];
    public bool TeamBusy { get; private set; }
    public string? TeamError { get; set; }
    private DispatcherQueueTimer? _teamTimer;
    public DbWorkspace? DbWorkspace { get; private set; }

    public string? AccountEmail { get; private set; }
    public string? PendingAccountEmail { get; set; }
    public byte[]? PendingRemoteBlob { get; set; }
    public string? ProfileName { get; private set; } = Settings.Str(Settings.ProfileName);

    public List<TerminalSession> Sessions { get; } = [];
    public Guid? ActiveSessionId { get; private set; }

    /// <summary>Panel Info server (spesifikasi & grafik) untuk host di tab aktif.</summary>
    public bool ShowServerInfo { get; private set; }
    public ServerStats? ServerStats { get; private set; }

    public void ToggleServerInfo(bool? show = null)
    {
        ShowServerInfo = show ?? !ShowServerInfo;
        SyncServerStats();
        Raise("serverinfo");
    }

    /// <summary>Hubungkan / putus panel Info server mengikuti tab aktif.</summary>
    public void SyncServerStats()
    {
        var s = ActiveSession;
        if (!ShowServerInfo || s == null || s.IsLocal || SshTarget(s.Host.Id) is not { } target)
        {
            if (ServerStats == null) return;
            ServerStats.Stop();
            ServerStats = null;
            Raise("serverinfo");
            return;
        }
        if (ServerStats?.Host.Id == s.Host.Id) return;
        ServerStats?.Stop();
        ServerStats = new ServerStats(s.Host);
        ServerStats.Start(target);
        Raise("serverinfo");
    }

    public void RetryServerStats()
    {
        if (ServerStats is { } st && SshTarget(st.Host.Id) is { } t) st.Retry(t);
    }
    public HashSet<string> Selection { get; } = [];
    public string? Toast { get; private set; }
    public Host? EditingHost { get; private set; }

    public SyncKind Sync { get; private set; } = SyncKind.Off;
    public DateTimeOffset? LastSynced { get; private set; }
    public string? SyncError { get; private set; }
    public AvailableUpdate? Update { get; private set; }
    public bool UpdateDismissed { get; set; }
    public bool UpdateBusy { get; private set; }
    public double UpdateProgress { get; private set; }
    public string? UpdateStatus { get; private set; }
    public string? UpdateError { get; private set; }

    public TunnelManager Tunnels { get; } = new();
    public SftpModel Sftp { get; }
    public StackModel Stack { get; }
    public DockerModel Docker { get; }
    public DashboardModel Dashboard { get; }
    public AdminModel Admin { get; }
    public BackupModel Backups { get; }

    public bool IsDark { get; private set; } = true;
    public string Appearance { get; private set; } = Settings.Str(Settings.Appearance) ?? "dark";

    /// <summary>Kategori perubahan: phase, data, nav, sessions, toast, sync, update, editing, selection, theme, db, sftp, tunnels.</summary>
    public event Action<string>? Changed;

    private Vault? _vault;
    private CancellationTokenSource? _syncCts;
    private DriveClient.RemoteFile? _remoteFile;
    private readonly DispatcherQueue _dq;
    private readonly Windows.UI.ViewManagement.UISettings _ui = new();

    public AppModel()
    {
        _dq = DispatcherQueue.GetForCurrentThread();
        Phase = ZtermCoreMethods.VaultExists(Config.VaultPath) ? Phase.Locked : Phase.Welcome;
        Sftp = new SftpModel(this);
        Stack = new StackModel(this);
        Docker = new DockerModel(this);
        Dashboard = new DashboardModel(this);
        Admin = new AdminModel(this);
        Backups = new BackupModel(this);
        Tunnels.Changed += () => Raise("tunnels");
        IsDark = ComputeDark();
        _ui.ColorValuesChanged += (_, _) => _dq.TryEnqueue(() =>
        {
            var d = ComputeDark();
            if (d != IsDark) { IsDark = d; Raise("theme"); }
        });
    }

    public void Raise(string what) => Changed?.Invoke(what);

    /// <summary>
    /// Raise untuk alur update: kegagalan render UI tidak boleh membatalkan unduhan.
    /// </summary>
    private void SafeRaise(string what)
    {
        try { Raise(what); }
        catch (Exception e) { UpdateLog.Write("UI error saat raise '" + what + "': " + e); }
    }

    private void SafeFlash(string message)
    {
        try { Flash(message); }
        catch (Exception e) { UpdateLog.Write("UI error saat flash: " + e); }
    }

    // MARK: Tampilan

    private bool ComputeDark()
    {
        if (Appearance == "light") return false;
        if (Appearance == "dark") return true;
        var bg = _ui.GetColorValue(Windows.UI.ViewManagement.UIColorType.Background);
        return bg.R < 128;
    }

    public void SetAppearance(string mode)
    {
        Appearance = mode;
        Settings.Set(Settings.Appearance, mode);
        IsDark = ComputeDark();
        foreach (var s in Sessions) if (s.ThemeId == null) s.PushTheme();
        Raise("theme");
    }

    public bool HideAddresses
    {
        get => Settings.Bool(Settings.HideAddresses, true);
        set { Settings.Set(Settings.HideAddresses, value); Raise("data"); }
    }

#if DEBUG
    /// <summary>Vault contoh untuk tes tampilan (hanya build debug, folder ZTERM_DATA_DIR).</summary>
    public void LoadDemo()
    {
        var path = Config.VaultPath;
        var v = File.Exists(path) ? Vault.Unlock(path, "demo-password-123") : Vault.Create(path, "demo-password-123");
        if (v.Hosts().Length == 0)
        {
            var samples = new[] {
                ("prod-api", "10.0.1.10", "Production", new[] { "api", "prod" }, "#3FD0B4", "ubuntu"),
                ("prod-db", "10.0.1.20", "Production", new[] { "postgres" }, "#F0616D", "postgres"),
                ("staging", "staging.zterm.local", "Staging", new[] { "web" }, "#5B9CF5", "deploy"),
                ("homelab", "192.168.1.5", (string?)null, new[] { "pi" }, "#9D7CF2", "pi"),
            };
            foreach (var (label, hostname, group, tags, color, user) in samples)
                v.UpsertHost(HostExt.Blank() with { Label = label, Hostname = hostname, Group = group, Tags = tags, Color = color, Username = user });
            v.GenerateKey("Laptop Windows");
            var hs = v.Hosts();
            v.UpsertSnippet(new Snippet("", "Cek disk", "df -h", 0, false));
            v.UpsertSnippet(new Snippet("", "Update sistem", "sudo apt update && sudo apt upgrade -y", 0, false));
            v.UpsertForward(new PortForward("", "Postgres prod", hs[1].Id, ForwardKind.Local, "127.0.0.1", 5433, "localhost", 5432, 0, false));
            var l = v.StartLog(hs[0].Id, hs[0].Title(), hs[0].Address());
            v.FinishLog(l, 0);
            v.UpsertDatabase(new DbConnection("", "Produksi API", DbEngine.Postgres, "10.0.1.20", 5432, "postgres", null, "app", "", true, hs[0].Id, "#336791", 0, false));
            v.UpsertDatabase(new DbConnection("", "Cache", DbEngine.Redis, "127.0.0.1", 6379, "", null, "0", "", false, null, "#DC382D", 0, false));
        }
        var env = Environment.GetEnvironmentVariable("ZTERM_TEST_HOST");
        if (env is { Length: > 0 })
        {
            // ZTERM_TEST_HOST=user@host:port ; ZTERM_TEST_PW=password ; ZTERM_TEST_KEY=path private key
            var at = env.IndexOf('@'); var colon = env.LastIndexOf(':');
            var h = HostExt.Blank() with
            {
                Label = "server-tes", Username = env[..at], Hostname = env[(at + 1)..colon], Port = ushort.Parse(env[(colon + 1)..]), Color = "#F2A65A",
                Password = Environment.GetEnvironmentVariable("ZTERM_TEST_PW"),
            };
            if (Environment.GetEnvironmentVariable("ZTERM_TEST_KEY") is { Length: > 0 } kp)
            {
                var pem = File.ReadAllText(kp);
                var k = v.Keys().FirstOrDefault(x => x.Label == "tes-terminal" && x.PrivateKey.Trim() == pem.Trim())
                        ?? v.ImportKey("tes-terminal", pem, Environment.GetEnvironmentVariable("ZTERM_TEST_KEYPASS"));
                h = h with { Auth = AuthMethod.Key, KeyId = k.Id };
            }
            // ZTERM_TEST_PROXY=socks5|http,host,port,user,pass
            if (Environment.GetEnvironmentVariable("ZTERM_TEST_PROXY") is { Length: > 0 } px && px.Split(',') is { Length: 5 } pp)
                h = h with { Proxy = new HostProxy(pp[0] == "http" ? ProxyKind.Http : ProxyKind.Socks5, pp[1], ushort.Parse(pp[2]), pp[3], pp[4]) };
            var old = v.Hosts().FirstOrDefault(x => x.Label == "server-tes");
            v.UpsertHost(old == null ? h : h with { Id = old.Id });
        }
        // ZTERM_DASH_HOSTS="label|host|port|user|grup|#warna;..." (key ZTERM_TEST_KEY) menggantikan semua host contoh
        if (Environment.GetEnvironmentVariable("ZTERM_DASH_HOSTS") is { Length: > 0 } dash && Environment.GetEnvironmentVariable("ZTERM_TEST_KEY") is { Length: > 0 } dkp)
        {
            var pem = File.ReadAllText(dkp);
            var k = v.Keys().FirstOrDefault(x => x.Label == "tes-dashboard" && x.PrivateKey.Trim() == pem.Trim()) ?? v.ImportKey("tes-dashboard", pem, null);
            foreach (var old in v.Hosts()) v.DeleteHost(old.Id);
            foreach (var item in dash.Split(';'))
            {
                var f = item.Split('|');
                if (f.Length != 6 || !ushort.TryParse(f[2], out var port)) continue;
                v.UpsertHost(HostExt.Blank() with { Label = f[0], Hostname = f[1], Port = port, Username = f[3], Group = f[4].Length == 0 ? null : f[4], Color = f[5], Auth = AuthMethod.Key, KeyId = k.Id });
            }
        }
        Open(v);
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_SECTION") is { Length: > 0 } sec && Enum.TryParse<Section>(sec, true, out var s)) Navigate(s);
        // Tes Tim dengan Drive tiruan: ZTERM_DRIVE_BASE + ZTERM_TEST_DRIVE_TOKEN/EMAIL; ZTERM_DEMO_TEAM=admin|member
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_TEAM") is { Length: > 0 } role) _ = DemoTeam(role);
        // ZTERM_DEMO_STACK=web,postgres : nyalakan layanan Server Lokal; ZTERM_DEMO_STACK_INSTALL=nginx,php : unduh dulu
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_STACK") is { } stackList) _ = DemoStack(stackList);
        // ZTERM_DEMO_DOCKER=<id host> | local : buka halaman Docker
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_DOCKER") is { Length: > 0 } dk) _ = DemoDocker(dk);
        // ZTERM_DEMO_SPLIT=3 : split terminal lokal; ZTERM_DEMO_BROADCAST=1; ZTERM_DEMO_SPLIT_TYPE = teks diketik di panel aktif
        if (int.TryParse(Environment.GetEnvironmentVariable("ZTERM_DEMO_SPLIT"), out var n) && n > 1) _ = DemoSplit(n);
        // ZTERM_DEMO_BACKUP_DB="label|engine|port|user|pw|db|host ssh" : koneksi tes + dialog Backup; ZTERM_DEMO_BACKUP_RUN=1
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_BACKUP_DB") is { Length: > 0 } bspec && bspec.Split('|') is { Length: 7 } bf)
        {
            var engine = bf[1] == "postgres" ? DbEngine.Postgres : bf[1] == "mariadb" ? DbEngine.Mariadb : DbEngine.Mysql;
            var ssh = Hosts.FirstOrDefault(h => h.Title() == bf[6])?.Id;
            var saved = _vault!.UpsertDatabase(new DbConnection("", bf[0], engine, "127.0.0.1", ushort.Parse(bf[2]), bf[3], bf[4], bf[5], "", false, ssh, "#C0765A", 0, false));
            DataChanged();
            Navigate(Section.Database);
            _ = DemoBackup(saved);
        }
        // ZTERM_DEMO_ADMIN=judul host, ZTERM_DEMO_ADMIN_TAB=Processes|Services|Cron|Logs, ZTERM_DEMO_ADMIN_SERVICE=nama
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_ADMIN") is { Length: > 0 } adm) _ = DemoAdmin(adm);
        // ZTERM_DEMO_DASHBOARD_SELECT=judul1,judul2 : pilih server; ZTERM_DEMO_DASHBOARD_SPLIT = teks diketik setelah Split & broadcast
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_DASHBOARD_SELECT") is { Length: > 0 } dsel) _ = DemoDashboard(dsel);
        var test = Hosts.FirstOrDefault(x => x.Label == "server-tes");
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_LIGHT") == "1") SetAppearance("light");
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_EDIT") is "1" or "test") Edit(Environment.GetEnvironmentVariable("ZTERM_DEMO_EDIT") == "test" ? test : Hosts.FirstOrDefault());
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_SFTP") == "1" && test != null) _ = DemoSftp(test);
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_TUNNEL") is { Length: > 0 } tport && test != null)
        {
            // Tunnel tes: 127.0.0.1:<tport> → 127.0.0.1:<port ssh server> lewat server-tes
            var f = Forwards.FirstOrDefault(x => x.Label == "tunnel-tes") ?? _vault!.UpsertForward(new PortForward("", "tunnel-tes", test.Id, ForwardKind.Local, "127.0.0.1", ushort.Parse(tport), "127.0.0.1", test.Port, 0, false));
            Reload();
            Navigate(Section.Forwarding);
            ToggleTunnel(f);
        }
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_DB") == "1")
        {
            if (Environment.GetEnvironmentVariable("ZTERM_DEMO_DBTREE") is "0" or "1") Settings.Set(Settings.DbShowTree, Environment.GetEnvironmentVariable("ZTERM_DEMO_DBTREE") == "1");
            var file = Path.Combine(Config.DataDir, "toko.sqlite");
            var conn = Databases.FirstOrDefault(x => x.Label == "Toko Lokal") ?? _vault!.UpsertDatabase(new DbConnection("", "Toko Lokal", DbEngine.Sqlite, "", 0, "", null, "", file, false, null, "#0F80CC", 0, false));
            Reload();
            _ = Task.Run(async () =>
            {
                if (!File.Exists(file))
                {
                    var s = await DbSession.Connect(conn, null);
                    await s.Run("CREATE TABLE produk (id INTEGER PRIMARY KEY, nama TEXT, harga INTEGER, stok INTEGER, kategori TEXT)");
                    await s.Run("CREATE TABLE pelanggan (id INTEGER PRIMARY KEY, nama TEXT, kota TEXT)");
                    await s.Run("CREATE VIEW stok_rendah AS SELECT * FROM produk WHERE stok < 10");
                    await s.Run("INSERT INTO produk (nama, harga, stok, kategori) VALUES ('Kopi Gayo 250g', 85000, 42, 'Minuman'), ('Teh Tarik', 18000, 7, 'Minuman'), ('Keripik Pisang', 22000, 120, 'Camilan'), ('Kue Adee', 35000, NULL, 'Kue'), ('Madu Hutan', 120000, 5, 'Herbal'), ('Kopi Ulee Kareng', 65000, 31, 'Minuman')");
                }
            }).ContinueWith(_ => _dq.TryEnqueue(async () =>
            {
                await OpenDatabase(conn);
                var mode = Environment.GetEnvironmentVariable("ZTERM_DEMO_DBTAB");
                if (DbWorkspace is { } ws && ws.DbTables.TryGetValue("main", out var tables) && tables.FirstOrDefault(x => x.Name == "produk") is { } t && mode != "overview")
                {
                    if (mode == "sql") { ws.CurrentTab = DbWorkspace.Tab.Sql; ws.Query = "SELECT nama, harga, stok, kategori FROM produk ORDER BY harga DESC;"; await ws.OpenTable(t, "main"); await ws.SetTab(DbWorkspace.Tab.Sql); await ws.Run(); }
                    else if (mode == "structure") { await ws.OpenTable(t, "main"); await ws.SetTab(DbWorkspace.Tab.Structure); }
                    else if (mode == "search")
                    {
                        // ZTERM_DEMO_DBFIND=kolom=nilai;kolom=nilai ; ZTERM_DEMO_DBSUBMIT=1 ; ZTERM_DEMO_DBQUICK=teks
                        await ws.OpenTable(t, "main"); await ws.SetTab(DbWorkspace.Tab.Search);
                        foreach (var pair in (Environment.GetEnvironmentVariable("ZTERM_DEMO_DBFIND") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
                            if (pair.Split('=', 2) is [var k, var v] && ws.SearchForm.FirstOrDefault(x => x.Column == k) is { } fld) fld.Value = v;
                        await ws.SetTab(DbWorkspace.Tab.Search);
                        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_DBSUBMIT") == "1") await ws.SubmitSearch();
                        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_DBQUICK") is { Length: > 0 } q) { ws.QuickSearch = q; await ws.SubmitQuickSearch(); }
                    }
                    else await ws.OpenTable(t, "main");
                }
            }));
        }
        // ZTERM_DEMO_LOCAL=powershell|cmd|wsl|pwsh : buka terminal lokal (ZTERM_DEMO_RUN dikirim setelah siap)
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_LOCAL") is { Length: > 0 } ls)
            OpenLocalTerminal(LocalShell.Available.FirstOrDefault(x => x.Id == ls), Environment.GetEnvironmentVariable("ZTERM_DEMO_RUN"));
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_CONNECT") == "1" && Hosts.FirstOrDefault(x => x.Label == "server-tes") is { } t)
        {
            Connect([t.Id], Environment.GetEnvironmentVariable("ZTERM_DEMO_RUN"));
            if (Environment.GetEnvironmentVariable("ZTERM_DEMO_INFO") == "1") ToggleServerInfo(true);
            // ZTERM_DEMO_TYPE = ketikan dipisah "|" (\r = Enter, <accept> = terima saran autocomplete)
            var steps = (Environment.GetEnvironmentVariable("ZTERM_DEMO_TYPE") ?? "").Split('|').Select(x => x.Replace("\\r", "\r")).ToList();
            for (int i = 0; i < steps.Count; i++)
            {
                var step = steps[i];
                if (step.Length == 0) continue;
                _ = Task.Delay(4000 + i * 1300).ContinueWith(_ => _dq.TryEnqueue(() =>
                {
                    if (step == "<accept>") ActiveSession?.DebugAccept(); else ActiveSession?.Send(step);
                }));
            }
        }
    }
#endif

    // MARK: Vault

    public void SetPhase(Phase p) { Phase = p; Raise("phase"); }

    public async Task CreateVault(string password)
    {
        var path = Config.VaultPath;
        var v = await Task.Run(() => Vault.Create(path, password));
        if (PendingAccountEmail != null) v.SetAccountEmail(PendingAccountEmail);
        Open(v);
        if (HelloUnlock.HasStoredKey) HelloUnlock.Store(v.ExportKey());
    }

    public async Task Unlock(string password)
    {
        var path = Config.VaultPath;
        var v = await Task.Run(() => Vault.Unlock(path, password));
        Open(v);
        if (HelloUnlock.HasStoredKey) HelloUnlock.Store(v.ExportKey());
    }

    /// <summary>Pulihkan vault dari Google Drive di perangkat ini.</summary>
    public async Task Restore(string password)
    {
        if (PendingRemoteBlob == null) return;
        var path = Config.VaultPath;
        await File.WriteAllBytesAsync(path, PendingRemoteBlob);
        try
        {
            var v = await Task.Run(() => Vault.Unlock(path, password));
            if (PendingAccountEmail != null) v.SetAccountEmail(PendingAccountEmail);
            PendingRemoteBlob = null;
            Open(v);
        }
        catch
        {
            try { File.Delete(path); } catch { }
            throw;
        }
    }

    public async Task UnlockWithHello()
    {
        var key = await HelloUnlock.Retrieve();
        var path = Config.VaultPath;
        var v = await Task.Run(() => Vault.UnlockWithKey(path, key));
        Open(v);
    }

    public void EnableHello(bool on)
    {
        if (on && _vault != null) HelloUnlock.Store(_vault.ExportKey());
        else HelloUnlock.Forget();
        Raise("data");
    }

    public void Lock()
    {
        _ = Sftp.Disconnect();
        foreach (var s in Sessions) s.Terminate();
        Tunnels.StopAll();
        _syncCts?.Cancel();
        Sessions.Clear();
        ActiveSessionId = null;
        _vault = null;
        Hosts = []; Keys = []; Snippets = []; Forwards = []; Logs = []; Databases = [];
        Teams = []; TeamKeys = []; TeamInvites = []; TeamError = null;
        _teamTimer?.Stop();
        DbWorkspace = null;
        EditingHost = null;
        Selection.Clear();
        Dashboard.Reset();
        Admin.Close();
        Backups.StopTimer();
        Raise("sessions");
        SetPhase(Phase.Locked);
    }

    private void Open(Vault v)
    {
        _vault = v;
        Reload();
        AccountEmail = v.AccountEmail();
        Sync = AccountEmail == null ? SyncKind.Off : SyncKind.Idle;
        SetPhase(Phase.Main);
        if (AccountEmail != null) SyncNow();
        _ = CheckForUpdates(false);
        StartTeamTimer();
        Backups.StartTimer();
        _ = Backups.RunDue();
    }

    public async Task CheckForUpdates(bool manual)
    {
        if (UpdateBusy) return;
        try
        {
            var u = await UpdateChecker.Check();
            Update = u;
            UpdateError = null;
            if (u != null) UpdateDismissed = false;
            SafeRaise("update");
            if (manual && u == null) Flash(L.T("Zterm {} sudah versi terbaru", Config.Version));
        }
        catch (Exception e)
        {
            UpdateLog.Write("Gagal memeriksa pembaruan: " + e);
            if (manual) Flash(L.T("Gagal memeriksa pembaruan"));
        }
    }

    /// <summary>Sembunyikan notifikasi untuk sesi ini. Pemeriksaan berikutnya (mis. saat app dibuka lagi) akan menampilkannya lagi.</summary>
    public void DismissUpdate()
    {
        UpdateDismissed = true;
        UpdateError = null;
        SafeRaise("update");
    }

    /// <summary>Unduh installer, jalankan pemasangan senyap, lalu tutup app. Installer membuka Zterm lagi setelah selesai.</summary>
    public async Task InstallUpdateAsync()
    {
        if (Update is not { } u || UpdateBusy) return;
        UpdateBusy = true;
        UpdateDismissed = false;
        UpdateError = null;
        UpdateProgress = 0;
        UpdateStatus = L.T("Mengunduh pembaruan…");
        UpdateLog.Write($"Mulai update ke {u.Version} ({u.AssetName ?? "tanpa aset"}).");
        SafeRaise("update");

        var downloading = true;
        var progress = new Progress<double>(p =>
        {
            // Progress<T> sudah kembali ke UI thread. Laporan dari UpdateInstaller
            // dibatasi ~12/detik supaya antrean DispatcherQueue tidak membanjir.
            if (!downloading) return;
            UpdateProgress = p;
            UpdateStatus = L.T("Mengunduh pembaruan… {}%", (int)Math.Round(p * 100));
            SafeRaise("update-progress");
        });

        try
        {
            // Jalankan unduhan + hash di thread pool; UI hanya menerima laporan progress.
            var installer = await Task.Run(() => UpdateInstaller.DownloadAsync(u, progress));
            downloading = false;
            UpdateLog.Write($"Unduhan selesai: {installer}");
            UpdateProgress = 1;
            UpdateStatus = L.T("Menyiapkan pembaruan…");
            SafeRaise("update-progress");
            await Task.Delay(300);

            UpdateStatus = L.T("Zterm akan ditutup dan dibuka ulang.");
            SafeRaise("update-progress");
            await Task.Delay(250);

            // Tutup sesi lebih dulu supaya file Zterm.exe tidak terkunci saat installer
            // menggantinya. Installer juga memakai CloseApplications=force sebagai cadangan.
            try { foreach (var s in Sessions) s.Terminate(); } catch { }
            try { Tunnels.StopAll(); } catch { }
            try { Stack.Stack?.StopAll(); } catch { }

            // Installer memasang, lalu membuka Zterm lagi lewat [Run] di Zterm.iss.
            UpdateInstaller.Launch(installer);
            UpdateLog.Write("Installer diluncurkan; app akan ditutup.");

            // Jaring pengaman: kalau Application.Exit() tertahan, proses tetap berakhir
            // sehingga file Zterm.exe tidak terkunci saat installer menggantinya.
            _ = Task.Run(async () => { await Task.Delay(2500); Environment.Exit(0); });
            try { Application.Current.Exit(); }
            catch (Exception e) { UpdateLog.Write("Application.Exit error: " + e); }
        }
        catch (Exception e)
        {
            downloading = false;
            UpdateBusy = false;
            UpdateProgress = 0;
            UpdateStatus = null;
            UpdateError = L.T("Gagal memasang pembaruan: {}", Errors.Text(e));
            UpdateLog.Write("Update gagal: " + e);
            SafeRaise("update");
            SafeFlash(UpdateError);
        }
    }

    private void Reload()
    {
        if (_vault == null) return;
        Teams = _vault.Teams();
        // Host tim ikut tampil di daftar host (read-only)
        Hosts = [.. _vault.Hosts(), .. _vault.TeamHosts()];
        TeamKeys = _vault.TeamKeys();
        Keys = _vault.Keys();
        Snippets = _vault.Snippets();
        Forwards = _vault.Forwards();
        Logs = _vault.Logs();
        Databases = _vault.Databases();
        // Notifikasi Dashboard aktif → pantau terus, ikut perubahan host
        if (Dashboard?.Alerts == true) Dashboard.Start();
    }

    // MARK: Dashboard

    public void SetDashboardAlerts(bool on)
    {
        if (on && !Notifier.Allowed)
        {
            Flash(L.T("Notifikasi diblokir — izinkan Zterm di Settings Windows → Sistem → Notifikasi"));
            return;
        }
        Dashboard.Alerts = on;
        if (on) { Dashboard.Start(); Flash(L.T("Notifikasi aktif — Dashboard memantau semua server di latar belakang")); }
        else if (Section != Section.Dashboard || ActiveSessionId != null) Dashboard.Stop();
        Raise("dashboard");
    }

    /// <summary>Dialog "Jalankan perintah"; <paramref name="ids"/> kosong → semua server online (atau semua host).</summary>
    public RunManyModel NewRunMany(IEnumerable<string> ids)
    {
        var chosen = ids.ToHashSet();
        if (chosen.Count == 0) chosen = Dashboard.Tiles.Values.Where(t => t.State == ServerTile.Status.Online).Select(t => t.Id).ToHashSet();
        if (chosen.Count == 0) chosen = Hosts.Select(h => h.Id).ToHashSet();
        return new RunManyModel(this, chosen);
    }

    /// <summary>Setelah setiap perubahan data: muat ulang tampilan & jadwalkan sync.</summary>
    private void DataChanged()
    {
        Reload();
        Raise("data");
        foreach (var s in Sessions) s.PushConfig();
        ScheduleSync();
    }

    // MARK: Akun Google & sync

    private void SaveProfile(string? name, string? picture)
    {
        Settings.Set(Settings.ProfileName, name);
        Settings.Set(Settings.ProfilePicture, picture);
        ProfileName = name;
    }

    /// <summary>Login Google. Jika vault sudah ada di Drive (dan belum ada vault lokal), kembalikan true (perlu dipulihkan).</summary>
    public async Task<bool> SignInGoogle()
    {
        var r = await GoogleAuth.SignIn();
        SaveProfile(r.Name, r.Picture);
        PendingAccountEmail = r.Email;
        if (_vault != null)
        {
            _vault.SetAccountEmail(r.Email);
            AccountEmail = r.Email;
            Sync = SyncKind.Idle;
            Raise("sync");
            SyncNow();
            return false;
        }
        if (await DriveClient.Find() is { } file)
        {
            PendingRemoteBlob = await DriveClient.Download(file);
            return true;
        }
        return false;
    }

    public void DisconnectGoogle()
    {
        GoogleTokens.Forget();
        SaveProfile(null, null);
        try { _vault?.SetAccountEmail(null); } catch { }
        AccountEmail = null;
        _remoteFile = null;
        Sync = SyncKind.Off;
        Raise("sync");
    }

    /// <summary>Keluar: putuskan Google & kunci; jika deleteLocal, hapus vault & kunci Hello dari PC ini.</summary>
    public void SignOut(bool deleteLocal)
    {
        DisconnectGoogle();
        Lock();
        if (!deleteLocal) return;
        try { File.Delete(Config.VaultPath); } catch { }
        HelloUnlock.Forget();
        PendingRemoteBlob = null;
        PendingAccountEmail = null;
        SetPhase(Phase.Welcome);
    }

    private void ScheduleSync()
    {
        if (AccountEmail == null) return;
        _syncCts?.Cancel();
        var cts = _syncCts = new CancellationTokenSource();
        _ = Task.Delay(2500, cts.Token).ContinueWith(t => { if (!t.IsCanceled) _dq.TryEnqueue(() => _ = PerformSync(cts.Token)); });
    }

    public void SyncNow()
    {
        if (AccountEmail == null) return;
        _syncCts?.Cancel();
        var cts = _syncCts = new CancellationTokenSource();
        _ = PerformSync(cts.Token);
    }

    private async Task PerformSync(CancellationToken ct)
    {
        if (_vault == null) return;
        var vault = _vault;
        if (!GoogleTokens.HasRefreshToken) { Sync = SyncKind.NeedsLogin; Raise("sync"); return; }
        Sync = SyncKind.Syncing; Raise("sync");
        try
        {
            var remote = await DriveClient.Find();
            _remoteFile = remote;
            if (ct.IsCancellationRequested) return;
            if (remote != null)
            {
                var blob = await DriveClient.Download(remote);
                var outcome = vault.MergeRemote(blob);
                if (outcome.LocalChanged) { Reload(); Raise("data"); }
                if (outcome.RemoteOutdated) await DriveClient.Upload(vault.EncryptedBlob(), remote);
            }
            else
            {
                await DriveClient.Upload(vault.EncryptedBlob(), null);
            }
            Sync = SyncKind.Synced; LastSynced = DateTimeOffset.Now; SyncError = null;
            if (Teams.Length > 0) await SyncTeams();
        }
        catch (NotSignedInException) { Sync = SyncKind.NeedsLogin; }
        catch (Exception e) { Sync = SyncKind.Failed; SyncError = Errors.Text(e); }
        Raise("sync");
    }

    public string SyncStatusText => Sync switch
    {
        SyncKind.Off => L.T("Lokal saja"),
        SyncKind.Idle => L.T("Siap sync"),
        SyncKind.Syncing => L.T("Menyinkronkan…"),
        SyncKind.Synced => LastSynced is { } d && DateTimeOffset.Now - d < TimeSpan.FromMinutes(1) ? L.T("Tersinkron") : L.T("Sinkron {}", Ui.Relative(LastSynced ?? DateTimeOffset.Now)),
        SyncKind.Failed => L.T("Sync gagal — klik untuk ulang"),
        _ => L.T("Masuk ulang Google"),
    };

    // MARK: Navigasi

    public void Navigate(Section s)
    {
        Section = s;
        ActiveSessionId = null;
        Raise("nav");
    }

    public void ShowHome() { ActiveSessionId = null; Raise("nav"); }

    public void Edit(Host? h) { EditingHost = h; Raise("editing"); }

    public void ToggleSelect(string id)
    {
        if (!Selection.Remove(id)) Selection.Add(id);
        Raise("selection");
    }

    public void SetSelection(IEnumerable<string> ids) { Selection.Clear(); foreach (var i in ids) Selection.Add(i); Raise("selection"); }

    // MARK: Hosts

    public Host? Save(Host host)
    {
        if (_vault == null) return null;
        if (host.IsTeam()) { Flash(L.T("Host tim hanya bisa diubah admin tim")); return null; }
        try
        {
            var saved = _vault.UpsertHost(host);
            foreach (var s in Sessions.Where(s => s.Host.Id == saved.Id && s.ThemeId != saved.TerminalTheme)) s.ApplyTheme(saved.TerminalTheme);
            DataChanged();
            return saved;
        }
        catch (Exception e) { Flash(Errors.Text(e)); return null; }
    }

    public void Delete(Host host)
    {
        if (host.IsTeam()) { Flash(L.T("Host tim hanya bisa diubah admin tim")); return; }
        try { _vault?.DeleteHost(host.Id); } catch { }
        Selection.Remove(host.Id);
        if (EditingHost?.Id == host.Id) Edit(null);
        DataChanged();
    }

    public Host? HostById(string? id) => id == null ? null : Hosts.FirstOrDefault(h => h.Id == id);
    public SshKey? KeyById(string? id) => id == null ? null : Keys.FirstOrDefault(k => k.Id == id) ?? TeamKeys.FirstOrDefault(k => k.Id == id);
    /// <summary>Host pribadi saja (tanpa host tim).</summary>
    public Host[] OwnHosts => Hosts.Where(h => !h.IsTeam()).ToArray();

    // MARK: Keychain

    public SshKey GenerateKey(string label)
    {
        var k = _vault!.GenerateKey(label);
        DataChanged();
        return k;
    }

    public void ImportKey(string label, string privateKey, string? passphrase)
    {
        _vault!.ImportKey(label, privateKey, passphrase);
        DataChanged();
    }

    public void RenameKey(SshKey k, string label) { try { _vault?.RenameKey(k.Id, label); } catch { } DataChanged(); }
    public void DeleteKey(SshKey k) { try { _vault?.DeleteKey(k.Id); } catch { } DataChanged(); }

    // MARK: Snippets

    public void Save(Snippet s) { try { _vault?.UpsertSnippet(s); DataChanged(); } catch (Exception e) { Flash(Errors.Text(e)); } }
    public void Delete(Snippet s) { try { _vault?.DeleteSnippet(s.Id); } catch { } DataChanged(); }

    public void RunInActiveSession(Snippet s) => ActiveSession?.Send(s.Command + "\r");

    // MARK: Port forwarding

    public void Save(PortForward f) { try { _vault?.UpsertForward(f); DataChanged(); } catch (Exception e) { Flash(Errors.Text(e)); } }

    public void Delete(PortForward f)
    {
        Tunnels.Stop(f.Id);
        try { _vault?.DeleteForward(f.Id); } catch { }
        DataChanged();
    }

    public void ToggleTunnel(PortForward f)
    {
        if (Tunnels.IsRunning(f.Id)) Tunnels.Stop(f.Id);
        else if (HostById(f.HostId) is { } h) Tunnels.Start(f, h, KeyById(h.KeyId), HostById(h.JumpHostId));
        else Flash(L.T("Host untuk aturan ini sudah tidak ada"));
    }

    // MARK: Database

    public void Save(DbConnection c) { try { _vault?.UpsertDatabase(c); DataChanged(); } catch (Exception e) { Flash(Errors.Text(e)); } }

    public void Delete(DbConnection c)
    {
        if (DbWorkspace?.Conn.Id == c.Id) DbWorkspace = null;
        try { _vault?.DeleteDatabase(c.Id); } catch { }
        DataChanged();
    }

    public async Task OpenDatabase(DbConnection c)
    {
        var ws = new DbWorkspace(c);
        DbWorkspace = ws;
        Section = Section.Database;
        ActiveSessionId = null;
        Raise("nav");
        await ws.Connect(SshTarget(c.SshHostId));
    }

    public void CloseDatabase() { DbWorkspace = null; Raise("db"); }

    /// <summary>Target SSH dari host tersimpan (untuk tunnel database & SFTP).</summary>
    public SshTarget? SshTarget(string? id)
    {
        if (HostById(id) is not { } h) return null;
        var k = KeyById(h.KeyId);
        return new SshTarget(h.Hostname, h.Port, h.Username,
            h.Auth == AuthMethod.Password ? h.Password : null,
            h.Auth == AuthMethod.Key ? k?.PrivateKey : null,
            h.Auth == AuthMethod.Key ? k?.Passphrase : null, true, h.Proxy);
    }

    // MARK: SFTP

    public async Task OpenSftp(Host h)
    {
        Section = Section.Sftp;
        ActiveSessionId = null;
        Raise("nav");
        await Sftp.Connect(h, KeyById(h.KeyId));
    }

    // MARK: Logs

    public string? LogStart(Host h)
    {
        try { var id = _vault?.StartLog(h.Id, h.Title(), h.Address()); Reload(); Raise("logs"); return id; } catch { return null; }
    }

    public void LogEnd(string? id, int? code)
    {
        if (id == null || _vault == null) return;
        try { _vault.FinishLog(id, code); } catch { }
        Reload();
        Raise("logs");
        ScheduleSync();
    }

#if DEBUG
    private async Task DemoDocker(string dk)
    {
        Navigate(Section.Docker);
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_DOCKER_QUERY") is { } q) Docker.Query = q;
        await Docker.Select(dk == "local" ? null : Hosts.FirstOrDefault(h => h.Label == dk)?.Id);
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_DOCKER_SELECT") is { } name && Docker.Containers.FirstOrDefault(c => c.Name == name) is { } c)
            Docker.Choose(c);
    }

    private async Task DemoBackup(DbConnection c)
    {
        await Task.Delay(1500);
        new Views.BackupDialog(c).Show();
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_BACKUP_RUN") == "1") await Backups.Backup(c);
    }

    private async Task DemoAdmin(string name)
    {
        if (Hosts.FirstOrDefault(h => h.Title() == name) is not { } h) return;
        if (Enum.TryParse<AdminModel.Tab>(Environment.GetEnvironmentVariable("ZTERM_DEMO_ADMIN_TAB"), true, out var tab)) Admin.Current = tab;
        Navigate(Section.ServerAdmin);
        await Admin.Select(h.Id);
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_ADMIN_SERVICE") is { Length: > 0 } svc)
        {
            if (Admin.Current == AdminModel.Tab.Logs) Admin.ShowLogs(svc); else Admin.ChooseService(svc);
        }
    }

    private async Task DemoDashboard(string names)
    {
        Navigate(Section.Dashboard);
        // ZTERM_DEMO_ALERTS=<file> : pantau di latar belakang, catat peringatan ke file (tanpa notifikasi)
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_ALERTS") is { Length: > 0 } alertLog)
        {
            Dashboard.Alerts = true;
            Dashboard.Start();
            foreach (var t in Dashboard.Tiles.Values)
                t.OnAlert = (title, body, key) => File.AppendAllText(alertLog, $"ALERT [{key}] {title} — {body}\n");
        }
        // ZTERM_DEMO_RUNMANY=<perintah>, ZTERM_DEMO_RUNMANY_LOG=<file> : buka dialog Jalankan perintah untuk semua host, jalankan, catat hasil
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_RUNMANY") is { Length: > 0 } cmd)
        {
            await Task.Delay(1500);
            var run = NewRunMany(Hosts.Select(h => h.Id));
            run.Command = cmd;
            new Views.RunManyDialog(run).Show();
            run.Run();
            if (Environment.GetEnvironmentVariable("ZTERM_DEMO_RUNMANY_LOG") is { Length: > 0 } log)
            {
                while (run.Running) await Task.Delay(300);
                File.WriteAllText(log, $"RUNMANY ok={run.OkCount} fail={run.FailCount}\n{run.Report()}\n");
            }
            return;
        }
        var set = names.Split(',').ToHashSet();
        foreach (var h in Hosts.Where(h => set.Contains(h.Title()))) Dashboard.Selection.Add(h.Id);
        Raise("dashboard");
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_DASHBOARD_SPLIT") is not { } typed) return;
        await Task.Delay(3000);
        OpenSplit(Dashboard.SelectedIds, true);
        Dashboard.Selection.Clear();
        for (int i = 0; i < 60 && Sessions.Any(s => SplitIds.Contains(s.Id) && s.State != TerminalSession.Status.Connected); i++) await Task.Delay(500);
        await Task.Delay(1500);
        ActiveSession?.Send(typed.Replace("\\r", "\r"));
    }

    private async Task DemoSplit(int n)
    {
        OpenLocalTerminal();
        for (int i = 1; i < n; i++) SplitDuplicate();
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_BROADCAST") == "1") ToggleBroadcast();
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_SPLIT_TYPE") is { } typed)
        {
            // Tunggu semua panel tersambung (shell di VM bisa lambat)
            for (int i = 0; i < 60 && Sessions.Any(s => SplitIds.Contains(s.Id) && s.State != TerminalSession.Status.Connected); i++) await Task.Delay(500);
            await Task.Delay(1500);
            ActiveSession?.Send(typed.Replace("\\r", "\r"));
        }
    }

    private async Task DemoStack(string list)
    {
        Navigate(Section.LocalServer);
        foreach (var id in (Environment.GetEnvironmentVariable("ZTERM_DEMO_STACK_INSTALL") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries))
        {
            Stack.Install(id);
            while (Stack.Downloads.ContainsKey(id)) await Task.Delay(500);
        }
        foreach (var s in list.Split(',', StringSplitOptions.RemoveEmptyEntries)) await Stack.Toggle(s);
    }

    private async Task DemoTeam(string role)
    {
        Navigate(Section.Team);
        if (role == "admin")
        {
            if (!Teams.Any(t => t.IsOwner) && await CreateTeam(Environment.GetEnvironmentVariable("ZTERM_DEMO_TEAM_NAME") ?? "Tim Infra"))
            {
                await ShareHosts(Teams.First(t => t.IsOwner), OwnHosts.Take(2).Select(h => h.Id));
                foreach (var e in (Environment.GetEnvironmentVariable("ZTERM_DEMO_TEAM_INVITE") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries))
                    await InviteToTeam(Teams.First(t => t.IsOwner), e);
            }
        }
        else
        {
            await RefreshInvites();
            if (TeamInvites.FirstOrDefault() is { } inv) await JoinTeam(inv.FileId);
        }
    }

    /// <summary>Demo SFTP: ZTERM_DEMO_SFTP_DIR = folder server, ZTERM_DEMO_SFTP_EDIT / _OPENWITH = nama file, ZTERM_DEMO_SFTP_APPEND = teks ditambah lalu disimpan.</summary>
    private async Task DemoSftp(Host test)
    {
        await OpenSftp(test);
        for (int i = 0; i < 50 && Sftp.State != SftpModel.Status.Connected; i++) await Task.Delay(200);
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_SFTP_DIR") is { Length: > 0 } dir) await Sftp.OpenRemote(dir);
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_SFTP_EDIT") is { Length: > 0 } e && Sftp.RemoteItems.FirstOrDefault(x => x.Name == e) is { } ef)
        {
            await Sftp.OpenEditor(ef);
            if (Environment.GetEnvironmentVariable("ZTERM_DEMO_SFTP_APPEND") is { Length: > 0 } add && Sftp.Editor is { } doc)
            {
                doc.Text += add + doc.LineEnding;
                await Sftp.SaveEditor(doc);
                Sftp.CloseEditor();
                await Sftp.OpenEditor(ef);
            }
        }
        if (Environment.GetEnvironmentVariable("ZTERM_DEMO_SFTP_OPENWITH") is { Length: > 0 } o && Sftp.RemoteItems.FirstOrDefault(x => x.Name == o) is { } of)
            await Sftp.OpenWith(of, Environment.GetEnvironmentVariable("ZTERM_DEMO_SFTP_APP"));
    }
#endif

    public void ClearLogs() { try { _vault?.ClearLogs(); } catch { } DataChanged(); }

    // MARK: Sesi

    /// <summary>Buka satu tab per host. `run` = perintah yang dikirim setelah tersambung.</summary>
    public void Connect(IEnumerable<string> ids, string? run = null)
    {
        var targets = ids.Select(HostById).OfType<Host>().ToList();
        if (targets.Count == 0) return;
        TerminalSession? first = null;
        foreach (var h in targets)
        {
            var s = new TerminalSession(h, KeyById(h.KeyId), HostById(h.JumpHostId), run, this);
            s.Changed += () => Raise("session");
            Sessions.Add(s);
            first ??= s;
        }
        ActiveSessionId = first!.Id;
        Selection.Clear();
        Raise("sessions");
        Raise("selection");
    }

    /// <summary>Buka tab terminal lokal (PowerShell / CMD / WSL).</summary>
    public void OpenLocalTerminal(LocalShell? shell = null, string? run = null)
    {
        shell ??= LocalShell.Default;
        var s = new TerminalSession(shell.AsHost(), null, null, run, this, shell);
        s.Changed += () => Raise("session");
        Sessions.Add(s);
        ActiveSessionId = s.Id;
        Raise("sessions");
    }

    public void Close(TerminalSession s)
    {
        s.Terminate();
        var idx = Sessions.IndexOf(s);
        if (idx < 0) return;
        SplitIds.Remove(s.Id);
        if (SplitIds.Count < 2) { SplitIds.Clear(); Broadcast = false; }
        Sessions.RemoveAt(idx);
        if (ActiveSessionId == s.Id) ActiveSessionId = Sessions.Count == 0 ? null : Sessions[Math.Max(0, idx - 1)].Id;
        Raise("sessions");
    }

    public void Activate(TerminalSession s) { ActiveSessionId = s.Id; Raise("sessions"); s.Focus(); }

    public TerminalSession? ActiveSession => Sessions.FirstOrDefault(s => s.Id == ActiveSessionId);

    public void CloseActive() { if (ActiveSession is { } s) Close(s); }

    public void FocusTab(int n)
    {
        if (n == 0) { ShowHome(); return; }
        if (n >= 1 && n <= Sessions.Count) Activate(Sessions[n - 1]);
    }

    public void CycleTab(int dir)
    {
        if (Sessions.Count == 0) return;
        var i = Sessions.FindIndex(s => s.Id == ActiveSessionId);
        var next = i < 0 ? 0 : (i + dir + Sessions.Count) % Sessions.Count;
        Activate(Sessions[next]);
    }

    public void SessionStatusChanged() => Raise("sessions");

    // MARK: Split & broadcast

    /// <summary>Tab yang ditampilkan berdampingan (2–4); tampil saat tab aktif termasuk di dalamnya.</summary>
    public List<Guid> SplitIds { get; } = [];
    /// <summary>Ketikan di satu panel dikirim ke semua panel split.</summary>
    public bool Broadcast { get; private set; }
    public const int MaxSplit = 4;

    public bool SplitVisible => SplitIds.Count > 1 && ActiveSessionId is { } a && SplitIds.Contains(a);
    public bool CanSplit => ActiveSession != null && (!SplitVisible || SplitIds.Count < MaxSplit);

    private void AddToSplit(Guid id)
    {
        if (ActiveSessionId is not { } active) return;
        if (!SplitVisible) { SplitIds.Clear(); SplitIds.Add(active); }
        if (!SplitIds.Contains(id) && SplitIds.Count < MaxSplit) SplitIds.Add(id);
        ActiveSessionId = id;
        Raise("sessions");
    }

    public void SplitWith(TerminalSession s) => AddToSplit(s.Id);

    public void SplitNew(Host h)
    {
        if (!CanSplit) return;
        var s = new TerminalSession(h, KeyById(h.KeyId), HostById(h.JumpHostId), null, this);
        Sessions.Add(s);
        AddToSplit(s.Id);
    }

    /// <summary>Buka beberapa host sekaligus dalam satu split (dari Dashboard), opsional langsung broadcast.</summary>
    public void OpenSplit(IEnumerable<string> ids, bool broadcast)
    {
        var hs = ids.Select(HostById).OfType<Host>().Take(MaxSplit).ToList();
        if (hs.Count == 0) return;
        var created = hs.Select(h => new TerminalSession(h, KeyById(h.KeyId), HostById(h.JumpHostId), null, this)).ToList();
        Sessions.AddRange(created);
        SplitIds.Clear();
        if (created.Count > 1) SplitIds.AddRange(created.Select(c => c.Id));
        ActiveSessionId = created[0].Id;
        Broadcast = broadcast && created.Count > 1;
        Raise("sessions");
    }

    /// <summary>Panel baru ke host yang sama dengan tab aktif (Ctrl+Shift+D).</summary>
    public void SplitDuplicate()
    {
        if (ActiveSession is not { } s || !CanSplit) return;
        if (s.IsLocal)
        {
            var n = new TerminalSession(s.Host, null, null, null, this, s.Local ?? LocalShell.Default);
            Sessions.Add(n);
            AddToSplit(n.Id);
        }
        else SplitNew(s.Host);
    }

    public void RemoveFromSplit(Guid id)
    {
        SplitIds.Remove(id);
        if (SplitIds.Count < 2) { SplitIds.Clear(); Broadcast = false; }
        Raise("sessions");
    }

    public void Unsplit() { SplitIds.Clear(); Broadcast = false; Raise("sessions"); }

    public void ToggleBroadcast()
    {
        if (!SplitVisible) return;
        Broadcast = !Broadcast;
        Raise("sessions");
    }

    /// <summary>Panel yang diklik jadi tab aktif.</summary>
    public void FocusPane(Guid id)
    {
        if (!SplitVisible || !SplitIds.Contains(id) || ActiveSessionId == id) return;
        ActiveSessionId = id;
        Raise("sessions");
    }

    /// <summary>Teruskan ketikan dari satu panel ke panel split lain (saat broadcast menyala).</summary>
    /// <summary>Balasan otomatis terminal (laporan posisi kursor, atribut perangkat, warna OSC, fokus) — bukan ketikan, jadi tidak di-broadcast.</summary>
    private static readonly System.Text.RegularExpressions.Regex TerminalReply = new(
        @"^(\x1b\[\??[0-9;]*[Rcn]|\x1b\[[>=?][0-9;]*c|\x1b\][0-9]+;[^\x07\x1b]*(\x07|\x1b\\)|\x1b\[[IO]|\x1b\[\??[0-9;]*\$y|\x1bP[^\x1b]*\x1b\\)+$");
    public static bool IsTerminalReply(string data) => data.Length >= 3 && data[0] == '\x1b' && TerminalReply.IsMatch(data);

    public void BroadcastInput(TerminalSession source, string data)
    {
        if (!Broadcast || !SplitVisible || !SplitIds.Contains(source.Id) || IsTerminalReply(data)) return;
        foreach (var s in Sessions)
            if (s != source && SplitIds.Contains(s.Id) && s.State != TerminalSession.Status.Disconnected) s.WriteInput(data);
    }

    public void HandleTerminalShortcut(string k)
    {
        switch (k)
        {
            case "split": SplitDuplicate(); break;
            case "broadcast": ToggleBroadcast(); break;
            case "nextTab": CycleTab(1); break;
            case "prevTab": CycleTab(-1); break;
            case "close": CloseActive(); break;
            case "lock": Lock(); break;
            default:
                if (k.StartsWith("tab") && int.TryParse(k[3..], out var n)) FocusTab(n);
                break;
        }
    }

    public void PushAutocompleteConfig() { foreach (var s in Sessions) s.PushConfig(); }

    public int OnlineCount => Sessions.Where(s => s.State == TerminalSession.Status.Connected).Select(s => s.Host.Id).Distinct().Count();

    // MARK: Tim

    /// <summary>Login Google sudah mengizinkan drive.file (dibutuhkan untuk file Tim).</summary>
    public bool TeamReady =>
#if DEBUG
        Environment.GetEnvironmentVariable("ZTERM_TEST_DRIVE_TOKEN") != null ||
#endif
        AccountEmail != null && GoogleTokens.HasDriveFileScope;

    private static async Task<string> DriveToken()
    {
#if DEBUG
        if (Environment.GetEnvironmentVariable("ZTERM_TEST_DRIVE_TOKEN") is { } t) return t;
#endif
        return await GoogleTokens.ValidAccessToken();
    }

    private string? TeamEmail
    {
        get
        {
#if DEBUG
            if (Environment.GetEnvironmentVariable("ZTERM_TEST_DRIVE_EMAIL") is { } e) return e;
#endif
            if (AccountEmail == null) { TeamError = L.T("Masuk dengan Google dulu untuk memakai Tim"); Raise("team"); }
            return AccountEmail;
        }
    }

    /// <summary>Jalankan operasi Tim dengan token Google; error tampil di halaman Tim.</summary>
    private async Task<T?> TeamCall<T>(Func<Vault, string, Task<T>> op, bool quiet = false) where T : class
    {
        if (_vault is not { } vault) return null;
        if (!quiet) { TeamBusy = true; Raise("team"); }
        try
        {
            var r = await op(vault, await DriveToken());
            if (!quiet) TeamError = null;
            Reload();
            Raise("data");
            return r;
        }
        catch (CoreException.GoogleScope e) { GoogleTokens.MarkDriveFileScope(false); TeamError = Errors.Text(e); }
        catch (Exception e) when (e is NotSignedInException or CoreException.GoogleAuth) { Sync = SyncKind.NeedsLogin; Raise("sync"); TeamError = Errors.Text(new CoreException.GoogleAuth()); }
        catch (Exception e) { if (!quiet) TeamError = Errors.Text(e); }
        finally { if (!quiet) TeamBusy = false; Raise("team"); }
        return null;
    }

    public async Task<bool> CreateTeam(string name)
    {
        if (TeamEmail is not { } email) return false;
        var ok = await TeamCall((v, t) => v.TeamCreate(t, name, email)) != null;
        if (ok) Flash(L.T("Tim {} dibuat", name));
        return ok;
    }

    public async Task<bool> InviteToTeam(TeamInfo team, string email)
    {
        var ok = await TeamCall((v, t) => v.TeamInvite(t, team.Id, email)) != null;
        if (ok) Flash(L.T("Undangan dikirim ke {}", email));
        return ok;
    }

    public async Task RemoveFromTeam(TeamInfo team, string email)
    {
        if (await TeamCall((v, t) => v.TeamRemoveMember(t, team.Id, email)) != null) Flash(L.T("{} dikeluarkan · kunci tim diganti", email));
    }

    public Task ShareHosts(TeamInfo team, IEnumerable<string> ids) => TeamCall((v, t) => v.TeamShareHosts(t, team.Id, ids.ToArray()));

    public async Task RefreshInvites()
    {
        if (await TeamCall((v, t) => v.TeamFindInvites(t), quiet: true) is { } list) { TeamInvites = list; Raise("team"); }
    }

    public async Task<bool> JoinTeam(string fileOrLink)
    {
        if (TeamEmail is not { } email) return false;
        var id = FileIdFrom(fileOrLink);
        if (await TeamCall((v, t) => v.TeamJoin(t, id, email)) is not { } info) return false;
        TeamInvites = TeamInvites.Where(i => i.FileId != id).ToArray();
        Flash(info.Status == TeamStatus.Active ? L.T("Bergabung ke {}", info.Name) : L.T("Bergabung ke {} · menunggu admin", info.Name));
        Raise("team");
        return true;
    }

    public async Task LeaveTeam(TeamInfo team)
    {
        if (await TeamCall<object>(async (v, t) => { await v.TeamLeave(t, team.Id); return team; }) != null)
            Flash(team.IsOwner ? L.T("Tim {} dihapus", team.Name) : L.T("Keluar dari {}", team.Name));
    }

    /// <summary>Sinkron semua tim (diam-diam; error per tim tampil di kartunya).</summary>
    public async Task SyncTeams()
    {
        if (!TeamReady || Teams.Length == 0) return;
        await TeamCall<object>(async (v, t) => await v.TeamSync(t), quiet: true);
    }

    /// <summary>Minta izin drive.file: login ulang Google dengan scope baru.</summary>
    public async Task GrantTeamAccess()
    {
        try
        {
            await SignInGoogle();
            TeamError = GoogleTokens.HasDriveFileScope ? null : L.T("Izin Google Drive belum dicentang. Coba lagi dan centang izin Drive.");
        }
        catch (AuthCancelledException) { }
        catch (Exception e) { TeamError = Errors.Text(e); }
        Raise("team");
    }

    /// <summary>Terima id file atau link Google Drive (…/d/&lt;id&gt;/… atau ?id=&lt;id&gt;).</summary>
    public static string FileIdFrom(string text)
    {
        var t = text.Trim();
        var m = System.Text.RegularExpressions.Regex.Match(t, @"/d/([A-Za-z0-9_-]+)");
        if (m.Success) return m.Groups[1].Value;
        m = System.Text.RegularExpressions.Regex.Match(t, @"[?&]id=([A-Za-z0-9_-]+)");
        return m.Success ? m.Groups[1].Value : t;
    }

    private void StartTeamTimer()
    {
        _teamTimer?.Stop();
        _teamTimer = _dq.CreateTimer();
        var secs = 60.0;
#if DEBUG
        if (double.TryParse(Environment.GetEnvironmentVariable("ZTERM_TEAM_SYNC_SECS"), out var d)) secs = d;
#endif
        _teamTimer.Interval = TimeSpan.FromSeconds(secs);
        _teamTimer.Tick += (s, e) => { if (Phase == Phase.Main) _ = SyncTeams(); };
        _teamTimer.Start();
    }

    public void Flash(string message)
    {
        Toast = message;
        Raise("toast");
        _ = Task.Delay(2600).ContinueWith(_ => _dq.TryEnqueue(() => { if (Toast == message) { Toast = null; Raise("toast"); } }));
    }
}
