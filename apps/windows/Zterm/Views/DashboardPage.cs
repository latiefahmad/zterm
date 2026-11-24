using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using uniffi.zterm_core;

namespace Zterm.Views;

/// <summary>Dashboard semua server: CPU, RAM, disk & uptime tiap host — padanan DashboardView.swift.</summary>
internal sealed class DashboardPage : PageBase
{
    private DashboardModel D => M.Dashboard;
    private readonly StackPanel _actions;
    private readonly StackPanel _summary = Ui.Col(0);
    private readonly Grid _filters;
    private readonly StackPanel _grid = Ui.Col(14);
    private readonly Grid _bar = new() { VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 18) };
    private readonly StackPanel _body;
    private int _columns = 3;

    public DashboardPage() : base("dashboard", "data")
    {
        var header = Ui.Header(L.T("Dashboard"), L.T("Semua server dalam satu layar — CPU, RAM, disk & uptime, diperbarui tiap 5 detik"));
        _actions = (StackPanel)header.Children[1];
        var search = Ui.Search(L.T("Cari server, OS, grup…"), D.Query, q => { D.Query = q; RenderGrid(); }, 240);
        search.HorizontalAlignment = HorizontalAlignment.Right;
        _filters = Ui.Columns("Auto,*", 12, new Border(), search);
        _body = Ui.Col(20, header, _summary, _filters, _grid);
        var scroll = Ui.Scroll(_body);
        Children.Add(scroll);
        Children.Add(_bar);
        SizeChanged += (s, e) =>
        {
            var cols = Math.Max(1, (int)((e.NewSize.Width - 56 + 14) / 304));
            if (cols != _columns) { _columns = cols; RenderGrid(); }
        };
        Loaded += (s, e) => { D.Start(); Render(); };
        Unloaded += (s, e) => { if (!D.Alerts) D.Stop(); };
        Render();
    }

    protected override void OnModelChanged(string what)
    {
        if (what == "data") D.Start();
        Render();
    }

    protected override void Render()
    {
        _actions.Children.Clear();
        if (D.Tiles.Values.Any(t => t.State == ServerTile.Status.Offline))
            _actions.Children.Add(Ui.IconBtn(G.Refresh, L.T("Coba lagi semua server yang offline"), D.RetryOffline));
        var bell = Ui.Secondary(D.Alerts ? L.T("Notifikasi aktif") : L.T("Notifikasi"), D.Alerts ? "\uEA8F" : "\uE7ED", () => M.SetDashboardAlerts(!D.Alerts),
            D.Alerts ? Theme.Brush(Theme.Accent) : null);
        ToolTipService.SetToolTip(bell, D.Alerts
            ? L.T("Dashboard terus memantau di latar belakang dan memberi notifikasi saat server mati atau CPU/RAM/disk di atas 90%. Klik untuk mematikan.")
            : L.T("Nyalakan notifikasi: pantau terus di latar belakang, beri tahu saat server mati atau CPU/RAM/disk di atas 90%"));
        _actions.Children.Add(bell);
        if (M.Hosts.Length > 0)
        {
            var run = Ui.Primary(L.T("Jalankan perintah"), G.Play, () => new RunManyDialog(M.NewRunMany(D.SelectedIds)).Show());
            ToolTipService.SetToolTip(run, L.T("Jalankan satu perintah di banyak server sekaligus, hasilnya per server"));
            _actions.Children.Add(run);
        }

        var empty = M.Hosts.Length == 0;
        _summary.Visibility = _filters.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
        _summary.Children.Clear();
        if (!empty) _summary.Children.Add(Summary());
        var seg = Ui.Segmented([L.T("Semua"), L.T("Perlu perhatian"), L.T("Offline")], (int)D.Current, i => { D.Current = (DashboardModel.Filter)i; Render(); });
        seg.Width = 330;
        _filters.Children[0] = seg;
        RenderGrid();
        RenderBar();
    }

    private void RenderGrid()
    {
        _grid.Children.Clear();
        if (M.Hosts.Length == 0)
        {
            _grid.Children.Add(Ui.EmptyState(G.Gauge, L.T("Belum ada server"),
                L.T("Tambahkan host di menu Hosts — semua server langsung tampil di sini lengkap dengan pemakaian CPU, RAM, dan disk.")));
            return;
        }
        var tiles = D.Ordered;
        if (tiles.Count == 0)
        {
            _grid.Children.Add(Ui.Secondary(D.Current == DashboardModel.Filter.All ? L.T("Tidak ada server yang cocok.") : L.T("Semua server sehat 🎉"))
                .With(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 40, 0, 0); }));
            return;
        }
        for (int i = 0; i < tiles.Count; i += _columns)
        {
            var spec = string.Join(",", Enumerable.Repeat("*", _columns));
            var row = Ui.Columns(spec, 14, tiles.Skip(i).Take(_columns).Select(Card).ToArray());
            _grid.Children.Add(row);
        }
    }

    // MARK: Ringkasan

    private UIElement Summary()
    {
        var live = D.Tiles.Values.Where(t => t.State == ServerTile.Status.Online).ToList();
        var cpu = live.Count == 0 ? 0 : live.Average(t => t.CpuNow);
        ulong used = 0, total = 0;
        foreach (var t in live) if (t.Sample is { } s) { used += s.MemUsedBytes; total += s.MemTotalBytes; }
        return Ui.Columns("*,*,*,*", 14,
            Stat(L.T("Online"), $"{D.Online}/{D.Tiles.Count}", G.Server, Theme.Green),
            Stat(L.T("Perlu perhatian"), D.Attention.ToString(), G.Warning, D.Attention > 0 ? Theme.Red : "#94A3B8"),
            Stat(L.T("CPU rata-rata"), live.Count == 0 ? "—" : $"{cpu:0}%", G.Gauge, Theme.Accent),
            Stat(L.T("RAM terpakai"), total == 0 ? "—" : $"{Ui.Bytes(used)} / {Ui.Bytes(total)}", G.Stack, Theme.Accent3));
    }

    private static Border Stat(string title, string value, string glyph, string hex)
    {
        var icon = new Border
        {
            Width = 34, Height = 34, CornerRadius = new CornerRadius(10), Background = Theme.Brush(hex, 0.12),
            Child = Ui.Icon(glyph, 14, Theme.Brush(hex))
        };
        var text = Ui.Col(2, Ui.Text(title, 11.5, fg: Theme.Text2),
            Ui.Text(value, 17, FontWeights.Bold).With(t => t.TextTrimming = TextTrimming.CharacterEllipsis));
        return Ui.Card(Ui.Columns("Auto,*", 12, icon, text), 12);
    }

    // MARK: Kartu server

    private UIElement Card(ServerTile t)
    {
        var selected = D.Selection.Contains(t.Id);
        var avatar = new Border
        {
            Width = 32, Height = 32, CornerRadius = new CornerRadius(9), Background = Theme.TintGradient(t.Host.Color),
            Child = selected ? Ui.Icon(G.Check, 13, new SolidColorBrush(Microsoft.UI.Colors.White))
                : Ui.Text(t.Host.Title().Length > 0 ? t.Host.Title()[..1].ToUpperInvariant() : "?", 14, FontWeights.Bold, new SolidColorBrush(Microsoft.UI.Colors.White))
                    .With(x => { x.HorizontalAlignment = HorizontalAlignment.Center; x.VerticalAlignment = VerticalAlignment.Center; }),
        };
        var pick = Ui.Plain(avatar, () => D.Toggle(t.Id), new Thickness(0));
        ToolTipService.SetToolTip(pick, selected ? L.T("Batal pilih") : L.T("Pilih untuk dibuka bersama (split & broadcast)"));
        var subtitle = t.Info?.Os is { Length: > 0 } os ? os : t.Host.Address();
        var head = Ui.Columns("Auto,*,Auto,Auto,Auto", 8, pick,
            Ui.Col(1, Ui.Text(t.Host.Title(), 13.5, FontWeights.SemiBold).With(x => x.TextTrimming = TextTrimming.CharacterEllipsis),
                Ui.Text(subtitle, 11.5, fg: Theme.Text2).With(x => x.TextTrimming = TextTrimming.CharacterEllipsis)),
            Status(t),
            Ui.IconBtn(G.Terminal, L.T("Buka terminal"), () => M.Connect([t.Id]), size: 12),
            Ui.IconBtn(G.Folder, L.T("Buka SFTP"), () => _ = M.OpenSftp(t.Host), size: 12));

        UIElement content = t.State switch
        {
            ServerTile.Status.Offline => Ui.Col(8,
                Ui.Row(6, Ui.Icon(G.Warning, 13, Theme.Brush(Theme.Red)), Ui.Text(L.T("Tidak bisa dihubungi"), 13, FontWeights.SemiBold, Theme.Brush(Theme.Red))),
                Ui.Text(t.Error ?? "", 11.5, fg: Theme.Text2, wrap: true).With(x => { x.MaxLines = 3; x.IsTextSelectionEnabled = true; }),
                Ui.Secondary(L.T("Coba lagi"), null, () => D.Retry(t)).With(b => b.Margin = new Thickness(0, 6, 0, 0))),
            _ when t.Sample == null => Ui.Row(8, new ProgressRing { Width = 16, Height = 16, IsActive = true }, Ui.Text(L.T("Menghubungkan…"), 12.5, fg: Theme.Text2))
                .With(x => { x.HorizontalAlignment = HorizontalAlignment.Center; x.Margin = new Thickness(0, 46, 0, 46); }),
            _ => Metrics(t),
        };

        var stroke = selected ? Theme.Brush(Theme.Accent)
            : t.NeedsAttention ? Theme.Brush(Theme.Red, 0.55)
            : t.Health == ServerTile.Level.Warn ? Theme.Brush(Theme.Orange, 0.45) : Theme.CardStroke;
        var card = new Border
        {
            Child = Ui.Col(12, head, content), Padding = new Thickness(14), CornerRadius = new CornerRadius(14), Background = Theme.Card,
            BorderBrush = stroke, BorderThickness = new Thickness(selected ? 1.5 : 1), MinHeight = 196,
        };
        card.PointerEntered += (_, _) => card.Background = Theme.CardHover;
        card.PointerExited += (_, _) => card.Background = Theme.Card;
        var menu = new MenuFlyout();
        void Item(string text, Action a) { var it = new MenuFlyoutItem { Text = text }; it.Click += (_, _) => a(); menu.Items.Add(it); }
        Item(L.T("Buka terminal"), () => M.Connect([t.Id]));
        Item(L.T("Buka SFTP"), () => _ = M.OpenSftp(t.Host));
        menu.Items.Add(new MenuFlyoutSeparator());
        Item(selected ? L.T("Batal pilih") : L.T("Pilih"), () => D.Toggle(t.Id));
        Item(L.T("Sambung ulang"), () => D.Retry(t));
        card.ContextFlyout = menu;
        return card;
    }

    private static UIElement Status(ServerTile t)
    {
        switch (t.State)
        {
            case ServerTile.Status.Online:
                var issues = t.Issues;
                if (issues.Count > 0) return Ui.Badge(issues.Count > 1 ? $"{issues[0]} +{issues.Count - 1}" : issues[0], Theme.Red);
                return Ui.Row(5, new Ellipse { Width = 7, Height = 7, Fill = Theme.Brush(Theme.Green), VerticalAlignment = VerticalAlignment.Center },
                    Ui.Text(L.T("Online"), 11.5, fg: Theme.Text2)).With(x => x.VerticalAlignment = VerticalAlignment.Center);
            case ServerTile.Status.Offline:
                return Ui.Badge(L.T("Offline"), Theme.Red);
            default:
                return new ProgressRing { Width = 14, Height = 14, IsActive = true };
        }
    }

    private static string Tint(ServerTile.Level l, string ok) => l switch
    {
        ServerTile.Level.Critical => Theme.Red, ServerTile.Level.Warn => Theme.Orange, _ => ok,
    };

    private static UIElement Metrics(ServerTile t)
    {
        var s = t.Sample!;
        var cpuLevel = ServerTile.LevelOf(t.CpuNow / 100);
        var cpu = Ui.Col(0, Ui.Text("CPU", 11.5, fg: Theme.Text2),
            Ui.Text($"{t.CpuNow:0}%", 24, FontWeights.Bold, cpuLevel == ServerTile.Level.Ok ? Theme.Text : Theme.Brush(Tint(cpuLevel, Theme.Accent))));
        cpu.Width = 64;
        var top = Ui.Columns("Auto,*", 12, cpu, Spark(t.Cpu));
        var foot = Ui.Columns("Auto,Auto,*,Auto,Auto", 12,
            Foot(G.Clock, Uptime(s.UptimeSecs)), Foot(G.Gauge, s.Load1.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture)),
            new Border(), Foot(G.Download, Rate(t.Rx)), Foot(G.Upload, Rate(t.Tx)));
        return Ui.Col(11, top, Bar("RAM", s.MemUsedBytes, s.MemTotalBytes, Theme.Accent3), Bar("Disk", s.DiskUsedBytes, s.DiskTotalBytes, Theme.Orange), foot);
    }

    /// <summary>Grafik CPU kecil (30 sampel terakhir, mengalir dari kanan).</summary>
    private static UIElement Spark(List<double> cpu)
    {
        const double H = 40;
        var canvas = new Canvas { Height = H, VerticalAlignment = VerticalAlignment.Bottom };
        canvas.SizeChanged += (_, e) =>
        {
            canvas.Children.Clear();
            var w = e.NewSize.Width;
            if (cpu.Count == 0 || w <= 0) return;
            var step = w / 29;
            var x0 = w - (cpu.Count - 1) * step;
            var line = new Polyline { Stroke = Theme.Brush(Theme.Accent), StrokeThickness = 2, StrokeLineJoin = PenLineJoin.Round };
            var area = new Polygon { Fill = Theme.Brush(Theme.Accent, 0.16) };
            area.Points.Add(new Windows.Foundation.Point(x0, H));
            for (int k = 0; k < cpu.Count; k++)
            {
                var p = new Windows.Foundation.Point(x0 + k * step, H - Math.Clamp(cpu[k] / 100, 0, 1) * (H - 3));
                line.Points.Add(p);
                area.Points.Add(p);
            }
            area.Points.Add(new Windows.Foundation.Point(w, H));
            canvas.Children.Add(area);
            canvas.Children.Add(line);
        };
        return canvas;
    }

    private static UIElement Bar(string label, ulong used, ulong total, string color)
    {
        var f = total > 0 ? Math.Min(1, (double)used / total) : 0;
        var level = ServerTile.LevelOf(f);
        var track = new Grid { Height = 5, CornerRadius = new CornerRadius(3), Background = Theme.Ink(0.08) };
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0.02, f), GridUnitType.Star) });
        track.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(0.0001, 1 - f), GridUnitType.Star) });
        track.Children.Add(new Border { CornerRadius = new CornerRadius(3), Background = Theme.Brush(Tint(level, color)) });
        var head = Ui.Columns("Auto,Auto,*,Auto", 6,
            Ui.Text(label, 11.5, FontWeights.Medium),
            Ui.Text($"{f * 100:0}%", 11.5, FontWeights.SemiBold, level == ServerTile.Level.Ok ? Theme.Text2 : Theme.Brush(Tint(level, color))),
            new Border(),
            Ui.Text(total > 0 ? $"{Ui.Bytes(used)} / {Ui.Bytes(total)}" : "—", 10.5, fg: Theme.Text2).With(t => t.FontFamily = Theme.MonoFont));
        return Ui.Col(4, head, track);
    }

    private static UIElement Foot(string glyph, string text) => Ui.Row(3, Ui.Icon(glyph, 10, Theme.Text2),
        Ui.Text(text, 11, fg: Theme.Text2).With(t => t.FontFamily = Theme.MonoFont));

    private static string Uptime(ulong s)
    {
        ulong d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60;
        return d > 0 ? L.T("{} hari", d) : h > 0 ? L.T("{} jam", h) : L.T("{} mnt", m);
    }

    private static string Rate(double bps) => bps switch
    {
        < 1000 => $"{(int)bps} B/s",
        < 1_000_000 => $"{bps / 1000:0} KB/s",
        _ => $"{bps / 1_000_000:0.0} MB/s",
    };

    // MARK: Bar pilihan

    private void RenderBar()
    {
        _bar.Children.Clear();
        var ids = D.SelectedIds;
        _bar.Visibility = ids.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        _body.Margin = new Thickness(0, 0, 0, ids.Count == 0 ? 0 : 70);
        if (ids.Count == 0) return;
        var count = new Border
        {
            MinWidth = 24, Height = 24, CornerRadius = new CornerRadius(12), Background = Theme.Brush(Theme.Accent),
            Child = Ui.Text(ids.Count.ToString(), 13, FontWeights.Bold, new SolidColorBrush(Microsoft.UI.Colors.Black))
                .With(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.VerticalAlignment = VerticalAlignment.Center; }),
        };
        var cancel = Ui.Plain(Ui.Text(L.T("Batal"), 13, fg: Theme.Text2), () => { D.Selection.Clear(); Render(); }, new Thickness(8, 4, 8, 4));
        var open = Ui.Secondary(L.T("Buka tab"), G.Terminal, () => { M.Connect(ids); D.Selection.Clear(); });
        var runMany = Ui.Secondary(L.T("Jalankan perintah"), G.Play, () => new RunManyDialog(M.NewRunMany(ids)).Show());
        var split = Ui.Primary("Split & broadcast", "", () => { M.OpenSplit(ids, true); D.Selection.Clear(); });
        split.IsEnabled = ids.Count >= 2 && ids.Count <= AppModel.MaxSplit;
        ToolTipService.SetToolTip(split, ids.Count > AppModel.MaxSplit ? L.T("Maksimal {} server dalam satu split", AppModel.MaxSplit) : L.T("Buka berdampingan, ketikan dikirim ke semua"));
        _bar.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(24), Padding = new Thickness(14, 8, 8, 8), BorderThickness = new Thickness(1), BorderBrush = Theme.Ink(0.1),
            Background = Theme.Dark ? Theme.Brush("#1A1F27") : new SolidColorBrush(Microsoft.UI.Colors.White),
            Shadow = new ThemeShadow(), Translation = new System.Numerics.Vector3(0, 0, 24),
            Child = Ui.Row(12, count, Ui.Text(L.T("server dipilih"), 13).With(t => t.VerticalAlignment = VerticalAlignment.Center), cancel, open, runMany, split),
        });
    }
}
