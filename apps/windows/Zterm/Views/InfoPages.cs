using System;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Foundation;
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

/// <summary>Tentang Zterm — hero berbingkai terminal, dua panel ringkas, footer tetap.</summary>
internal sealed class AboutPage : PageBase
{
    public AboutPage() : base()
    {
        Render();
    }

    protected override void Render()
    {
        Children.Clear();

        // Latar: grid titik + sorotan mint di kiri atas (sama dengan versi macOS).
        var bg = new Grid { Background = Glow(Theme.Accent, Theme.Dark ? 0.12 : 0.15, new Point(0.18, 0.0)) };
        bg.Children.Add(new Grid { Background = Glow(Theme.Accent2, Theme.Dark ? 0.06 : 0.08, new Point(0.95, 0.08)) });
        bg.Children.Add(new DotField());
        Children.Add(bg);

        var panels = Ui.Columns("*,*", 14, ExplorePanel(), InfoPanel());

        var legal = Ui.Row(16,
            Ui.Plain(Ui.Text(L.T("Kebijakan Privasi"), 11.5, fg: Theme.AccentBrush), () => Ui.Open(Config.Privacy)),
            Ui.Plain(Ui.Text(L.T("Syarat Layanan"), 11.5, fg: Theme.AccentBrush), () => Ui.Open(Config.Terms)));
        var copy = Ui.Text(L.T("© 2026 Latief Ahmad · Lisensi MIT"), 11, fg: Theme.Text3);
        var footerLeft = Ui.Col(3, legal, copy);

        // Tombol donasi di kanan footer, sejajar dengan tautan legal.
        var support = Ui.Primary("Support me", G.Heart, () => Ui.Open(Config.Donate), large: true);
        support.HorizontalAlignment = HorizontalAlignment.Right;
        support.VerticalAlignment = VerticalAlignment.Center;
        ToolTipService.SetToolTip(support, "saweria.co/latiefahmad");

        var footerGrid = new Grid { ColumnSpacing = 18 };
        footerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footerGrid.Children.Add(footerLeft);
        Grid.SetColumn(support, 1);
        footerGrid.Children.Add(support);
        var footer = new Border
        {
            Child = footerGrid, BorderBrush = Theme.Ink(0.06), BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(0, 10, 0, 0)
        };

        var body = Ui.Col(14, Hero(), panels, footer);
        body.Width = 840;
        body.HorizontalAlignment = HorizontalAlignment.Center;
        for (int i = 0; i < body.Children.Count; i++) Ui.StaggerIn(body.Children[i], i);

        // Konten diskalakan turun bila jendela pendek, jadi halaman ini selalu utuh
        // dalam satu layar tanpa ScrollViewer.
        var fit = new Viewbox
        {
            Child = body,
            Stretch = Stretch.Uniform,
            StretchDirection = StretchDirection.DownOnly,
            Margin = new Thickness(28, 10, 28, 8),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch,
        };
        Children.Add(fit);
    }

    private static RadialGradientBrush Glow(string hex, double opacity, Point center) => new()
    {
        Center = center, RadiusX = 0.95, RadiusY = 0.9,
        GradientStops =
        {
            new GradientStop { Color = Theme.Hex(hex, (byte)Math.Round(255 * opacity)), Offset = 0 },
            new GradientStop { Color = Colors.Transparent, Offset = 1 },
        }
    };

