using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using uniffi.zterm_core;

namespace Zterm.Views;

/// <summary>Kelola Server: proses, service, cron, log — padanan AdminView.swift.</summary>
internal sealed class AdminPage : PageBase
{
    private AdminModel A => M.Admin;
    private readonly StackPanel _hostRow = Ui.Row(12);
    private readonly Border _tabs = new();
    private readonly Border _banner = new() { Margin = new Thickness(28, 0, 28, 10) };
    private readonly Border _content = new() { Padding = new Thickness(28, 0, 28, 20) };
    private readonly StackPanel _actions;
    private readonly Grid _procSearch, _svcSearch, _logSearch;
    private StackPanel? _procList, _svcList;
    private RichTextBlock? _log;
    private ScrollViewer? _logScroll;
    private TextBlock? _logCount;

    private static readonly (AdminModel.Tab Tab, string Title, string Glyph)[] TabInfo =
    [
        (AdminModel.Tab.Processes, "Proses", ""), (AdminModel.Tab.Services, "Service", ""),
        (AdminModel.Tab.Cron, "Cron", ""), (AdminModel.Tab.Logs, "Log", ""),
    ];

    public AdminPage() : base("admin", "admin.list", "admin.log", "data")
    {
        var header = Ui.Header(L.T("Kelola Server"), L.T("Proses, service, cron, dan log server — tanpa hafal perintah"));
        _actions = (StackPanel)header.Children[1];
        _procSearch = Ui.Search(L.T("Cari PID, user, perintah…"), A.ProcQuery, q => { A.ProcQuery = q; RenderProcList(); }, 280);
        _svcSearch = Ui.Search(L.T("Cari service"), A.SvcQuery, q => { A.SvcQuery = q; RenderSvcList(); }, 240);
        _logSearch = Ui.Search(L.T("Saring baris…"), A.LogQuery, q => { A.LogQuery = q; RenderLogText(true); }, 260);
        var top = Ui.Col(16, header, Ui.Columns("*,Auto", 12, _hostRow, _tabs));
        top.Margin = new Thickness(28, 28, 28, 16);
        Children.Add(Ui.Rows("Auto,Auto,*", 0, top, _banner, _content));
        Loaded += async (_, _) =>
        {
            A.StartPolling();
            if (A.TargetId == null && M.Hosts.Length > 0)
            {
                var first = M.Hosts.FirstOrDefault(h => M.Dashboard.Tiles.GetValueOrDefault(h.Id)?.State == ServerTile.Status.Online) ?? M.Hosts[0];
                await A.Select(first.Id);
            }
        };
        Unloaded += (_, _) => A.StopPolling();
        Render();
    }

    protected override void OnModelChanged(string what)
    {
        switch (what)
        {
            case "admin.list":
                if (A.Current == AdminModel.Tab.Processes) RenderProcList(); else if (A.Current == AdminModel.Tab.Services) RenderSvcList();
                break;
            case "admin.log":
                RenderLogText(false);
                break;
            default:
                Render();
                break;
        }
    }

    protected override void Render()
    {
        _actions.Children.Clear();
        if (A.Connected) _actions.Children.Add(Ui.IconBtn(G.Refresh, L.T("Muat ulang"), () => _ = A.Load()));
        RenderHostRow();
        RenderTabs();
        RenderBanner();
        RenderContent();
    }

