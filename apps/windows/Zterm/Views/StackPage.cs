using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using uniffi.zterm_core;

namespace Zterm.Views;

/// <summary>Server Lokal: web server & database di PC ini — padanan LocalServerView.swift.</summary>
internal sealed class StackPage : PageBase
{
    private sealed record DbKind(string Id, string Name, string Color, string Glyph, DbEngine Engine, string User, string Note);

    private static readonly DbKind[] Dbs =
    [
        new("mysql", "MySQL", "#00758F", G.Database, DbEngine.Mysql, "root", "User root, tanpa password"),
        new("postgres", "PostgreSQL", "#336791", G.Database, DbEngine.Postgres, "postgres", "User postgres, tanpa password"),
        new("mongodb", "MongoDB", "#13AA52", G.Database, DbEngine.Mongodb, "", "Tanpa autentikasi"),
    ];

    private readonly StackPanel _body = Ui.Col(20);
    private readonly StackPanel _actions;
    private StackModel S => M.Stack;

    public StackPage() : base("stack")
    {
        var header = Ui.Header(L.T("Server Lokal"), L.T("Web server & database di PC ini — seperti MAMP / XAMPP, tanpa install manual"));
        _actions = (StackPanel)header.Children[1];
        Children.Add(Ui.Scroll(Ui.Col(22, header, _body)));
        Loaded += (s, e) => { S.Refresh(); S.StartPolling(); Render(); };
        Unloaded += (s, e) => S.StopPolling();
        Render();
    }

    protected override void Render()
    {
        _actions.Children.Clear();
        _actions.Children.Add(Ui.IconBtn(G.Folder, L.T("Buka folder data & log"), () => Ui.Open(S.RootPath)));
        if (S.AnyRunning) _actions.Children.Add(Ui.Secondary(L.T("Stop semua"), G.Stop, () => _ = S.StopAll()));
        else
        {
            var all = Ui.Primary(L.T("Start semua"), G.Play, () => _ = S.StartAll());
            all.IsEnabled = S.Services.Any(x => x.Missing.Length == 0);
            _actions.Children.Add(all);
        }

        _body.Children.Clear();
        if (S.Error is { } err)
            _body.Children.Add(Banner(err, Theme.Red, () => { S.Error = null; Render(); }));
        if (S.NeedsVcRuntime)
        {
            var install = Ui.Primary(L.T("Pasang"), G.Download, () => _ = S.InstallVcRuntime());
            _body.Children.Add(Ui.Card(Ui.Columns("Auto,*,Auto", 12, Ui.Icon(G.Warning, 16, Theme.Brush(Theme.Orange)),
                Ui.Col(2, Ui.Text(L.T("Butuh Microsoft Visual C++ Runtime"), 13, FontWeights.SemiBold),
                    Ui.Secondary(L.T("Apache, PHP, dan MySQL memerlukannya. Pasang sekali (±25 MB, perlu izin admin)."), 12, wrap: true)), install), 14));
        }
        _body.Children.Add(WebCard());
        _body.Children.Add(Ui.Caps("Database"));
        var grid = Ui.Columns("*,*,*", 14, Dbs.Select(DbCard).ToArray());
        _body.Children.Add(grid);
    }