    private static FrameworkElement Hero()
    {
        var dots = Ui.Row(6, TrafficDot("#FF5F57"), TrafficDot("#FEBC2E"), TrafficDot("#28C840"));
        var chromeLabel = Ui.Text("ZTERM — ABOUT", 8.5, mono: true, fg: Theme.Text3).With(t => t.CharacterSpacing = 110);
        var chromeRight = new StackPanel
        {
            Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center, Children = { chromeLabel }
        };
        var chrome = new Grid { Height = 31, Padding = new Thickness(12, 0, 12, 0) };
        chrome.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        chrome.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        chrome.Children.Add(dots);
        Grid.SetColumn(chromeRight, 1);
        chrome.Children.Add(chromeRight);
        var chromeBorder = new Border
        {
            Child = chrome, Background = Theme.Ink(0.02), BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(0, 0, 0, 1), CornerRadius = new CornerRadius(12, 12, 0, 0)
        };

        var logo = new Image
        {
            Source = new BitmapImage(new Uri("ms-appx:///Assets/logo.png")),
            Width = 68, Height = 68, VerticalAlignment = VerticalAlignment.Center
        };

        var cursor = new Border
        {
            Width = 7, Height = 14, CornerRadius = new CornerRadius(1), Background = Theme.AccentBrush,
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(1, 1, 0, 0)
        };
        Ui.Pulse(cursor);
        var tagline = Ui.Row(6,
            Ui.Text(">", 14, mono: true, fg: Theme.AccentBrush),
            Ui.Text(L.T("Semua servermu, satu terminal."), 13.5, mono: true, fg: Theme.Text2),
            cursor);

        var badges = Ui.Row(7,
            Ui.Badge($"v{Config.Version}"),
            Ui.Badge($"CORE {uniffi.zterm_core.ZtermCoreMethods.CoreVersion()}", Theme.Accent2),
            Ui.Badge("MIT", Theme.Accent3),
            Ui.Caps("WINUI 3 · XTERM.JS · CONPTY").With(t => { t.FontSize = 8.5; t.CharacterSpacing = 90; }));

        var copy = Ui.Col(4,
            Ui.Caps(L.T("Tentang Zterm")).With(t => { t.FontSize = 9; t.CharacterSpacing = 140; }),
            Ui.Text("Zterm", 34, FontWeights.ExtraBold),
            tagline,
            badges);

        var side = Ui.Col(7, new UpdatePanel(),
            Ui.Text(L.T("Gratis · tanpa iklan · local-first"), 9.5, fg: Theme.Text3).With(t => t.HorizontalAlignment = HorizontalAlignment.Right));
        side.Width = 252;
        side.VerticalAlignment = VerticalAlignment.Center;

        var main = Ui.Columns("Auto,*,Auto", 16, logo, copy, side);
        main.Margin = new Thickness(18, 14, 18, 16);

        var watermark = Ui.Text(">_", 112, FontWeights.ExtraBold, Theme.Brush(Theme.Accent, 0.07), mono: true)
            .With(t =>
            {
                t.HorizontalAlignment = HorizontalAlignment.Right;
                t.VerticalAlignment = VerticalAlignment.Bottom;
                t.Margin = new Thickness(0, 0, 14, 0);
                t.IsHitTestVisible = false;
            });

        var inner = new Grid();
        inner.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        inner.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(watermark, 1);
        inner.Children.Add(watermark);
        inner.Children.Add(chromeBorder);
        Grid.SetRow(main, 1);
        inner.Children.Add(main);

        return new Border
        {
            Child = inner, Background = Theme.Card, BorderBrush = Theme.CardStroke, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12)
        };
    }

    private static Border TrafficDot(string hex) => new()
    {
        Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Background = Theme.Brush(hex)
    };

    private static FrameworkElement PanelHead(string title, string hint)
    {
        var h = Ui.Caps(hint).With(t => { t.FontSize = 9; t.CharacterSpacing = 90; t.HorizontalAlignment = HorizontalAlignment.Right; });
        return Ui.Columns("*,Auto", 8, Ui.Text(title, 13, FontWeights.SemiBold), h);
    }

    private static FrameworkElement ExplorePanel()
    {
        var grid = new Grid { ColumnSpacing = 8, RowSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        (string icon, string color, string title, string sub, string url)[] items =
        [
            ("globe", Theme.Accent, "Website", "latief.id/zterm", Config.Website),
            ("file-code", Theme.Accent2, "GitHub", "latiefahmad/zterm", Config.GitHub),
            ("sparkle", Theme.Accent3, L.T("Catatan rilis"), L.T("Yang baru"), Config.Releases),
            ("bug", "#F2A65A", L.T("Laporkan bug"), "github issues", Config.Issues),
        ];
        for (int i = 0; i < items.Length; i++)
        {
            var it = items[i];
            var tile = Tile(it.icon, it.color, it.title, it.sub, it.url);
            Grid.SetColumn(tile, i % 2);
            Grid.SetRow(tile, i / 2);
            grid.Children.Add(tile);
        }
        return Ui.Card(Ui.Col(10, PanelHead(L.T("Jelajahi"), L.T("Buka di browser")), grid), 14);
    }

    private static Button Tile(string icon, string color, string title, string sub, string url)
    {
        var iconBox = new Border
        {
            Width = 30, Height = 30, CornerRadius = new CornerRadius(8), Background = Theme.Brush(color, 0.12),
            Child = Ph.Icon(icon, 14, Theme.Brush(color))
        };
        var text = Ui.Col(1, Ui.Text(title, 12.5, FontWeights.SemiBold), Ui.Text(sub, 10.5, fg: Theme.Text3));
        var b = new Button
        {
            Content = Ui.Columns("Auto,*", 9, iconBox, text),
            Background = Theme.Ink(0.03), BorderBrush = Theme.CardStroke, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(9), Padding = new Thickness(9, 8, 9, 8),
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            MinWidth = 0, MinHeight = 0
        };
        b.Resources["ButtonBackgroundPointerOver"] = Theme.Ink(0.065);
        b.Resources["ButtonBackgroundPressed"] = Theme.Ink(0.1);
        ToolTipService.SetToolTip(b, url);
        b.Click += (_, _) => Ui.Open(url);
        return b;
    }

    private static FrameworkElement InfoPanel()
    {
        var list = Ui.Col(0,
            InfoRow("user", L.T("Dibuat oleh"), "Latief Ahmad"),
            InfoRow("cube", L.T("Inti"), "zterm-core · Rust"),
            InfoRow("shield-check", L.T("Keamanan"), "Argon2id + XChaCha20"),
            InfoRow("cloud", "Sync", "Google Drive · zero-knowledge", true));
        return Ui.Card(Ui.Col(10, PanelHead(L.T("Di balik layar"), "native · rust"), list), 14);
    }

    private static UIElement InfoRow(string icon, string label, string value, bool last = false)
    {
        var iconBox = new Border
        {
            Width = 26, Height = 26, CornerRadius = new CornerRadius(7), Background = Theme.Ink(0.04),
            Child = Ph.Icon(icon, 13, Theme.Text2)
        };
        var labelText = Ui.Text(label, 12, fg: Theme.Text2).With(t => t.Width = 74);
        var valueText = Ui.Text(value, 12, FontWeights.Medium).With(t => t.TextAlignment = TextAlignment.Right);
        return new Border
        {
            Padding = new Thickness(0, 8, 0, 8), BorderBrush = Theme.Ink(0.06),
            BorderThickness = new Thickness(0, 0, 0, last ? 0 : 1),
            Child = Ui.Columns("Auto,Auto,*,Auto", 9, iconBox, labelText, null, valueText)
        };
    }
}

