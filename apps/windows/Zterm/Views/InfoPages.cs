using System;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using uniffi.zterm_core;

namespace Zterm.Views;

/// <summary>Server yang sudah dipercaya (%USERPROFILE%\.ssh\known_hosts).</summary>
internal sealed class KnownHostsPage : PageBase
{
    private readonly StackPanel _list = Ui.Col(8);
    private string _query = "";

    public KnownHostsPage() : base("data")
    {
        var header = Ui.Header("Known Hosts", L.T("Fingerprint server yang sudah dipercaya — %USERPROFILE%\\.ssh\\known_hosts"),
            Ui.Search(L.T("Cari host…"), "", q => { _query = q; Render(); }, 180),
            Ui.IconBtn(G.Refresh, L.T("Muat ulang"), Render).With(b => b.Background = Theme.Ink(0.07)));
        Children.Add(Ui.Scroll(Ui.Col(22, header, _list)));
        Render();
    }

    protected override void Render()
    {
        _list.Children.Clear();
        var entries = KnownHostsFile.Read();
        if (entries.Count == 0)
        {
            _list.Children.Add(Ui.EmptyState(G.Fingerprint, L.T("Belum ada known host"), L.T("Fingerprint server otomatis tercatat di sini saat pertama kali kamu connect.")));
            return;
        }
        var q = _query.ToLowerInvariant();
        var shown = entries.Where(e => q.Length == 0 || e.Hosts.ToLowerInvariant().Contains(q) || e.KeyType.ToLowerInvariant().Contains(q)).ToList();
        for (int i = 0; i < shown.Count; i++)
        {
            var e = shown[i];
            var icon = new Border
            {
                Width = 34, Height = 34, CornerRadius = new CornerRadius(9),
                Background = Theme.Brush(Theme.Accent, 0.08), BorderBrush = Theme.Brush(Theme.Accent, 0.2),
                BorderThickness = new Thickness(1), Child = Ph.Icon("fingerprint", 17, Theme.AccentBrush)
            };
            var info = Ui.Col(3, Ui.Row(8, Ui.Text(e.Display(M.HideAddresses), 13, FontWeights.SemiBold), Ui.Badge(e.ShortType, Theme.Accent2)),
                Ui.Text(e.Fingerprint, 11, fg: Theme.Text2, mono: true).With(t => { t.IsTextSelectionEnabled = true; t.TextTrimming = TextTrimming.CharacterEllipsis; }));
            var del = Ui.IconBtn(G.Delete, L.T("Hapus dari known hosts"), async () =>
            {
                if (!await Ui.Confirm(L.T("Hapus fingerprint ini?"), L.T("Saat connect berikutnya, fingerprint server akan dicatat ulang. Hapus hanya jika kamu yakin server memang berganti kunci."), L.T("Hapus fingerprint"))) return;
                try { KnownHostsFile.Remove(e.Line); M.Flash(L.T("Fingerprint dihapus")); } catch (Exception ex) { M.Flash(L.Msg(ex.Message)); }
                Render();
            }, Theme.Brush("#E5484D"));
            UIElement? more = null;
            if (e.FirstHost() is { } hp)
            {
                var menu = new MenuFlyout();
                var all = new MenuFlyoutItem { Text = L.T("Hapus semua key untuk host ini") };
                all.Click += async (_, _) =>
                {
                    if (!await Ui.Confirm(L.T("Hapus semua key untuk {}?", hp.Host),
                            L.T("Semua key untuk {} di known_hosts akan dihapus, lalu server dipercaya lagi saat connect berikutnya. Hapus hanya jika kamu yakin server memang berganti kunci.", hp.Host),
                            L.T("Hapus semua key"))) return;
                    try
                    {
                        var removed = ZtermCoreMethods.ForgetKnownHost(hp.Host, hp.Port);
                        M.Flash(L.T("{} key dihapus", removed));
                    }
                    catch (Exception ex) { M.Flash(L.Msg(ex.Message)); }
                    Render();
                };
                menu.Items.Add(all);
                var moreBtn = Ui.IconBtn(G.More, L.T("Lainnya"), () => { });
                moreBtn.Flyout = menu;
                more = moreBtn;
            }
            var actions = Ui.Row(2, more, del);
            var card = Ui.HoverCard(Ui.Columns("Auto,*,Auto", 12, icon, info, actions), 12);
            _list.Children.Add(card);
            Ui.StaggerIn(card, i);
        }
    }
}