    private void RenderHostRow()
    {
        _hostRow.Children.Clear();
        if (M.Hosts.Length == 0) return;
        var combo = new ComboBox { MinWidth = 200, PlaceholderText = L.T("Pilih server") };
        foreach (var h in M.Hosts)
        {
            combo.Items.Add(new ComboBoxItem { Content = Ui.Row(8, new Ellipse { Width = 8, Height = 8, Fill = Theme.Brush(h.Color), VerticalAlignment = VerticalAlignment.Center }, Ui.Text(h.Title(), 13, FontWeights.SemiBold)), Tag = h.Id });
            if (h.Id == A.TargetId) combo.SelectedIndex = combo.Items.Count - 1;
        }
        combo.SelectionChanged += (_, _) => { if (combo.SelectedItem is ComboBoxItem { Tag: string id } && id != A.TargetId) _ = A.Select(id); };
        _hostRow.Children.Add(combo);
        if (A.System is { } s)
        {
            var ok = s.IsRoot || s.Sudo;
            _hostRow.Children.Add(Ui.Row(6, Ui.Icon(ok ? G.Key : G.Person, 12, Theme.Brush(ok ? Theme.Green : Theme.Orange)),
                Ui.Text($"{s.User} · {(s.IsRoot ? "root" : s.Sudo ? "sudo" : L.T("tanpa sudo"))}", 12),
                Ui.Text(s.Os.Length > 0 ? "· " + s.Os : "", 12, fg: Theme.Text2)).With(r => r.VerticalAlignment = VerticalAlignment.Center));
        }
        if (A.Connecting) _hostRow.Children.Add(new ProgressRing { Width = 16, Height = 16, IsActive = true });
    }