/// <summary>Grid titik mint yang memudar, digambar sebagai satu Path agar ringan.</summary>
internal sealed class DotField : Canvas
{
    private readonly Microsoft.UI.Xaml.Shapes.Path _path = new() { IsHitTestVisible = false };

    public DotField()
    {
        IsHitTestVisible = false;
        _path.Fill = Theme.Brush(Theme.Accent, Theme.Dark ? 0.09 : 0.13);
        Children.Add(_path);
        SizeChanged += (_, e) => Build(e.NewSize.Width, e.NewSize.Height);
    }

    private void Build(double width, double height)
    {
        if (width <= 0 || height <= 0) return;
        var group = new GeometryGroup();
        const double gap = 24;
        const double radius = 1;
        for (double y = gap / 2; y < height; y += gap)
        {
            for (double x = gap / 2; x < width; x += gap)
            {
                group.Children.Add(new EllipseGeometry { Center = new Point(x, y), RadiusX = radius, RadiusY = radius });
            }
        }
        _path.Data = group;
    }
}

/// <summary>Status pembaruan ringkas di sisi hero; diperbarui sendiri agar progress tidak menggambar ulang seluruh halaman.</summary>
internal sealed class UpdatePanel : Grid
{
    private readonly AppModel M = App.Model;
    private readonly Action<string> _onChange;
    private bool _subscribed;
    private UpdateBar? _bar;
    private TextBlock? _status;