/// <summary>Riwayat sesi SSH: kapan, ke mana, berapa lama, dan hasilnya.</summary>
internal sealed class LogsPage : PageBase
{
    private readonly StackPanel _list = Ui.Col(18);
    private static readonly CultureInfo Id = new(L10n.English ? "en-US" : "id-ID");

    public LogsPage() : base("data", "logs", "sessions")
    {
        var clear = Ui.Secondary(L.T("Bersihkan"), G.Delete, async () =>
        {
            if (await Ui.Confirm(L.T("Hapus semua riwayat sesi?"), L.T("Riwayat di semua perangkat yang tersinkron ikut terhapus."), L.T("Hapus semua"))) M.ClearLogs();
        });
        var header = Ui.Header(L.T("Logs"), L.T("Riwayat sesi SSH di semua perangkat yang tersinkron"), clear);
        Children.Add(Ui.Scroll(Ui.Col(22, header, _list)));
        Render();
    }

    protected override void Render()
    {
        _list.Children.Clear();
        if (M.Logs.Length == 0)
        {
            _list.Children.Add(Ui.EmptyState(G.Clock, L.T("Belum ada riwayat"), L.T("Setiap sesi SSH yang kamu buka akan tercatat di sini.")));
            return;
        }
        int n = 0;
        foreach (var day in M.Logs.GroupBy(l => Ui.FromMs(l.StartedAt).LocalDateTime.Date).OrderByDescending(g => g.Key))
        {
            var title = day.Key == DateTime.Today ? L.T("Hari ini") : day.Key == DateTime.Today.AddDays(-1) ? L.T("Kemarin") : day.Key.ToString("dddd, d MMMM yyyy", Id);
            var col = Ui.Col(6, Ui.Caps(title));
            foreach (var l in day)
            {
                var row = Row(l);
                col.Children.Add(row);
                Ui.StaggerIn(row, n++);
            }
            _list.Children.Add(col);
        }
    }

    private FrameworkElement Row(SessionLog l)
    {
        var host = M.HostById(l.HostId);
        (string text, string color) status;
        if (l.EndedAt == null)
        {
            var live = M.Sessions.Any(s => s.Host.Id == l.HostId && s.State != TerminalSession.Status.Connecting);
            status = live ? (L.T("Berjalan"), Theme.Green) : (L.T("Terputus"), "#94A3B8");
        }
        else status = l.ExitCode switch
        {
            0 => (L.T("Selesai"), Theme.Accent),
            255 => (L.T("Gagal connect"), Theme.Orange),
            int c => (L.T("Keluar ({})", c), "#EAB308"),
            null => (L.T("Ditutup"), "#94A3B8"),
        };
        var start = Ui.FromMs(l.StartedAt);
        var end = l.EndedAt is { } e ? Ui.FromMs(e) : DateTimeOffset.Now;
        var secs = Math.Max(0, (end - start).TotalSeconds);
        var dur = secs >= 3600 ? L.T("{}j {}m", (int)(secs / 3600), (int)(secs % 3600 / 60)) : L.T("{}m {}d", (int)(secs / 60), (int)(secs % 60));
        var addr = l.Address;
        if (M.HideAddresses && addr.IndexOf('@') is var at and >= 0) addr = addr[..(at + 1)] + "••••••••";
        var dot = new Border { Width = 10, Height = 10, CornerRadius = new CornerRadius(5), Background = Theme.Brush(host?.Color ?? "#94A3B8") };
        var info = Ui.Col(2, Ui.Text(l.HostLabel, 13, FontWeights.SemiBold), Ui.Text(addr, 11, fg: Theme.Text2, mono: true));
        var time = Ui.Text(start.LocalDateTime.ToString(L10n.English ? "HH:mm" : "HH.mm", Id), 12, fg: Theme.Text2);
        var duration = Ui.Text(dur, 12, fg: Theme.Text2, mono: true).With(t => { t.Width = 70; t.TextAlignment = TextAlignment.Right; });
        var badge = new Border { Width = 110, Child = Ui.Badge(status.text, status.color).With(b => b.HorizontalAlignment = HorizontalAlignment.Right) };
        UIElement? again = host == null ? null : Ui.IconBtn(G.Bolt, L.T("Connect lagi"), () => M.Connect([host.Id]), Theme.AccentBrush);
        return Ui.HoverCard(Ui.Columns("Auto,*,Auto,Auto,Auto,Auto", 12, dot, info, time, duration, badge, again ?? new Border { Width = 30 }), 12);
    }
}