    private static Border Banner(string text, string hex, Action dismiss)
    {
        var b = new Border
        {
            Background = Theme.Brush(hex, 0.12), CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 10, 12, 10),
            Child = Ui.Columns("Auto,*,Auto", 8, Ui.Icon(G.Warning, 14, Theme.Brush(hex)), Ui.Text(text, 13, fg: Theme.Brush(hex), wrap: true),
                Ui.IconBtn(G.Close, L.T("Tutup"), dismiss, size: 11))
        };
        return b;
    }

    private static UIElement Dot(bool running) => Ui.Row(6,
        new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(4), Background = running ? Theme.Brush(Theme.Green) : Theme.Ink(0.3), VerticalAlignment = VerticalAlignment.Center },
        Ui.Text(running ? L.T("Berjalan") : L.T("Berhenti"), 11.5, FontWeights.Medium, running ? Theme.Brush(Theme.Green) : Theme.Text2));

    private Button Power(string service, bool running, bool enabled)
    {
        var busy = S.Busy.Contains(service);
        var text = busy ? (running ? L.T("Menghentikan…") : L.T("Menyalakan…")) : running ? "Stop" : "Start";
        var b = running ? Ui.Secondary(text, G.Stop, () => _ = S.Toggle(service)) : Ui.Primary(text, G.Play, () => _ = S.Toggle(service));
        b.MinWidth = 104;
        b.IsEnabled = enabled && !busy;
        return b;
    }

    /// <summary>Komponen yang perlu diunduh: tombol unduh / progress / batal.</summary>
    private UIElement ComponentRow(string id)
    {
        if (S.Component(id) is not { } c) return new Border();
        var installed = c.State != StackState.NotInstalled && c.State != StackState.Installing;
        UIElement info;
        UIElement? action = null;
        if (S.Downloads.TryGetValue(id, out var d))
        {
            info = Ui.Col(3, Ui.Text($"{c.Name} {c.Version}", 12.5, FontWeights.Medium),
                new ProgressBar { Value = d.Fraction * 100, Maximum = 100, MaxWidth = 260, HorizontalAlignment = HorizontalAlignment.Left },
                Ui.Text(d.Label, 10.5, fg: Theme.Text2));
            action = Ui.Secondary(L.T("Batal"), null, () => S.CancelInstall(id));
        }
        else
        {
            info = Ui.Col(2, Ui.Text($"{c.Name} {c.Version}", 12.5, FontWeights.Medium),
                Ui.Text(c.System ? L.T("Bawaan sistem") : installed ? L.T("Terpasang") : L.T("Belum diunduh · ±{} MB", c.SizeMb), 11, fg: Theme.Text2));
            if (!installed && !c.System)
            {
                var dl = Ui.Secondary(L.T("Unduh"), G.Download, () => S.Install(id));
                dl.IsEnabled = c.Available;
                action = dl;
            }
        }
        return new Border
        {
            CornerRadius = new CornerRadius(10), Background = Theme.Ink(0.045), Padding = new Thickness(12, 9, 12, 9),
            Child = Ui.Columns("Auto,*,Auto", 10, Ui.Icon(installed ? G.Check : G.Download, 14, installed ? Theme.Brush(Theme.Green) : Theme.Text2), info, action)
        };
    }

    private Border Card(UIElement content, bool running) => new()
    {
        Child = content, Padding = new Thickness(18), CornerRadius = new CornerRadius(16), Background = Theme.Card,
        BorderThickness = new Thickness(1), BorderBrush = running ? Theme.Brush(Theme.Green, 0.45) : Theme.CardStroke,
    };

    private NumberBox PortBox(ushort value, bool running, Action<ushort> set)
    {
        var n = Ui.Number(value, 1, 65535, 100);
        n.IsEnabled = !running;
        n.ValueChanged += (s, e) => { if (!double.IsNaN(e.NewValue) && (ushort)e.NewValue != value) set((ushort)e.NewValue); };
        return n;
    }

    // MARK: Web

    private UIElement WebCard()
    {
        var svc = S.Service("web");
        var running = svc?.Running == true;
        var st = S.Settings;
        var serverName = st.WebServer == "nginx" ? "Nginx" : "Apache";

        var icon = new Border
        {
            Width = 48, Height = 48, CornerRadius = new CornerRadius(13), Background = Theme.BrandGradient,
            Child = new FontIcon { Glyph = G.Globe, FontSize = 22, Foreground = Theme.Brush("#000000", 0.72) }
        };
        var title = Ui.Col(3, Ui.Row(10, Ui.Text("Web server", 18, FontWeights.Bold), Dot(running)),
            Ui.Text(running ? L.T("{} + PHP di localhost:{}", serverName, st.WebPort) : L.T("Apache atau Nginx dengan PHP — untuk Laravel, WordPress, dan proyek PHP lain"), 12, fg: Theme.Text2));
        var more = new MenuFlyout();
        void Item(string t, Action a) { var i = new MenuFlyoutItem { Text = L.T(t) }; i.Click += (s, e) => a(); more.Items.Add(i); }
        Item("Lihat log", () => _ = ShowLog("web"));
        Item("Buka folder proyek", () => { System.IO.Directory.CreateDirectory(st.DocRoot); Ui.Open(st.DocRoot); });
        var moreBtn = Ui.IconBtn(G.More, L.T("Lainnya"), () => { });
        moreBtn.Flyout = more;
        var head = Ui.Columns("Auto,*,Auto,Auto,Auto", 12, icon, title,
            running ? Ui.Secondary(L.T("Buka di browser"), G.Globe, () => Ui.Open(S.WebUrl)) : null,
            moreBtn, Power("web", running, svc?.Missing.Length == 0));

        var seg = Ui.Segmented(["Apache", "Nginx"], st.WebServer == "nginx" ? 1 : 0, i => S.SaveSettings(S.Settings with { WebServer = i == 1 ? "nginx" : "apache" }));
        seg.IsHitTestVisible = !running;
        seg.Opacity = running ? 0.5 : 1;
        var root = Ui.Text(st.DocRoot, 12, mono: true).With(t => t.TextTrimming = TextTrimming.CharacterEllipsis);
        var rootBox = new Border { Background = Theme.Field, CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 6, 10, 6), MaxWidth = 300, Child = root };
        var pick = Ui.Secondary(L.T("Pilih…"), null, () => _ = PickRoot());
        pick.IsEnabled = !running;

        UIElement Field(string label, UIElement content) => Ui.Columns("110,*", 12,
            Ui.Text(L.T(label), 12.5, fg: Theme.Text2).With(t => { t.HorizontalAlignment = HorizontalAlignment.Right; t.VerticalAlignment = VerticalAlignment.Center; }), content);
        var left = Ui.Col(12,
            Field("Web server", seg.With(g => { g.Width = 200; g.HorizontalAlignment = HorizontalAlignment.Left; })),
            Field("Port", PortBox(st.WebPort, running, p => S.SaveSettings(S.Settings with { WebPort = p })).With(n => n.HorizontalAlignment = HorizontalAlignment.Left)),
            Field("Folder proyek", Ui.Row(8, rootBox, pick)));
        var right = Ui.Col(8, Ui.Caps(L.T("Komponen")), ComponentRow(st.WebServer), ComponentRow("php"));
        var body = Ui.Col(16, head, Ui.Columns("*,*", 18, left, right));
        if (svc?.Error is { } e && !running) body.Children.Add(Ui.Text("⚠ " + e, 11.5, fg: Theme.Brush(Theme.Orange), wrap: true));
        return Card(body, running);
    }

    private async Task PickRoot()
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Window));
        if (await picker.PickSingleFolderAsync() is { } f) S.SaveSettings(S.Settings with { DocRoot = f.Path });
    }

    // MARK: Database

    private UIElement DbCard(DbKind k)
    {
        var svc = S.Service(k.Id);
        var c = S.Component(k.Id);
        var running = svc?.Running == true;
        var installed = c != null && c.State != StackState.NotInstalled && c.State != StackState.Installing;
        var more = new MenuFlyout();
        var log = new MenuFlyoutItem { Text = L.T("Lihat log") };
        log.Click += (s, e) => _ = ShowLog(k.Id);
        more.Items.Add(log);
        if (installed)
        {
            more.Items.Add(new MenuFlyoutSeparator());
            var rm = new MenuFlyoutItem { Text = L.T("Hapus program…"), Foreground = Theme.Brush("#E5484D"), IsEnabled = !running };
            rm.Click += async (s, e) =>
            {
                if (await Ui.Confirm(L.T("Hapus program {}?", k.Name), L.T("Program dihapus dari PC ini. Data database tetap disimpan dan dipakai lagi saat diunduh ulang."), L.T("Hapus program")))
                    S.Uninstall(k.Id);
            };
            more.Items.Add(rm);
        }
        var moreBtn = Ui.IconBtn(G.More, L.T("Lainnya"), () => { });
        moreBtn.Flyout = more;
        var head = Ui.Columns("Auto,*,Auto,Auto", 12, Ui.TintIcon(k.Glyph, k.Color, 40, 17, 11),
            Ui.Col(2, Ui.Text(k.Name, 15, FontWeights.Bold), Ui.Text(c != null ? L.T("versi {}", c.Version) : "", 11, fg: Theme.Text2)),
            installed ? Dot(running) : null, moreBtn);
        var body = Ui.Col(14, head);
        if (!installed) body.Children.Add(ComponentRow(k.Id));
        else
        {
            var port = svc?.Port ?? 0;
            var box = PortBox(port, running, p => S.SaveSettings(k.Id switch
            {
                "mysql" => S.Settings with { MysqlPort = p },
                "postgres" => S.Settings with { PostgresPort = p },
                _ => S.Settings with { MongodbPort = p },
            }));
            body.Children.Add(Ui.Columns("Auto,Auto,*,Auto", 10, Ui.Text("Port", 12, fg: Theme.Text2).With(t => t.VerticalAlignment = VerticalAlignment.Center), box, null, Power(k.Id, running, true)));
            body.Children.Add(Ui.Text($"127.0.0.1:{port} · {L.T(k.Note)}", 11, fg: Theme.Text3));
            if (running)
            {
                var open = Ui.Secondary(L.T("Buka di Database"), G.Table, () => _ = OpenInDatabase(k, port));
                open.HorizontalAlignment = HorizontalAlignment.Stretch;
                body.Children.Add(open);
            }
        }
        if (svc?.Error is { } err && !running) body.Children.Add(Ui.Text("⚠ " + err, 11, fg: Theme.Brush(Theme.Orange), wrap: true));
        return Card(body, running).With(b => b.Padding = new Thickness(16));
    }

    /// <summary>Simpan koneksi "Lokal · &lt;DB&gt;" (sekali) lalu buka di halaman Database.</summary>
    private async Task OpenInDatabase(DbKind k, ushort port)
    {
        var label = $"Lokal · {k.Name}";
        var conn = M.Databases.FirstOrDefault(d => d.Label == label && d.Host == "127.0.0.1");
        if (conn == null || conn.Port != port)
        {
            M.Save((conn ?? new DbConnection("", label, k.Engine, "127.0.0.1", port, k.User, null, "", "", false, null, k.Color, 0, false)) with { Port = port });
            conn = M.Databases.FirstOrDefault(d => d.Label == label && d.Host == "127.0.0.1");
        }
        if (conn != null) await M.OpenDatabase(conn);
    }

    private async Task ShowLog(string service)
    {
        var text = new TextBlock { Text = S.Log(service) is { Length: > 0 } t ? t : L.T("Belum ada log."), FontFamily = Theme.MonoFont, FontSize = 11, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
        var scroll = new ScrollViewer { Content = text, Height = 380, Width = 620 };
        var d = Ui.Dialog(service == "web" ? L.T("Log web server") : L.T("Log {}", service), scroll, null, L.T("Tutup"));
        await d.ShowAsync();
    }
}