    public UpdatePanel()
    {
        Width = 252;
        HorizontalAlignment = HorizontalAlignment.Right;
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

        var u = M.Update;
        var busy = M.UpdateBusy;
        var error = M.UpdateError is { Length: > 0 } e ? e : null;
        var ledColor = busy || u == null ? Theme.Accent : error != null ? Theme.Red : Theme.Orange;

        var led = new Border
        {
            Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Background = Theme.Brush(ledColor),
            VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 3, 0, 0)
        };
        if (busy) Ui.Pulse(led);

        var label = Ui.Caps("Update").With(t => { t.FontSize = 8; t.CharacterSpacing = 110; });
        var title = busy ? L.T("Mengunduh pembaruan…")
            : u == null ? L.T("Kamu memakai versi terbaru")
            : L.T("Versi {} tersedia", u.Version);
        var text = Ui.Col(1, label, Ui.Text(title, 11.5, FontWeights.Medium, wrap: true));

        Button? action = null;
        if (!busy)
        {
            action = u == null
                ? MiniButton(L.T("Periksa"), null, () => _ = M.CheckForUpdates(true))
                : error == null
                    ? MiniButton(L.T("Update"), G.Download, () => _ = UpdateUI.StartAsync(M, u), true)
                    : MiniButton(L.T("Coba lagi"), G.Refresh, () => _ = UpdateUI.StartAsync(M, u));
        }

        var content = Ui.Col(6, Ui.Columns("Auto,*,Auto", 8, led, text, action));
        if (busy)
        {
            _bar = new UpdateBar(M.UpdateProgress) { Height = 4 };
            _status = Ui.Secondary(M.UpdateStatus ?? L.T("Mengunduh pembaruan…"), 10.5, true);
            content.Children.Add(_bar);
            content.Children.Add(_status);
        }
        else if (u != null && error != null)
        {
            content.Children.Add(Ui.Text(error, 10.5, fg: Theme.Brush(Theme.Orange), wrap: true));
            content.Children.Add(Ui.Row(6,
                MiniButton(L.T("Unduh manual"), G.Download, () => Ui.Open(u.Page)),
                MiniButton(L.T("Catatan rilis"), null, () => Ui.Open(u.Page))));
        }
        else if (u != null)
        {
            content.Children.Add(Ui.Row(6, MiniButton(L.T("Catatan rilis"), null, () => Ui.Open(u.Page))));
        }

        Children.Add(new Border
        {
            Child = content, Background = Theme.Field, BorderBrush = u == null ? Theme.CardStroke : Theme.Brush(ledColor, 0.35),
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(10, 8, 10, 8)
        });
    }

    private static Button MiniButton(string text, string? glyph, Action click, bool primary = false)
    {
        var fg = primary ? new SolidColorBrush(Theme.Hex("#06231E")) : Theme.Text;
        UIElement content = glyph == null
            ? Ui.Text(text, 11, FontWeights.SemiBold, fg)
            : Ui.Row(4, Ui.Icon(glyph, 11, fg), Ui.Text(text, 11, FontWeights.SemiBold, fg));
        var b = new Button
        {
            Content = content, Background = primary ? Theme.AccentBrush : Theme.Ink(0.05), Foreground = fg,
            BorderBrush = Theme.CardStroke, BorderThickness = primary ? new Thickness(0) : new Thickness(1),
            CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 3, 8, 4), MinWidth = 0, MinHeight = 0
        };
        b.Resources["ButtonBackgroundPointerOver"] = primary ? Theme.Brush(Theme.Accent, 0.88) : Theme.Ink(0.09);
        b.Resources["ButtonBackgroundPressed"] = primary ? Theme.Brush(Theme.Accent, 0.76) : Theme.Ink(0.13);
        b.Resources["ButtonForegroundPointerOver"] = fg;
        b.Resources["ButtonForegroundPressed"] = fg;
        b.Click += (_, _) => click();
        return b;
    }
}