/// <summary>Profil akun, status sync, Windows Hello, kunci & keluar.</summary>
internal sealed class AccountPage : PageBase
{
    private readonly StackPanel _body = Ui.Col(18);

    public AccountPage() : base("data", "sync")
    {
        Children.Add(Ui.Scroll(_body));
        Render();
    }

    protected override void Render()
    {
        _body.Children.Clear();
        _body.MaxWidth = 720;
        _body.HorizontalAlignment = HorizontalAlignment.Left;

        // Profil
        var avatar = Ui.Avatar(M.ProfileName, M.AccountEmail, 64);
        var name = Ui.Col(3, Ui.Text(M.ProfileName ?? M.AccountEmail ?? L.T("Tanpa akun"), 22, FontWeights.Bold),
            Ui.Secondary(M.AccountEmail ?? L.T("Data hanya tersimpan di PC ini. Hubungkan Google untuk sync antar perangkat."), 13, true));
        _body.Children.Add(Ui.Card(Ui.Columns("Auto,*", 16, avatar, name), 20, 16));

        // Statistik
        var stats = new Grid { ColumnSpacing = 10 };
        (string label, int value, string glyph, string tint)[] items =
        [
            (L10n.English ? "Hosts" : "Host", M.Hosts.Length, G.Server, "#3B82F6"), (L10n.English ? "SSH keys" : "SSH key", M.Keys.Length, G.Key, "#F59E0B"),
            (L10n.English ? "Snippets" : "Snippet", M.Snippets.Length, G.Code, "#8B5CF6"), (L10n.English ? "Databases" : "Database", M.Databases.Length, G.Database, "#F97316"),
        ];
        for (int i = 0; i < items.Length; i++)
        {
            stats.ColumnDefinitions.Add(new ColumnDefinition());
            var it = items[i];
            var c = Ui.Card(Ui.Col(6, Ui.TintIcon(it.glyph, it.tint, 26, 12), Ui.Text(it.value.ToString(), 20, FontWeights.Bold), Ui.Secondary(it.label, 12)), 14, 12);
            Grid.SetColumn(c, i);
            stats.Children.Add(c);
        }
        _body.Children.Add(stats);

        // Sync
        var syncCol = Ui.Col(10, Ui.Text("Sync Google Drive", 15, FontWeights.SemiBold));
        if (M.AccountEmail == null)
        {
            syncCol.Children.Add(Ui.Secondary(L.T("Vault terenkripsi disimpan di folder tersembunyi Google Drive milikmu (appDataFolder). Google tidak bisa membacanya."), 12.5, true));
            syncCol.Children.Add(Ui.Primary(L.T("Hubungkan Google Drive"), G.Cloud, () => _ = Connect()).With(b => b.HorizontalAlignment = HorizontalAlignment.Left));
        }
        else
        {
            var st = Ui.Row(8, Ui.Icon(M.Sync is SyncKind.Failed or SyncKind.NeedsLogin ? G.Warning : G.Cloud, 14,
                M.Sync is SyncKind.Failed or SyncKind.NeedsLogin ? Theme.Brush(Theme.Orange) : Theme.AccentBrush), Ui.Text(M.SyncStatusText, 13));
            syncCol.Children.Add(st);
            if (M.SyncError is { } err) syncCol.Children.Add(Ui.Text(err, 12, fg: Theme.Brush(Theme.Orange), wrap: true));
            var row = Ui.Row(8);
            if (M.Sync == SyncKind.NeedsLogin) row.Children.Add(Ui.Primary(L.T("Masuk ulang Google"), G.Globe, () => _ = Connect()));
            else row.Children.Add(Ui.Secondary(L.T("Sinkronkan sekarang"), G.Sync, M.SyncNow));
            row.Children.Add(Ui.Secondary(L.T("Putuskan akun Google"), null, M.DisconnectGoogle, Theme.Brush("#E5484D")));
            syncCol.Children.Add(row);
        }
        _body.Children.Add(Ui.Card(syncCol, 18, 14));

        // Keamanan
        var hello = new ToggleSwitch { IsOn = HelloUnlock.HasStoredKey, OnContent = "", OffContent = "", MinWidth = 0, IsEnabled = false };
        _ = EnableHelloToggle(hello);
        hello.Toggled += (_, _) => { if (hello.IsOn != HelloUnlock.HasStoredKey) M.EnableHello(hello.IsOn); };
        var helloRow = Ui.Columns("Auto,*,Auto", 12, Ui.Icon(G.Hello, 18, Theme.AccentBrush),
            Ui.Col(1, Ui.Text(L.T("Buka dengan Windows Hello"), 13, FontWeights.Medium), Ui.Secondary(L.T("Kunci vault disimpan di Credential Manager PC ini"), 11.5)), hello);
        var lockBtn = Ui.Secondary(L.T("Kunci vault sekarang  (Ctrl+Shift+L)"), G.Lock, M.Lock).With(b => b.HorizontalAlignment = HorizontalAlignment.Left);
        _body.Children.Add(Ui.Card(Ui.Col(12, Ui.Text(L.T("Keamanan"), 15, FontWeights.SemiBold), helloRow, lockBtn), 18, 14));

        // Bahasa
        var langBox = new ComboBox { MinWidth = 200 };
        foreach (var ch in L10n.Choices) langBox.Items.Add(L10n.Title(ch));
        langBox.SelectedIndex = Array.IndexOf(L10n.Choices, L10n.Choice);
        langBox.SelectionChanged += (_, _) => { if (langBox.SelectedIndex >= 0) _ = ShellPage.SetLanguage(L10n.Choices[langBox.SelectedIndex]); };
        var langRow = Ui.Columns("Auto,*,Auto", 12, Ui.Icon(G.Globe, 18, Theme.AccentBrush),
            Ui.Col(1, Ui.Text("Bahasa / Language", 13, FontWeights.Medium), Ui.Secondary(L.T("Berlaku setelah Zterm dibuka ulang"), 11.5)), langBox);
        _body.Children.Add(Ui.Card(langRow, 18, 14));

        // Keluar
        var outCol = Ui.Col(10, Ui.Text(L.T("Keluar"), 15, FontWeights.SemiBold),
            Ui.Secondary(L.T("Keluar memutus login Google dan mengunci vault. Pilih hapus jika PC ini bukan milikmu."), 12.5, true),
            Ui.Row(8,
                Ui.Secondary(L.T("Keluar"), G.SignOut, async () => { if (await Ui.Confirm(L.T("Keluar dari akun?"), L.T("Vault dikunci dan login Google diputus. Data tetap terenkripsi di PC ini."), L.T("Keluar"), false)) M.SignOut(false); }),
                Ui.Secondary(L.T("Keluar & hapus data dari PC ini"), G.Delete, async () =>
                {
                    if (await Ui.Confirm(L.T("Hapus semua data dari PC ini?"), L.T("Vault lokal dan kunci Windows Hello dihapus. Salinan di Google Drive tidak dihapus, jadi bisa dipulihkan dengan login lagi."), L.T("Hapus & keluar")))
                        M.SignOut(true);
                }, Theme.Brush("#E5484D"))));
        _body.Children.Add(Ui.Card(outCol, 18, 14));
        Ui.StaggerIn(_body, 0);
    }

