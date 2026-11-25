using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using uniffi.zterm_core;

namespace Zterm.Views;

/// <summary>Docker gaya OrbStack: sidebar kecil, daftar ringkas per proyek Compose, panel detail di kanan. Padanan DockerView.swift.</summary>
internal sealed class DockerPage : PageBase
{
    private const string Blue = "#2496ED";
    private readonly Border _sidebar = new() { Width = 210, Padding = new Thickness(12, 14, 12, 14) };
    private readonly Grid _header = new() { Padding = new Thickness(18, 12, 18, 12) };
    private readonly StackPanel _list = Ui.Col(2);
    private readonly Border _detail = new() { Width = 380, Visibility = Visibility.Collapsed };
    private readonly Border _error = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(14, 10, 14, 0) };
    private DockerModel D => M.Docker;
    private bool _showEnv;
    private string? _detailFor;
    private int _detailTab;
    private TextBlock? _logText;
    private ScrollViewer? _logScroll;
    private bool _logFollow = true;

    public DockerPage() : base("docker", "data")
    {
        _sidebar.Background = Theme.Ink(0.018);
        _detail.Background = Theme.Ink(0.018);
        var listScroll = new ScrollViewer { Content = new Border { Padding = new Thickness(12, 10, 12, 10), Child = _list } };
        var center = Ui.Rows("Auto,Auto,Auto,*", 0, _header, Ui.Divider(), _error, listScroll);
        var sep1 = new Border { Width = 1, Background = Theme.Ink(0.07) };
        var sep2 = new Border { Width = 1, Background = Theme.Ink(0.07) };
        sep2.SetBinding(VisibilityProperty, new Microsoft.UI.Xaml.Data.Binding { Source = _detail, Path = new PropertyPath("Visibility") });
        Children.Add(Ui.Columns("Auto,Auto,*,Auto,Auto", 0, _sidebar, sep1, center, sep2, _detail));
        Loaded += async (s, e) =>
        {
            D.StartPolling();
            if (!D.Connected && !D.Loading) await D.Select(D.TargetId);
            _ = LogLoop();
        };
        Unloaded += (s, e) => { D.StopPolling(); _detailFor = null; };
        Render();
    }

    protected override void Render()
    {
        RenderSidebar();
        RenderHeader();
        RenderList();
        RenderDetail();
    }

    // MARK: Sidebar

    private void RenderSidebar()
    {
        var current = D.TargetId == null ? null : M.HostById(D.TargetId);
        var menu = new MenuFlyout();
        var local = new MenuFlyoutItem { Text = L.T("PC ini") };
        local.Click += (s, e) => _ = D.Select(null);
        menu.Items.Add(local);
        if (M.Hosts.Length > 0) menu.Items.Add(new MenuFlyoutSeparator());
        foreach (var h in M.Hosts)
        {
            var i = new MenuFlyoutItem { Text = h.Title() };
            i.Click += (s, e) => _ = D.Select(h.Id);
            menu.Items.Add(i);
        }
        var target = new DropDownButton
        {
            Content = Ui.Row(8, Ui.Icon(current == null ? G.Terminal : G.Server, 12), Ui.Text(current?.Title() ?? L.T("PC ini"), 12.5, FontWeights.SemiBold)),
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Flyout = menu,
        };
        var nav = Ui.Col(2);
        foreach (var (t, title, glyph) in new[] { (DockerModel.Tab.Containers, "Container", G.Apps), (DockerModel.Tab.Volumes, "Volume", G.Database), (DockerModel.Tab.Images, "Image", G.Structure), (DockerModel.Tab.Networks, "Network", G.Globe) })
        {
            var on = D.Current == t;
            var row = Ui.Columns("Auto,*,Auto", 9, Ui.Icon(glyph, 13, on ? Theme.Brush(Blue) : Theme.Text2),
                Ui.Text(L.T(title), 13, on ? FontWeights.SemiBold : FontWeights.Normal),
                D.Info != null ? Ui.Text(D.Count(t).ToString(), 11, fg: Theme.Text2) : null);
            var b = Ui.Plain(row, () => { D.Current = t; Render(); }, new Thickness(10, 7, 10, 7));
            b.HorizontalAlignment = HorizontalAlignment.Stretch;
            b.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            b.Background = on ? Theme.Brush(Blue, 0.14) : null;
            nav.Children.Add(b);
        }
        UIElement? info = null;
        if (D.Info is { } i2)
            info = new Border
            {
                Background = Theme.Ink(0.04), CornerRadius = new CornerRadius(10), Padding = new Thickness(12), VerticalAlignment = VerticalAlignment.Bottom,
                Child = Ui.Col(5,
                    Ui.Row(6, new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(4), Background = Theme.Brush(Theme.Green) }, Ui.Text($"Docker {i2.Version}", 11.5, FontWeights.SemiBold)),
                    Ui.Text(i2.Os + (i2.UsesSudo ? " · sudo" : ""), 11, fg: Theme.Text2),
                    Ui.Text($"{i2.Cpus} CPU · {Ui.Bytes(i2.Memory)}", 11, fg: Theme.Text2),
                    Ui.Text(L.T("{} dari {} container berjalan", i2.Running, i2.Containers), 11, fg: Theme.Text2, wrap: true)),
            };
        _sidebar.Child = Ui.Rows("Auto,Auto,*,Auto", 14, Ui.Col(6, Ui.Caps(L.T("Docker di")), target), nav, null, info);
    }

    private void RenderHeader()
    {
        _header.Children.Clear();
        var title = D.Current switch { DockerModel.Tab.Containers => "Container", DockerModel.Tab.Volumes => "Volume", DockerModel.Tab.Images => "Image", _ => "Network" };
        UIElement? search = D.Current == DockerModel.Tab.Containers ? Ui.Search(L.T("Cari"), D.Query, q => { D.Query = q; RenderList(); }, 200) : null;
        var refresh = Ui.IconBtn(G.Refresh, L.T("Muat ulang"), () => _ = D.Refresh());
        refresh.IsEnabled = D.Connected && !D.Loading;
        _header.Children.Add(Ui.Columns("Auto,Auto,*,Auto,Auto", 10, Ui.Text(L.T(title), 20, FontWeights.Bold),
            D.Loading && D.Info != null ? new ProgressRing { IsActive = true, Width = 16, Height = 16 } : null, null, search, refresh));

        if (D.Error is { } err)
        {
            var retry = Ui.Secondary(L.T("Coba lagi"), null, () => _ = D.Select(D.TargetId));
            _error.Child = new Border
            {
                Background = Theme.Brush(Theme.Orange, 0.12), CornerRadius = new CornerRadius(10), Padding = new Thickness(12),
                Child = Ui.Columns("Auto,*,Auto", 10, Ui.Icon(G.Warning, 15, Theme.Brush(Theme.Orange)), Ui.Text(err, 13, wrap: true), retry)
            };
            _error.Visibility = Visibility.Visible;
        }
        else _error.Visibility = Visibility.Collapsed;
    }

    // MARK: Daftar

    private void RenderList()
    {
        _list.Children.Clear();
        if (D.Info == null)
        {
            if (D.Loading)
                _list.Children.Add(Ui.Row(10, new ProgressRing { IsActive = true, Width = 18, Height = 18 }, Ui.Secondary(L.T("Menghubungkan ke Docker…"))).With(r => { r.HorizontalAlignment = HorizontalAlignment.Center; r.Margin = new Thickness(0, 60, 0, 0); }));
            return;
        }
        switch (D.Current)
        {
            case DockerModel.Tab.Containers:
                if (D.Containers.Length == 0) { _list.Children.Add(Ui.EmptyState(G.Apps, L.T("Belum ada container"), L.T("Container dari docker run atau docker compose akan muncul di sini."))); break; }
                foreach (var g in D.Groups)
                {
                    var items = g.ToList();
                    if (g.Key.Length == 0) { foreach (var c in items) _list.Children.Add(ContainerRow(c, false)); continue; }
                    _list.Children.Add(ProjectRow(g.Key, items));
                    if (!D.Collapsed.Contains(g.Key) || D.Query.Length > 0)
                        foreach (var c in items) _list.Children.Add(ContainerRow(c, true));
                }
                break;
            case DockerModel.Tab.Volumes:
                foreach (var v in D.Volumes)
                    _list.Children.Add(Row(IconTile(G.Database, !v.Anonymous),
                        Ui.Col(1, Ui.Text(v.Anonymous ? v.Name[..Math.Min(12, v.Name.Length)] + "…" : v.Name, 13, FontWeights.Medium),
                            Ui.Text(v.Project.Length > 0 ? $"{v.Project} · {v.Driver}" : v.Anonymous ? L.T("anonim · {}", v.Driver) : v.Driver, 11, fg: Theme.Text2)),
                        Actions(Danger(L.T("Hapus volume"), async () =>
                        {
                            if (await Ui.Confirm(L.T("Hapus volume {}?", v.Name[..Math.Min(24, v.Name.Length)]), L.T("Data di volume ini hilang permanen. Volume yang masih dipakai container tidak bisa dihapus.")))
                                await D.RemoveVolume(v);
                        })), false, null));
                break;
            case DockerModel.Tab.Images:
                foreach (var i in D.Images)
                    _list.Children.Add(Row(IconTile(G.Structure, true),
                        Ui.Col(1, Ui.Row(6, Ui.Text(i.Repository, 13, FontWeights.Medium), Ui.Badge(i.Tag, Theme.Accent2)), Ui.Text($"{i.Size} · {i.Created}", 11, fg: Theme.Text2)),
                        Actions(Danger(L.T("Hapus image"), async () =>
                        {
                            if (await Ui.Confirm(L.T("Hapus image {}?", $"{i.Repository}:{i.Tag}"), L.T("Image yang masih dipakai container tidak bisa dihapus.")))
                                await D.RemoveImage(i);
                        })), false, null));
                break;
            default:
                foreach (var n in D.Networks)
                    _list.Children.Add(Row(IconTile(G.Globe, !n.Builtin),
                        Ui.Col(1, Ui.Text(n.Name, 13, FontWeights.Medium),
                            Ui.Text(string.Join(" · ", new[] { n.Driver, n.Project.Length > 0 ? n.Project : n.Builtin ? L.T("bawaan") : "" }.Where(x => x.Length > 0)), 11, fg: Theme.Text2)),
                        null, false, null));
                break;
        }
    }

    private static Border IconTile(string glyph, bool active) => new()
    {
        Width = 30, Height = 30, CornerRadius = new CornerRadius(8), Background = active ? Theme.Brush(Blue, 0.16) : Theme.Ink(0.06),
        Child = Ui.Icon(glyph, 13, active ? Theme.Brush(Blue) : Theme.Text2),
    };

    private static StackPanel Actions(params UIElement?[] kids) => Ui.Row(2, kids);
    private static Button Danger(string tip, Func<Task> a) => Ui.IconBtn(G.Delete, tip, () => _ = a(), Theme.Brush("#E5484D"));

    /// <summary>Baris gaya OrbStack: sorotan saat hover/terpilih, tombol aksi muncul saat disorot.</summary>
    private Border Row(UIElement icon, UIElement text, UIElement? actions, bool selected, Action? click, UIElement? trailing = null, double indent = 0)
    {
        if (actions != null) actions.Opacity = selected ? 1 : 0;
        var grid = Ui.Columns("Auto,*,Auto,Auto", 10, icon, text, trailing, actions);
        var b = new Border
        {
            Height = 46, Padding = new Thickness(10 + indent, 0, 10, 0), CornerRadius = new CornerRadius(9),
            Background = selected ? Theme.Brush(Blue, 0.16) : null, Child = grid,
        };
        grid.VerticalAlignment = VerticalAlignment.Center;
        b.PointerEntered += (s, e) => { if (!selected) b.Background = Theme.Ink(0.05); if (actions != null) actions.Opacity = 1; };
        b.PointerExited += (s, e) => { if (!selected) b.Background = null; if (actions != null && !selected) actions.Opacity = 0; };
        if (click != null) b.Tapped += (s, e) => { if (e.OriginalSource is not FrameworkElement fe || fe.FindParent<Button>() == null) click(); };
        return b;
    }

    private Border StatusIcon(string state, double size = 30)
    {
        var running = state == "running";
        var color = state switch { "running" => Theme.Green, "paused" => Theme.Orange, "restarting" => "#EAB308", _ => "#6B7280" };
        var g = new Grid { Width = size, Height = size };
        g.Children.Add(new Border { CornerRadius = new CornerRadius(size * 0.27), Background = running ? Theme.Brush(Blue, 0.18) : Theme.Ink(0.06) });
        g.Children.Add(Ui.Icon(G.Apps, size * 0.42, running ? Theme.Brush(Blue) : Theme.Text2));
        g.Children.Add(new Border
        {
            Width = size * 0.3, Height = size * 0.3, CornerRadius = new CornerRadius(size * 0.15), Background = Theme.Brush(color),
            BorderThickness = new Thickness(2), BorderBrush = Theme.Brush(Theme.Dark ? "#0D1117" : "#FFFFFF"),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, -2, -2),
        });
        return new Border { Child = g };
    }

    private UIElement ProjectRow(string name, List<DockerContainer> items)
    {
        var running = items.Count(x => x.State == "running");
        var open = !D.Collapsed.Contains(name);
        var busy = D.Busy.Contains("compose:" + name);
        var chevron = Ui.Icon(open ? G.ChevronDown : G.ChevronRight, 10, Theme.Text2);
        var text = Ui.Col(1, Ui.Text(name, 13, FontWeights.SemiBold),
            Ui.Text(running > 0 ? L.T("{} dari {} berjalan", running, items.Count) : L.T("{} container · berhenti", items.Count), 11, fg: running > 0 ? Theme.Brush(Theme.Green) : Theme.Text2));
        var acts = Actions(
            busy ? new ProgressRing { IsActive = true, Width = 14, Height = 14 } : null,
            running > 0 ? Ui.IconBtn(G.Stop, L.T("Stop proyek"), () => _ = D.Compose(name, "stop")) : Ui.IconBtn(G.Play, L.T("Jalankan proyek (up)"), () => _ = D.Compose(name, "up"), Theme.Brush(Theme.Green)),
            Ui.IconBtn(G.Refresh, L.T("Restart proyek"), () => _ = D.Compose(name, "restart")),
            Danger(L.T("Down (hapus container proyek)"), async () =>
            {
                if (await Ui.Confirm(L.T("Down proyek {}?", name), L.T("Semua container proyek ini dihentikan dan dihapus (docker compose down). Volume tetap aman."), "Down"))
                    await D.Compose(name, "down");
            }));
        return Row(Ui.Row(8, chevron, IconTile(G.Structure, running > 0)), text, acts, false, () =>
        {
            if (!D.Collapsed.Remove(name)) D.Collapsed.Add(name);
            RenderList();
        });
    }

    private UIElement ContainerRow(DockerContainer c, bool indent)
    {
        var running = c.State == "running";
        var busy = D.Busy.Contains(c.Id);
        var text = Ui.Col(1, Ui.Text(c.Service.Length > 0 ? c.Service : c.Name, 13, FontWeights.Medium), Ui.Text(c.Image, 11, fg: Theme.Text2));
        var trailing = Ui.Row(8);
        if (running && FirstPort(c.Ports) is { } p)
        {
            var link = Ui.Plain(Ui.Text($":{p} ↗", 11, FontWeights.Medium, Theme.Brush(Blue), mono: true), () => Ui.Open(D.Url(p)), new Thickness(7, 2, 7, 3));
            link.Background = Theme.Brush(Blue, 0.12);
            link.CornerRadius = new CornerRadius(10);
            ToolTipService.SetToolTip(link, L.T("Buka di browser"));
            trailing.Children.Add(link);
        }
        if (running && D.Stats.TryGetValue(c.Id, out var st))
            trailing.Children.Add(Ui.Text($"{st.CpuPercent:0.0}%", 11, fg: Theme.Text2, mono: true).With(t => { t.Width = 46; t.TextAlignment = TextAlignment.Right; t.VerticalAlignment = VerticalAlignment.Center; }));
        var acts = Actions(
            busy ? new ProgressRing { IsActive = true, Width = 14, Height = 14 }
                 : running ? Ui.IconBtn(G.Stop, "Stop", () => _ = D.Action(c, "stop")) : Ui.IconBtn(G.Play, "Start", () => _ = D.Action(c, "start"), Theme.Brush(Theme.Green)),
            Ui.IconBtn(G.Refresh, "Restart", () => _ = D.Action(c, "restart")),
            Danger(L.T("Hapus container"), async () =>
            {
                if (await Ui.Confirm(L.T("Hapus container {}?", c.Name), L.T("Container dihentikan dan dihapus. Volume dan image tidak ikut terhapus.")))
                    await D.Action(c, "rm");
            }));
        return Row(StatusIcon(c.State), text, acts, D.SelectedId == c.Id, () => D.Choose(c), trailing, indent ? 22 : 0);
    }

    private static ushort? FirstPort(string ports)
    {
        foreach (var p in ports.Split(", "))
        {
            var i = p.IndexOf("->", StringComparison.Ordinal);
            if (i < 0) continue;
            if (ushort.TryParse(p[..i].Split(':').Last(), out var n)) return n;
        }
        return null;
    }

    // MARK: Detail

    private void RenderDetail()
    {
        if (D.Current != DockerModel.Tab.Containers || D.Selected is not { } c)
        {
            _detail.Visibility = Visibility.Collapsed;
            _detailFor = null;
            return;
        }
        if (_detailFor != c.Id) { _detailTab = 0; _showEnv = false; _logText = null; }
        _detailFor = c.Id;
        _detail.Visibility = Visibility.Visible;
        var running = c.State == "running";

        var head = Ui.Columns("Auto,*,Auto", 12, StatusIcon(c.State, 44),
            Ui.Col(2, Ui.Text(c.Name, 16, FontWeights.Bold).With(t => { t.TextTrimming = TextTrimming.CharacterEllipsis; t.IsTextSelectionEnabled = true; }),
                Ui.Text(c.Status, 11.5, fg: running ? Theme.Brush(Theme.Green) : Theme.Text2)),
            Ui.IconBtn(G.Close, L.T("Tutup"), () => D.Choose(null)));
        var shell = Ui.Secondary("Terminal", G.Terminal, () => D.OpenShell(c));
        shell.IsEnabled = running;
        var buttons = Ui.Row(8,
            running ? Ui.Secondary("Stop", G.Stop, () => _ = D.Action(c, "stop")) : Ui.Secondary("Start", G.Play, () => _ = D.Action(c, "start")),
            Ui.Secondary("Restart", G.Refresh, () => _ = D.Action(c, "restart")), shell);
        var tabs = Ui.Segmented(["Info", L.T("Log")], _detailTab, i => { _detailTab = i; RenderDetail(); });
        var top = new Border { Padding = new Thickness(16), Child = Ui.Col(12, head, buttons, tabs) };

        UIElement body;
        if (_detailTab == 0) body = new ScrollViewer { Content = new Border { Padding = new Thickness(16), Child = InfoPanel(c) } };
        else
        {
            _logText ??= new TextBlock { Text = L.T("Memuat log…"), FontFamily = Theme.MonoFont, FontSize = 10.5, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
            _logScroll = new ScrollViewer { Content = new Border { Padding = new Thickness(8), Child = _logText } };
            var follow = new ToggleSwitch { IsOn = _logFollow, OnContent = L.T("Ikuti log baru"), OffContent = L.T("Ikuti log baru") };
            follow.Toggled += (s, e) => _logFollow = follow.IsOn;
            var box = new Border { Background = Theme.Field, CornerRadius = new CornerRadius(8), Child = _logScroll };
            body = new Border { Padding = new Thickness(12), Child = Ui.Rows("Auto,*", 8, follow, box) };
        }
        _detail.Child = Ui.Rows("Auto,Auto,*", 0, top, Ui.Divider(), body);
    }

    private UIElement InfoPanel(DockerContainer c)
    {
        var col = Ui.Col(18);
        UIElement Group(string title, UIElement content, UIElement? trailing = null) => Ui.Col(8,
            Ui.Columns("*,Auto", 8, Ui.Caps(L.T(title)), trailing),
            new Border { Background = Theme.Ink(0.04), CornerRadius = new CornerRadius(10), Padding = new Thickness(12), Child = content });
        UIElement Kv(string k, string v) => Ui.Columns("74,*", 8, Ui.Text(L.T(k), 12, fg: Theme.Text2), Ui.Text(v, 12, wrap: true).With(t => t.IsTextSelectionEnabled = true));

        if (c.State == "running" && D.Stats.TryGetValue(c.Id, out var s))
            col.Children.Add(Group("Pemakaian", Ui.Col(8, Usage("CPU", s.CpuPercent, $"{s.CpuPercent:0.0}%"), Usage("RAM", s.MemPercent, s.MemUsage))));
        var d = D.Detail is { } dd && dd.Id.StartsWith(c.Id) ? dd : null;
        if (d is { Ports.Length: > 0 })
        {
            var ports = Ui.Col(6);
            foreach (var p in d.Ports)
            {
                var link = Ui.Plain(Ui.Columns("*,Auto", 8, Ui.Text($"{D.Url(p.HostPort).Replace("http://", "")} ↗", 12, fg: Theme.Brush(Blue), mono: true), Ui.Text(p.ContainerPort, 12, fg: Theme.Text2, mono: true)),
                    () => Ui.Open(D.Url(p.HostPort)), new Thickness(0));
                link.HorizontalAlignment = HorizontalAlignment.Stretch;
                link.HorizontalContentAlignment = HorizontalAlignment.Stretch;
                ports.Children.Add(link);
            }
            col.Children.Add(Group("Port", ports));
        }
        var general = Ui.Col(7, Kv("Image", c.Image));
        if (d != null)
        {
            general.Children.Add(Kv("Perintah", d.Command));
            general.Children.Add(Kv("Dibuat", d.Created));
            if (!d.StartedAt.StartsWith("0001")) general.Children.Add(Kv(L10n.English ? "Started" : "Mulai", d.StartedAt));
            general.Children.Add(Kv("Restart", d.RestartPolicy));
            if (d.Health.Length > 0) general.Children.Add(Kv("Health", d.Health));
        }
        general.Children.Add(Kv("ID", c.Id[..Math.Min(12, c.Id.Length)]));
        if (c.Project.Length > 0) general.Children.Add(Kv("Compose", $"{c.Project} · {c.Service}"));
        col.Children.Add(Group("Umum", general));
        if (d == null) { col.Children.Add(new ProgressRing { IsActive = true, Width = 18, Height = 18 }); return col; }
        if (d.Networks.Length > 0)
        {
            var nets = Ui.Col(6, Kv("IP", d.IpAddress.Length > 0 ? d.IpAddress : "—"));
            foreach (var n in d.Networks) nets.Children.Add(Ui.Text(n, 12, mono: true));
            col.Children.Add(Group("Network", nets));
        }
        if (d.Mounts.Length > 0)
        {
            var m = Ui.Col(6);
            foreach (var x in d.Mounts) m.Children.Add(Ui.Text(x, 11, mono: true, wrap: true).With(t => t.IsTextSelectionEnabled = true));
            col.Children.Add(Group("Mount", m));
        }
        if (d.Env.Length > 0)
        {
            var env = Ui.Col(5);
            foreach (var e in d.Env)
            {
                var i = e.IndexOf('=');
                var k = i < 0 ? e : e[..i];
                var v = i < 0 ? "" : e[(i + 1)..];
                env.Children.Add(Ui.Columns("Auto,*", 6, Ui.Text(k, 11, FontWeights.SemiBold, mono: true),
                    Ui.Text(_showEnv ? v : "••••••", 11, fg: Theme.Text2, mono: true, wrap: true).With(t => t.IsTextSelectionEnabled = true)));
            }
            var toggle = Ui.Plain(Ui.Text(_showEnv ? L.T("Sembunyikan") : L.T("Tampilkan"), 11, FontWeights.SemiBold, Theme.Brush(Blue)), () => { _showEnv = !_showEnv; RenderDetail(); }, new Thickness(0));
            col.Children.Add(Group("Environment", env, toggle));
        }
        return col;
    }

    private static UIElement Usage(string label, double value, string text)
    {
        var bar = new Grid { Height = 5, Background = Theme.Ink(0.08), CornerRadius = new CornerRadius(3) };
        var fill = new Border { HorizontalAlignment = HorizontalAlignment.Left, CornerRadius = new CornerRadius(3), Background = Theme.Brush(value > 80 ? Theme.Red : value > 50 ? Theme.Orange : Blue) };
        bar.Children.Add(fill);
        bar.SizeChanged += (s, e) => fill.Width = Math.Max(3, e.NewSize.Width * Math.Min(1, value / 100));
        return Ui.Col(5, Ui.Columns("*,Auto", 8, Ui.Text(label, 11.5, FontWeights.SemiBold), Ui.Text(text, 11.5, fg: Theme.Text2, mono: true)), bar);
    }

    /// <summary>Log container terpilih diperbarui tiap 2 detik selama tab Log terbuka (di thread UI).</summary>
    private async Task LogLoop()
    {
        while (IsLoaded)
        {
            if (_detailTab == 1 && _detailFor is { } id && _logText != null && _logFollow)
            {
                var t = await D.Logs(id, 500);
                if (_detailFor == id && _logText != null)
                {
                    _logText.Text = t.Length > 0 ? t : L.T("Belum ada log.");
                    _logScroll?.ChangeView(null, double.MaxValue, null, true);
                }
            }
            await Task.Delay(2000);
        }
    }
}

internal static class VisualTreeExt
{
    public static T? FindParent<T>(this DependencyObject d) where T : DependencyObject
    {
        var p = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(d);
        while (p != null && p is not T) p = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(p);
        return p as T;
    }
}