    private void RenderTabs()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        foreach (var (tab, title, glyph) in TabInfo)
        {
            var on = A.Current == tab;
            var b = Ui.Plain(Ui.Row(6, Ui.Icon(glyph, 12, on ? Theme.Text : Theme.Text2), Ui.Text(L.T(title), 12.5, on ? FontWeights.SemiBold : FontWeights.Normal, on ? Theme.Text : Theme.Text2)),
                () => { if (A.Current != tab) { A.Current = tab; Render(); _ = A.Load(); } }, new Thickness(12, 6, 12, 6));
            b.Background = on ? Theme.Ink(0.12) : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            row.Children.Add(b);
        }
        _tabs.Child = row;
        _tabs.Padding = new Thickness(3);
        _tabs.CornerRadius = new CornerRadius(10);
        _tabs.Background = Theme.Ink(0.05);
        _tabs.Visibility = M.Hosts.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    }

    private void RenderBanner()
    {
        _banner.Child = null;
        _banner.Visibility = Visibility.Collapsed;
        if (A.Connected && A.System is { IsRoot: false, Sudo: false } s)
        {
            _banner.Visibility = Visibility.Visible;
            _banner.Child = Ui.Row(6, Ui.Icon(G.Lock, 12, Theme.Brush(Theme.Orange)),
                Ui.Text(L.T("User {} tanpa sudo: bisa melihat, tapi aksi yang butuh root (service, proses user lain, log sistem) akan ditolak.", s.User), 12, fg: Theme.Brush(Theme.Orange), wrap: true));
        }
        else if (A.Connected && A.Error is { } e)
        {
            _banner.Visibility = Visibility.Visible;
            _banner.Child = Ui.Row(6, Ui.Icon(G.Warning, 12, Theme.Brush(Theme.Red)), Ui.Text(e, 12, fg: Theme.Brush(Theme.Red), wrap: true));
        }
    }

    private void RenderContent()
    {
        _procList = _svcList = null;
        _log = null;
        if (M.Hosts.Length == 0)
        {
            _content.Child = Ui.EmptyState(G.Server, L.T("Belum ada server"), L.T("Tambahkan host di menu Hosts, lalu kelola proses, service, cron, dan log-nya dari sini."));
            return;
        }
        if (A.TargetId == null) { _content.Child = Ui.EmptyState(G.Server, L.T("Pilih server"), L.T("Pilih server di atas untuk melihat proses, service systemd, crontab, dan log-nya.")); return; }
        if (!A.Connected)
        {
            if (A.Error is { } e && !A.Connecting)
            {
                _content.Child = Ui.Col(12, Ui.Icon(G.Warning, 28, Theme.Brush(Theme.Red)),
                    Ui.Text(e, 13, fg: Theme.Text2, wrap: true).With(t => { t.TextAlignment = TextAlignment.Center; t.MaxWidth = 460; }),
                    Ui.Secondary(L.T("Coba lagi"), G.Refresh, () => _ = A.Select(A.TargetId))).With(c => { c.HorizontalAlignment = HorizontalAlignment.Center; c.Margin = new Thickness(0, 60, 0, 0); });
            }
            else _content.Child = Ui.Row(8, new ProgressRing { Width = 18, Height = 18, IsActive = true }, Ui.Text(L.T("Menghubungkan…"), 13, fg: Theme.Text2))
                .With(r => { r.HorizontalAlignment = HorizontalAlignment.Center; r.Margin = new Thickness(0, 60, 0, 0); });
            return;
        }
        _content.Child = A.Current switch
        {
            AdminModel.Tab.Processes => ProcessesView(),
            AdminModel.Tab.Services => ServicesView(),
            AdminModel.Tab.Cron => CronView(),
            _ => LogsView(),
        };
    }

    /// <summary>Lepaskan kontrol yang dipakai ulang (kotak cari) dari induk lamanya sebelum dipasang lagi.</summary>
    private static T Detach<T>(T e) where T : FrameworkElement
    {
        switch (e.Parent)
        {
            case Panel p: p.Children.Remove(e); break;
            case Border b: b.Child = null; break;
        }
        return e;
    }

    private static Border Panel(UIElement child) => new()
    {
        Child = child, CornerRadius = new CornerRadius(12), Background = Theme.Card, BorderBrush = Theme.CardStroke, BorderThickness = new Thickness(1),
    };

    // MARK: Proses

    private UIElement ProcessesView()
    {
        _procList = Ui.Col(0);
        var sort = Ui.Segmented(["CPU", L.T("Memori"), "PID"], (int)A.Sort, i => { A.Sort = (AdminModel.ProcSort)i; Render(); });
        sort.Width = 240;
        var count = Ui.Text("", 11.5, fg: Theme.Text2);
        var bar = Ui.Columns("Auto,Auto,*,Auto", 12, Detach(_procSearch), sort, new Border(), count);
        var header = ProcRow(null);
        var table = Panel(Ui.Rows("Auto,Auto,*", 0, header, Ui.Divider(), new ScrollViewer { Content = _procList }));
        RenderProcList();
        count.Text = L.T("{} proses · diperbarui tiap 4 detik", A.FilteredProcesses.Count());
        return Ui.Rows("Auto,*", 10, bar, table);
    }

    private void RenderProcList()
    {
        if (_procList == null) return;
        _procList.Children.Clear();
        foreach (var p in A.FilteredProcesses.Take(250)) _procList.Children.Add(ProcRow(p));
    }

    private UIElement ProcRow(ServerProcess? p)
    {
        TextBlock T(string s, Brush? fg = null, bool right = false, bool trim = false)
        {
            var t = p == null ? Ui.Text(s, 10.5, FontWeights.SemiBold, Theme.Text2) : Ui.Text(s, 12, fg: fg);
            if (p != null) t.FontFamily = Theme.MonoFont;
            if (right) t.TextAlignment = TextAlignment.Right;
            if (trim) t.TextTrimming = TextTrimming.CharacterEllipsis;
            t.VerticalAlignment = VerticalAlignment.Center;
            return t;
        }
        UIElement actions = new Border();
        if (p != null)
        {
            if (A.Busy.Contains($"pid:{p.Pid}")) actions = new ProgressRing { Width = 14, Height = 14, IsActive = true };
            else
            {
                var stop = Ui.IconBtn("", L.T("Hentikan (SIGTERM)"), () => ConfirmKill(p, false), size: 11);
                var kill = Ui.IconBtn(G.Close, L.T("Hentikan paksa (kill -9)"), () => ConfirmKill(p, true), Theme.Brush(Theme.Red), 11);
                actions = Ui.Row(2, stop, kill);
                actions.Opacity = 0;
            }
        }
        var cpuFg = p == null ? null : p.CpuPercent >= 50 ? Theme.Brush(Theme.Red) : p.CpuPercent >= 15 ? Theme.Brush(Theme.Orange) : null;
        var g = Ui.Columns("56,90,64,80,86,*,70", 10,
            T(p == null ? "PID" : p.Pid.ToString(), p == null ? null : Theme.Text2, true),
            T(p == null ? "USER" : p.User, trim: true),
            T(p == null ? "CPU" : $"{p.CpuPercent:0.0}%", cpuFg, true),
            T(p == null ? L.T("MEMORI") : Ui.Bytes(p.RssBytes), right: true),
            T(p == null ? L.T("WAKTU") : p.Elapsed, p == null ? null : Theme.Text2, true),
            T(p == null ? L.T("PERINTAH") : p.Command, trim: true),
            actions);
        var row = new Border { Child = g, Padding = new Thickness(12, p == null ? 8 : 4, 12, p == null ? 8 : 4), MinHeight = p == null ? 0 : 32, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        if (p != null)
        {
            ToolTipService.SetToolTip(row, p.Command);
            row.PointerEntered += (_, _) => { row.Background = Theme.Ink(0.05); actions.Opacity = 1; };
            row.PointerExited += (_, _) => { row.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); actions.Opacity = 0; };
        }
        return row;
    }

    private async void ConfirmKill(ServerProcess p, bool force)
    {
        var d = Ui.Dialog(force ? L.T("Hentikan paksa proses {}?", p.Pid) : L.T("Hentikan proses {}?", p.Pid),
            Ui.Col(8, Ui.Text(p.Command, 12, wrap: true).With(t => t.FontFamily = Theme.MonoFont),
                Ui.Secondary(force ? L.T("SIGKILL: proses langsung dimatikan tanpa sempat menyimpan data.") : L.T("SIGTERM: proses diminta berhenti dengan rapi."), 12.5, true)),
            force ? "Kill -9" : L.T("Hentikan"));
        d.PrimaryButtonStyle = Ui.DangerStyle();
        if (await d.ShowAsync() == ContentDialogResult.Primary) await A.Kill(p, force);
    }

    // MARK: Service

    private UIElement ServicesView()
    {
        if (A.System?.Systemd != true) return Ui.EmptyState(G.Settings, L.T("Tanpa systemd"), L.T("Server ini tidak memakai systemd, jadi daftar service tidak tersedia."));
        _svcList = Ui.Col(4);
        var filter = Ui.Segmented([L.T("Semua"), L.T("Berjalan"), L.T("Gagal"), L.T("Saat boot")], (int)A.Filter, i => { A.Filter = (AdminModel.SvcFilter)i; Render(); });
        filter.Width = 340;
        var left = Ui.Rows("Auto,*", 10, Ui.Columns("Auto,*", 10, filter, Detach(_svcSearch)), new ScrollViewer { Content = _svcList });
        RenderSvcList();
        if (A.SelectedService is { } name && A.Services.FirstOrDefault(s => s.Name == name) is { } svc)
        {
            var detail = ServiceDetail(svc);
            detail.Width = 420;
            return Ui.Columns("*,Auto", 16, left, detail);
        }
        return left;
    }

    private static string SvcColor(ServiceUnit s) => s.Active switch
    {
        "active" => s.Sub == "running" ? Theme.Green : Theme.Accent2,
        "failed" => Theme.Red,
        "activating" or "deactivating" or "reloading" => Theme.Orange,
        _ => "#6B7280",
    };

    private void RenderSvcList()
    {
        if (_svcList == null) return;
        _svcList.Children.Clear();
        foreach (var s in A.FilteredServices)
        {
            var selected = A.SelectedService == s.Name;
            var text = Ui.Col(1, Ui.Text(s.Name, 12.5, FontWeights.SemiBold).With(t => { t.FontFamily = Theme.MonoFont; t.TextTrimming = TextTrimming.CharacterEllipsis; }),
                s.Description.Length > 0 ? Ui.Text(s.Description, 11, fg: Theme.Text2).With(t => t.TextTrimming = TextTrimming.CharacterEllipsis) : null);
            var row = Ui.Columns("Auto,*,Auto,Auto", 10,
                new Ellipse { Width = 8, Height = 8, Fill = Theme.Brush(SvcColor(s)), VerticalAlignment = VerticalAlignment.Center },
                text,
                s.Enabled == "enabled" ? Ui.Badge("BOOT", Theme.Accent2) : null,
                Ui.Text(s.Active == "active" ? s.Sub : s.Active, 11, fg: Theme.Brush(SvcColor(s))).With(t => t.VerticalAlignment = VerticalAlignment.Center));
            var card = new Border
            {
                Child = row, Padding = new Thickness(12, 8, 12, 8), CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1),
                Background = selected ? Theme.Brush(Theme.Accent, 0.12) : Theme.Card, BorderBrush = selected ? Theme.Brush(Theme.Accent, 0.5) : Theme.CardStroke,
            };
            var name = s.Name;
            var b = Ui.Plain(card, () => { A.ChooseService(selected ? null : name); }, new Thickness(0));
            b.HorizontalAlignment = HorizontalAlignment.Stretch;
            b.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            _svcList.Children.Add(b);
        }
    }

    private FrameworkElement ServiceDetail(ServiceUnit s)
    {
        var busy = A.Busy.Contains("svc:" + s.Name);
        var running = s.Active is "active" or "activating";
        Button Act(string title, string glyph, string action, bool primary = false, bool danger = false)
        {
            Action run = () => _ = A.ServiceAction(s.Name, action);
            Action click = action == "stop" && s.Name is "ssh" or "sshd" ? () => ConfirmStopSsh(s.Name) : run;
            var b = primary ? Ui.Primary(title, glyph, click) : Ui.Secondary(title, glyph, click, danger ? Theme.Brush(Theme.Red) : null);
            b.IsEnabled = !busy;
            return b;
        }
        var row1 = running ? Ui.Row(8, Act(L.T("Stop"), G.Stop, "stop", danger: true), Act(L.T("Restart"), G.Refresh, "restart"), Act(L.T("Reload"), G.Sync, "reload"))
                           : Ui.Row(8, Act(L.T("Start"), G.Play, "start", primary: true));
        if (busy) row1.Children.Add(new ProgressRing { Width = 16, Height = 16, IsActive = true });
        var row2 = Ui.Row(8);
        if (s.Enabled == "enabled") row2.Children.Add(Act(L.T("Jangan jalan saat boot"), "", "disable"));
        else if (s.Enabled == "disabled") row2.Children.Add(Act(L.T("Jalankan saat boot"), "", "enable"));
        row2.Children.Add(Ui.Secondary(L.T("Lihat log"), "", () => A.ShowLogs(s.Name)));
        var badges = Ui.Row(6, Ui.Badge(s.Active.ToUpperInvariant(), SvcColor(s)), Ui.Badge(s.Sub.ToUpperInvariant(), "#94A3B8"),
            s.Enabled.Length > 0 ? Ui.Badge(s.Enabled == "enabled" ? L.T("AKTIF SAAT BOOT") : s.Enabled.ToUpperInvariant(), s.Enabled == "enabled" ? Theme.Accent2 : "#94A3B8") : null);
        var status = new Border
        {
            Background = Theme.Brush("#000000", 0.25), CornerRadius = new CornerRadius(8), Padding = new Thickness(10),
            Child = new ScrollViewer
            {
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                Content = new TextBlock { Text = A.ServiceStatus ?? L.T("Memuat…"), FontFamily = Theme.MonoFont, FontSize = 11, IsTextSelectionEnabled = true },
            },
        };
        var head = Ui.Columns("Auto,*,Auto", 8, new Ellipse { Width = 10, Height = 10, Fill = Theme.Brush(SvcColor(s)), VerticalAlignment = VerticalAlignment.Center },
            Ui.Text(s.Name, 15, FontWeights.Bold).With(t => t.FontFamily = Theme.MonoFont), Ui.IconBtn(G.Close, L.T("Tutup"), () => A.ChooseService(null), size: 11));
        var col = Ui.Rows("Auto,Auto,Auto,Auto,Auto,Auto,*", 12, head,
            s.Description.Length > 0 ? Ui.Text(s.Description, 12.5, fg: Theme.Text2, wrap: true) : new Border(),
            badges, row1, row2, Ui.Caps(L.T("Status")), status);
        return new Border { Child = col, Padding = new Thickness(16), CornerRadius = new CornerRadius(14), Background = Theme.Card, BorderBrush = Theme.CardStroke, BorderThickness = new Thickness(1) };
    }

    private async void ConfirmStopSsh(string name)
    {
        var d = Ui.Dialog(L.T("Hentikan {}?", name), Ui.Secondary(L.T("Ini service SSH. Bila dihentikan, kamu bisa tidak bisa login lagi ke server ini sampai dinyalakan dari konsol."), 13, true), L.T("Hentikan"));
        d.PrimaryButtonStyle = Ui.DangerStyle();
        if (await d.ShowAsync() == ContentDialogResult.Primary) await A.ServiceAction(name, "stop");
    }

    // MARK: Cron

    private UIElement CronView()
    {
        if (A.System?.Crontab != true) return Ui.EmptyState("", L.T("crontab tidak tersedia"), L.T("Pasang paket cron di server ini (mis. apt install cron) untuk memakai jadwal."));
        var head = Ui.Columns("Auto,Auto,*,Auto", 10, Ui.Text(L.T("Jadwal milik user {}", A.System?.User), 13, fg: Theme.Text2),
            A.Busy.Contains("cron") ? new ProgressRing { Width = 14, Height = 14, IsActive = true } : null, new Border(),
            Ui.Primary(L.T("Tambah jadwal"), G.Add, () => EditJob(null, new CronJob("0 2 * * *", "", true))));
        var list = Ui.Col(8);
        var jobs = A.Jobs.ToList();
        if (A.CronLoaded && jobs.Count == 0)
            list.Children.Add(Ui.EmptyState("", L.T("Belum ada jadwal"), L.T("Tambahkan jadwal untuk menjalankan perintah otomatis, mis. backup tiap malam.")));
        foreach (var (i, j) in jobs)
        {
            var toggle = new ToggleSwitch { IsOn = j.Enabled, OnContent = "", OffContent = "", MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
            var idx = i;
            toggle.Toggled += (_, _) => { if (toggle.IsOn != j.Enabled) _ = A.SetJob(idx, j with { Enabled = toggle.IsOn }); };
            ToolTipService.SetToolTip(toggle, j.Enabled ? L.T("Nonaktifkan (baris dijadikan komentar)") : L.T("Aktifkan"));
            var text = Ui.Col(3,
                Ui.Row(8, Ui.Text(L.Msg(ZtermCoreMethods.CronDescribe(j.Schedule)), 13, FontWeights.SemiBold), Ui.Text(j.Schedule, 11, fg: Theme.Text2).With(t => t.FontFamily = Theme.MonoFont)),
                Ui.Text(j.Command, 12, fg: j.Enabled ? Theme.Text : Theme.Text2).With(t => { t.FontFamily = Theme.MonoFont; t.TextWrapping = TextWrapping.Wrap; t.MaxLines = 2; t.IsTextSelectionEnabled = true; }));
            var edit = Ui.IconBtn(G.Edit, L.T("Ubah"), () => EditJob(idx, j), size: 12);
            var del = Ui.IconBtn(G.Delete, L.T("Hapus"), () => ConfirmDeleteJob(idx, j), Theme.Brush(Theme.Red), 12);
            var row = Ui.Columns("Auto,*,Auto,Auto", 12, toggle, text, edit, del);
            var card = Ui.Card(row, 12, 12);
            card.Opacity = j.Enabled ? 1 : 0.65;
            list.Children.Add(card);
        }
        return Ui.Rows("Auto,*", 12, head, new ScrollViewer { Content = list });
    }

    private async void ConfirmDeleteJob(int index, CronJob j)
    {
        var d = Ui.Dialog(L.T("Hapus jadwal ini?"), Ui.Text(j.Command, 12, wrap: true).With(t => t.FontFamily = Theme.MonoFont), L.T("Hapus"));
        d.PrimaryButtonStyle = Ui.DangerStyle();
        if (await d.ShowAsync() == ContentDialogResult.Primary) await A.DeleteJob(index);
    }

    private static readonly (string Label, string Schedule)[] Presets =
    [
        ("Tiap menit", "* * * * *"), ("Tiap 5 menit", "*/5 * * * *"), ("Tiap 15 menit", "*/15 * * * *"),
        ("Tiap jam", "0 * * * *"), ("Tiap hari 02.00", "0 2 * * *"), ("Senin–Jumat 08.00", "0 8 * * 1-5"),
        ("Tiap Minggu", "0 3 * * 0"), ("Tiap tanggal 1", "0 3 1 * *"), ("Saat server menyala", "@reboot"),
    ];

    private async void EditJob(int? index, CronJob job)
    {
        var schedule = Ui.Field(L.T("menit jam tanggal bulan hari"), job.Schedule, mono: true);
        var command = Ui.Field(L.T("mis. /usr/local/bin/backup.sh >> /var/log/backup.log 2>&1"), job.Command, mono: true);
        var enabled = new ToggleSwitch { IsOn = job.Enabled, OnContent = L.T("Aktif"), OffContent = L.T("Nonaktif") };
        var hint = Ui.Text("", 12);
        var presets = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 160, ItemHeight = 36 };
        foreach (var (label, sched) in Presets)
        {
            var b = new Button { Content = L.T(label), HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(0, 0, 6, 6), FontSize = 12 };
            b.Click += (_, _) => schedule.Text = sched;
            presets.Children.Add(b);
        }
        var d = Ui.Dialog(index == null ? L.T("Tambah jadwal") : L.T("Ubah jadwal"),
            Ui.Col(8, Ui.Text(L.T("Kapan"), 13, FontWeights.SemiBold), presets, schedule, hint, Ui.Text(L.T("Perintah"), 13, FontWeights.SemiBold).With(t => t.Margin = new Thickness(0, 6, 0, 0)), command, enabled)
                .With(c => c.Width = 520),
            L.T("Simpan"));
        d.Resources["ContentDialogMaxWidth"] = 640.0;
        void Validate()
        {
            var ok = ZtermCoreMethods.CronValid(schedule.Text);
            hint.Text = ok ? L.Msg(ZtermCoreMethods.CronDescribe(schedule.Text)) : L.T("Format: menit jam tanggal bulan hari — mis. 30 2 * * 1-5");
            hint.Foreground = Theme.Brush(ok ? Theme.Accent : Theme.Orange);
            d.IsPrimaryButtonEnabled = ok && command.Text.Trim().Length > 0 && !command.Text.Contains('\n');
        }
        schedule.TextChanged += (_, _) => Validate();
        command.TextChanged += (_, _) => Validate();
        Validate();
        if (await d.ShowAsync() == ContentDialogResult.Primary)
            await A.SetJob(index, new CronJob(schedule.Text.Trim(), command.Text.Trim(), enabled.IsOn));
    }

    // MARK: Log

    private UIElement LogsView()
    {
        if (A.Sources.Length == 0)
            return Ui.Secondary(L.T("Tidak ada journal atau file log umum yang bisa dibaca di server ini."), 13).With(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 40, 0, 0); });
        ComboBox Combo(IEnumerable<(string Label, string Value)> items, string current, Action<string> set, double width)
        {
            var c = new ComboBox { MinWidth = width };
            foreach (var (label, value) in items)
            {
                c.Items.Add(new ComboBoxItem { Content = label, Tag = value });
                if (value == current) c.SelectedIndex = c.Items.Count - 1;
            }
            c.SelectionChanged += (_, _) => { if (c.SelectedItem is ComboBoxItem { Tag: string v } && v != current) { set(v); _ = A.ReloadLog(); } };
            return c;
        }
        var source = Combo(A.Sources.Select(s => (s.IsJournal ? L.Msg(s.Title) : $"{L.Msg(s.Title)}  ·  {Ui.Bytes(s.SizeBytes)}", s.Id)), A.LogSource, v => A.LogSource = v, 300);
        var row1 = Ui.Row(10, source);
        if (A.LogSource == "journal")
        {
            row1.Children.Add(Combo(new[] { (L.T("Semua service"), "") }.Concat(A.Services.Where(s => s.Active is "active" or "failed").Select(s => (s.Name, s.Name))), A.LogUnit, v => A.LogUnit = v, 200));
            row1.Children.Add(Combo([(L.T("Semua level"), ""), (L.T("Warning ke atas"), "warning"), (L.T("Error ke atas"), "err")], A.LogPriority, v => A.LogPriority = v, 150));
        }
        row1.Children.Add(Combo([(L.T("{} baris", 200), "200"), (L.T("{} baris", 500), "500"), (L.T("{} baris", L10n.English ? "2,000" : "2.000"), "2000"), (L.T("{} baris", L10n.English ? "5,000" : "5.000"), "5000")], A.LogLines.ToString(), v => A.LogLines = uint.Parse(v), 120));
        var follow = new ToggleSwitch { IsOn = A.Follow, OnContent = L.T("Ikuti"), OffContent = L.T("Ikuti") };
        follow.Toggled += (_, _) => A.Follow = follow.IsOn;
        ToolTipService.SetToolTip(follow, L.T("Ambil baris baru tiap 2 detik"));
        _logCount = Ui.Text("", 11.5, fg: Theme.Text2).With(t => t.VerticalAlignment = VerticalAlignment.Center);
        var copy = Ui.IconBtn(G.Copy, L.T("Salin"), () => { Ui.CopyText(string.Join("\n", Filtered())); M.Flash(L.T("{} baris log disalin", Filtered().Count())); });
        var row2 = Ui.Columns("Auto,Auto,Auto,*,Auto,Auto", 10, Detach(_logSearch), follow, A.LogViaSudo ? Ui.Badge("SUDO", Theme.Orange) : null, new Border(), _logCount, copy);
        _log = new RichTextBlock { FontFamily = Theme.MonoFont, FontSize = 11.5, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.NoWrap };
        _logScroll = new ScrollViewer { Content = new Border { Padding = new Thickness(10), Child = _log }, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        var box = new Border { Background = Theme.Brush("#000000", 0.3), CornerRadius = new CornerRadius(10), Child = _logScroll };
        RenderLogText(true);
        return Ui.Rows("Auto,Auto,*", 10, row1, row2, box);
    }

    private IEnumerable<string> Filtered()
    {
        var q = A.LogQuery.Trim();
        return q.Length == 0 ? A.LogText : A.LogText.Where(l => l.Contains(q, StringComparison.OrdinalIgnoreCase));
    }

    private static Paragraph Line(string l)
    {
        var s = l.ToLowerInvariant();
        var hex = s.Contains("error") || s.Contains("fail") || s.Contains("crit") || s.Contains("fatal") || s.Contains("panic") || s.Contains("[emerg]") ? Theme.Red
            : s.Contains("warn") ? Theme.Orange : null;
        var run = new Run { Text = l.Length == 0 ? " " : l };
        if (hex != null) run.Foreground = Theme.Brush(hex);
        var p = new Paragraph();
        p.Inlines.Add(run);
        return p;
    }

    private void RenderLogText(bool full)
    {
        if (_log == null) return;
        var q = A.LogQuery.Trim();
        if (full || q.Length > 0 || A.Appended > 2000)
        {
            _log.Blocks.Clear();
            foreach (var l in Filtered()) _log.Blocks.Add(Line(l));
        }
        else
        {
            foreach (var l in A.LogText.Skip(Math.Max(0, A.LogText.Count - A.Appended))) _log.Blocks.Add(Line(l));
        }
        A.Appended = 0;
        if (_logCount != null)
        {
            var n = Filtered().Count();
            _logCount.Text = q.Length == 0 ? L.T("{} baris", n) : L.T("{} dari {} baris", n, A.LogText.Count);
        }
        if (A.Follow && _logScroll != null)
            _logScroll.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => _logScroll.ChangeView(null, _logScroll.ScrollableHeight, null, true));
    }
}