    private static async Task EnableHelloToggle(ToggleSwitch t) => t.IsEnabled = await HelloUnlock.IsAvailable() || HelloUnlock.HasStoredKey;

    private async Task Connect()
    {
        try { await M.SignInGoogle(); }
        catch (AuthCancelledException) { }
        catch (Exception e) { M.Flash(Errors.Text(e)); }
    }
}

/// <summary>Tentang Zterm.</summary>
internal sealed class AboutPage : PageBase
{
    public AboutPage() : base()
    {
        Render();
    }

    protected override void Render()
    {
        Children.Clear();
        var logo = new Image { Source = new BitmapImage(new Uri("ms-appx:///Assets/logo.png")), Width = 96, Height = 96 };
        var title = Ui.Text("Zterm", 34, FontWeights.ExtraBold).With(t => t.HorizontalAlignment = HorizontalAlignment.Center);
        var tagline = Ui.Text(L.T("Semua servermu, satu terminal."), 14, fg: Theme.Text2, mono: true).With(t => t.HorizontalAlignment = HorizontalAlignment.Center);
        var badges = Ui.Row(8, Ui.Badge(L.T("VERSI {}", Config.Version)), Ui.Badge($"CORE {uniffi.zterm_core.ZtermCoreMethods.CoreVersion()}", Theme.Accent2), Ui.Badge("MIT", Theme.Accent3));
        badges.HorizontalAlignment = HorizontalAlignment.Center;
        var desc = Ui.Secondary(L.T("SSH client native untuk Windows & macOS — gratis, tanpa iklan, tanpa server. Host, SSH key, dan snippet dienkripsi di perangkatmu dan tersinkron lewat Google Drive milikmu sendiri."), 13.5, true)
            .With(t => { t.TextAlignment = TextAlignment.Center; t.MaxWidth = 540; t.HorizontalAlignment = HorizontalAlignment.Center; });
        var links = Ui.Row(10,
            Ui.Secondary("Website", G.Globe, () => Ui.Open(Config.Website)),
            Ui.Secondary("GitHub", G.Code, () => Ui.Open(Config.GitHub)),
            Ui.Secondary(L.T("Catatan rilis"), G.Sparkle, () => Ui.Open(Config.Releases)),
            Ui.Secondary(L.T("Laporkan bug"), G.Bug, () => Ui.Open(Config.Issues)));
        links.HorizontalAlignment = HorizontalAlignment.Center;

        var update = new UpdatePanel { HorizontalAlignment = HorizontalAlignment.Center };

        var info = Ui.Col(0,
            InfoRow(L.T("Dibuat oleh"), "Latief Ahmad"), InfoRow(L.T("Antarmuka"), L.T("WinUI 3 (native Windows)")),
            InfoRow(L.T("Inti"), L.T("zterm-core · Rust (vault, sync, keychain)")), InfoRow(L.T("Enkripsi"), "Argon2id + XChaCha20-Poly1305"),
            InfoRow("Terminal", "xterm.js · ConPTY · OpenSSH"), InfoRow("Sync", "Google Drive (appDataFolder), zero-knowledge", true));
        var infoCard = Ui.Card(info, 4).With(c => { c.MaxWidth = 560; c.HorizontalAlignment = HorizontalAlignment.Center; });
        var legal = Ui.Row(14,
            Ui.Plain(Ui.Text(L.T("Kebijakan Privasi"), 12, fg: Theme.AccentBrush), () => Ui.Open(Config.Privacy)),
            Ui.Plain(Ui.Text(L.T("Syarat Layanan"), 12, fg: Theme.AccentBrush), () => Ui.Open(Config.Terms)));
        legal.HorizontalAlignment = HorizontalAlignment.Center;
        var copy = Ui.Text(L.T("© 2026 Latief Ahmad · Lisensi MIT"), 11, fg: Theme.Text3).With(t => t.HorizontalAlignment = HorizontalAlignment.Center);

        var col = Ui.Col(18, logo, title, tagline, badges, desc, links, update, infoCard, legal, copy);
        col.Padding = new Thickness(0, 24, 0, 24);
        for (int i = 0; i < col.Children.Count; i++) Ui.StaggerIn(col.Children[i], i);
        Children.Add(Ui.Scroll(col));
    }

    private static UIElement InfoRow(string label, string value, bool last = false) => new Border
    {
        Padding = new Thickness(14, 11, 14, 11), BorderBrush = Theme.Ink(0.06), BorderThickness = new Thickness(0, 0, 0, last ? 0 : 1),
        Child = Ui.Columns("140,*", 10, Ui.Text(label, 13, fg: Theme.Text2), Ui.Text(value, 13, FontWeights.Medium))
    };
}

/// <summary>Status pembaruan di halaman Tentang; diperbarui sendiri agar progress tidak menggambar ulang seluruh halaman.</summary>
internal sealed class UpdatePanel : Grid
{
    private readonly AppModel M = App.Model;
    private readonly Action<string> _onChange;
    private bool _subscribed;
    private UpdateBar? _bar;
    private TextBlock? _status;

    public UpdatePanel()
    {
        _onChange = OnChange;
        Subscribe();
        Unloaded += (_, _) => Unsubscribe();
        Loaded += (_, _) => { Subscribe(); Render(); };
        Render();
    }

    private void Subscribe()
    {
        if (_subscribed) return;
        M.Changed += _onChange;
        _subscribed = true;
    }

    private void Unsubscribe()
    {
        if (!_subscribed) return;
        M.Changed -= _onChange;
        _subscribed = false;
    }

    private void OnChange(string what)
    {
        if (what == "update") Render();
        else if (what == "update-progress")
        {
            _bar?.SetTarget(M.UpdateProgress);
            if (_status != null) _status.Text = M.UpdateStatus ?? L.T("Mengunduh pembaruan…");
        }
    }

    private void Render()
    {
        Children.Clear();
        _bar = null;
        _status = null;
        if (M.Update is not { } u)
        {
            var latest = Ui.Row(10,
                Ui.Icon(G.Check, 14, Theme.AccentBrush),
                Ui.Text(L.T("Kamu memakai versi terbaru yang diketahui"), 13),
                Ui.Secondary(L.T("Periksa"), null, () => _ = M.CheckForUpdates(true)));
            latest.HorizontalAlignment = HorizontalAlignment.Center;
            Children.Add(latest);
            return;
        }

        var content = Ui.Col(8,
            Ui.Row(10, Ui.Icon(G.Sparkle, 14, Theme.AccentBrush), Ui.Text(L.T("Versi {} tersedia", u.Version), 13, FontWeights.SemiBold)));
        if (M.UpdateBusy)
        {
            _bar = new UpdateBar(M.UpdateProgress);
            _status = Ui.Secondary(M.UpdateStatus ?? L.T("Mengunduh pembaruan…"), 12, true);
            content.Children.Add(_bar);
            content.Children.Add(_status);
        }
        else if (M.UpdateError is { Length: > 0 } error)
        {
            content.Children.Add(Ui.Secondary(error, 12, true));
            content.Children.Add(Ui.Row(8,
                Ui.Primary(L.T("Unduh manual"), G.Download, () => Ui.Open(u.Page)),
                Ui.Secondary(L.T("Coba lagi"), null, () => _ = UpdateUI.StartAsync(M, u)),
                Ui.Secondary(L.T("Catatan rilis"), null, () => Ui.Open(u.Page))));
        }
        else
        {
            content.Children.Add(Ui.Row(8,
                Ui.Primary(L.T("Update sekarang"), G.Download, () => _ = UpdateUI.StartAsync(M, u)),
                Ui.Secondary(L.T("Catatan rilis"), null, () => Ui.Open(u.Page))));
        }

        var card = Ui.Card(content, 14).With(c =>
        {
            c.MaxWidth = 560;
            c.HorizontalAlignment = HorizontalAlignment.Center;
            c.Background = Theme.Brush(Theme.Accent, 0.06);
            c.BorderBrush = Theme.Brush(Theme.Accent, 0.3);
        });
        Children.Add(card);
    }
}
