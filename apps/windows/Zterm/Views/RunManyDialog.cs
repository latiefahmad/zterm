using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;

namespace Zterm.Views;

/// <summary>Dialog "Jalankan perintah di banyak server" — padanan RunManyView.swift.</summary>
internal sealed class RunManyDialog
{
    private readonly AppModel M = App.Model;
    private readonly RunManyModel R;
    private readonly ContentDialog _dialog;
    private readonly TextBox _command;
    private readonly VariableSizedWrapGrid _targets = new() { Orientation = Orientation.Horizontal, ItemWidth = 196, ItemHeight = 38 };
    private readonly TextBlock _targetsTitle = Ui.Caps("");
    private readonly StackPanel _results = Ui.Col(6);
    private readonly StackPanel _summary = Ui.Row(14);
    private readonly ScrollViewer _targetsScroll;
    private readonly StackPanel _resultsBox;

    public RunManyDialog(RunManyModel run)
    {
        R = run;
        _command = new TextBox
        {
            AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 80, FontFamily = Theme.MonoFont, FontSize = 12.5,
            PlaceholderText = L.T("mis. df -h /   ·   uptime   ·   apt list --upgradable 2>/dev/null | wc -l"),
        };
        _command.Text = R.Command;
        _command.TextChanged += (_, _) => { R.Command = _command.Text; UpdateButtons(); };

        var timeout = new ComboBox { MinWidth = 120 };
        foreach (var (label, secs) in new[] { (L.T("{} detik", 30), 30u), (L.T("{} menit", 2), 120u), (L.T("{} menit", 10), 600u), (L.T("{} menit", 30), 1800u) })
        {
            timeout.Items.Add(new ComboBoxItem { Content = label, Tag = secs });
            if (secs == R.Timeout) timeout.SelectedIndex = timeout.Items.Count - 1;
        }
        timeout.SelectionChanged += (_, _) => { if (timeout.SelectedItem is ComboBoxItem { Tag: uint s }) R.Timeout = s; };
        ToolTipService.SetToolTip(timeout, L.T("Batas waktu per server"));

        UIElement? snippets = null;
        if (M.Snippets.Length > 0)
        {
            var menu = new MenuFlyout();
            foreach (var s in M.Snippets)
            {
                var it = new MenuFlyoutItem { Text = s.Label };
                it.Click += (_, _) => _command.Text = s.Command;
                menu.Items.Add(it);
            }
            snippets = new DropDownButton { Content = Ui.Row(6, Ui.Icon(G.Code, 12), Ui.Text(L.T("Snippet"), 12.5)), Flyout = menu };
        }

        var editor = Ui.Col(8,
            Ui.Columns("*,Auto,Auto", 10, Ui.Caps(L.T("Perintah")), snippets, timeout),
            _command,
            Ui.Row(6, Ui.Icon(G.Info, 11, Theme.Text2),
                Ui.Text(L.T("Berjalan tanpa terminal interaktif. Perintah yang menunggu input (mis. sudo dengan password) berhenti di batas waktu — pakai user root atau sudo -n."),
                    11.5, fg: Theme.Text2, wrap: true)));

        Button Link(string text, Action a) => Ui.Plain(Ui.Text(text, 12.5, fg: Theme.Brush(Theme.Accent)), () => { a(); RenderTargets(); }, new Thickness(6, 3, 6, 3));
        var targetHead = Ui.Columns("*,Auto,Auto,Auto", 4, _targetsTitle,
            Link(L.T("Semua"), () => { R.Targets.Clear(); R.Targets.UnionWith(M.Hosts.Select(h => h.Id)); }),
            Link(L.T("Hanya online"), () => { R.Targets.Clear(); R.Targets.UnionWith(M.Dashboard.Tiles.Values.Where(t => t.State == ServerTile.Status.Online).Select(t => t.Id)); }),
            Link(L.T("Kosongkan"), () => R.Targets.Clear()));
        _targetsScroll = new ScrollViewer { Content = _targets, MaxHeight = 170 };

        var copy = Ui.Plain(Ui.Row(6, Ui.Icon(G.Copy, 12, Theme.Text2), Ui.Text(L.T("Salin semua"), 12.5, fg: Theme.Text2)),
            () => { Ui.CopyText(R.Report()); M.Flash(L.T("Output semua server disalin")); }, new Thickness(6, 3, 6, 3));
        _resultsBox = Ui.Col(8, Ui.Columns("Auto,*,Auto", 14, Ui.Caps(L.T("Hasil")), _summary, copy),
            new ScrollViewer { Content = _results, MaxHeight = 360 });

        var body = Ui.Col(16, Ui.Secondary(L.T("Satu perintah di banyak server sekaligus — hasilnya per server"), 13), editor, Ui.Col(8, targetHead, _targetsScroll), _resultsBox);
        body.Width = 820;

        _dialog = Ui.Dialog(L.T("Jalankan perintah"), new ScrollViewer { Content = body }, L.T("Jalankan"), L.T("Tutup"));
        _dialog.Resources["ContentDialogMaxWidth"] = 900.0;
        _dialog.PrimaryButtonClick += (_, e) => { e.Cancel = true; R.Run(); };
        _dialog.SecondaryButtonClick += (_, e) =>
        {
            e.Cancel = true;
            if (R.Running) R.Cancel();
            else R.Run(R.Rows.Where(r => r.Done && !r.Success).Select(r => r.Id).ToList());
        };
        _dialog.Closed += (_, _) => { R.Cancel(); R.Changed -= Render; };
        R.Changed += Render;
        RenderTargets();
        Render();
    }

    public async void Show() => await _dialog.ShowAsync();

    private void UpdateButtons()
    {
        _dialog.PrimaryButtonText = R.Running ? L.T("Menjalankan…") : L.T("Jalankan di {} server", R.Targets.Count);
        _dialog.IsPrimaryButtonEnabled = !R.Running && R.Targets.Count > 0 && R.Command.Trim().Length > 0;
        _dialog.SecondaryButtonText = R.Running ? L.T("Batalkan") : R.FailCount > 0 ? L.T("Ulangi yang gagal") : "";
    }

    private void RenderTargets()
    {
        _targetsTitle.Text = L.T("SERVER · {} DIPILIH", R.Targets.Count);
        _targets.Children.Clear();
        foreach (var h in M.Hosts)
        {
            var on = R.Targets.Contains(h.Id);
            var tile = M.Dashboard.Tiles.GetValueOrDefault(h.Id);
            UIElement? dot = tile?.State == ServerTile.Status.Online ? Dot(Theme.Green) : tile?.State == ServerTile.Status.Offline ? Dot(Theme.Red) : null;
            var content = Ui.Columns("Auto,Auto,*,Auto", 7,
                Ui.Icon(on ? G.Check : "", 12, on ? Theme.Brush(Theme.Accent) : Theme.Text2),
                Dot(h.Color),
                Ui.Text(h.Title(), 12.5).With(t => t.TextTrimming = TextTrimming.CharacterEllipsis),
                dot);
            var chip = new Border
            {
                Child = content, Padding = new Thickness(10, 7, 10, 7), CornerRadius = new CornerRadius(9), Margin = new Thickness(0, 0, 8, 8),
                Background = on ? Theme.Brush(Theme.Accent, 0.12) : Theme.Ink(0.05),
                BorderThickness = new Thickness(1), BorderBrush = on ? Theme.Brush(Theme.Accent, 0.5) : Theme.Ink(0),
            };
            var id = h.Id;
            var b = Ui.Plain(chip, () =>
            {
                if (R.Running) return;
                if (!R.Targets.Remove(id)) R.Targets.Add(id);
                RenderTargets();
            }, new Thickness(0));
            b.HorizontalAlignment = HorizontalAlignment.Stretch;
            b.HorizontalContentAlignment = HorizontalAlignment.Stretch;
            _targets.Children.Add(b);
        }
        UpdateButtons();
    }

    private static Ellipse Dot(string hex) => new() { Width = 7, Height = 7, Fill = Theme.Brush(hex), VerticalAlignment = VerticalAlignment.Center };

    private void Render()
    {
        UpdateButtons();
        _resultsBox.Visibility = R.Rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        _targetsScroll.MaxHeight = R.Rows.Count == 0 ? 170 : 84;
        _summary.Children.Clear();
        _summary.Children.Add(Count(G.Check, L.T("{} sukses", R.OkCount), Theme.Green));
        _summary.Children.Add(Count(G.Close, L.T("{} gagal", R.FailCount), Theme.Red));
        if (R.PendingCount > 0) _summary.Children.Add(Count(G.Clock, L.T("{} berjalan", R.PendingCount), "#94A3B8"));
        _results.Children.Clear();
        foreach (var row in R.Rows) _results.Children.Add(ResultRow(row));
    }

    private static UIElement Count(string glyph, string text, string hex) =>
        Ui.Row(4, Ui.Icon(glyph, 11, Theme.Brush(hex)), Ui.Text(text, 12, FontWeights.Medium));

    private UIElement ResultRow(RunManyModel.Row row)
    {
        var host = M.HostById(row.Id);
        var open = R.Expanded.Contains(row.Id);
        var tint = row.State switch
        {
            RunManyModel.Status.Ok => Theme.Green,
            RunManyModel.Status.Timeout => Theme.Orange,
            RunManyModel.Status.Failed or RunManyModel.Status.Error => Theme.Red,
            _ => "#94A3B8",
        };
        UIElement icon = row.State == RunManyModel.Status.Running
            ? new ProgressRing { Width = 14, Height = 14, IsActive = true }
            : Ui.Icon(row.State switch
            {
                RunManyModel.Status.Ok => G.Check,
                RunManyModel.Status.Waiting => G.Clock,
                RunManyModel.Status.Timeout => G.Clock,
                _ => G.Close,
            }, 12, Theme.Brush(tint));
        var last = row.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        var duration = row.Done && row.DurationMs > 0 ? (row.DurationMs < 1000 ? $"{row.DurationMs} ms" : L.T("{} dtk", (row.DurationMs / 1000.0).ToString("0.0"))) : "";
        var head = Ui.Columns("Auto,Auto,Auto,Auto,*,Auto,Auto", 9, icon, Dot(host?.Color ?? "#94A3B8"),
            Ui.Text(host?.Title() ?? row.Id, 12.5, FontWeights.SemiBold),
            Ui.Text(RunManyModel.Label(row), 11.5, fg: Theme.Brush(tint)),
            Ui.Text(open ? "" : last, 11.5, fg: Theme.Text2).With(t => { t.FontFamily = Theme.MonoFont; t.TextTrimming = TextTrimming.CharacterEllipsis; }),
            Ui.Text(duration, 11, fg: Theme.Text2).With(t => t.FontFamily = Theme.MonoFont),
            Ui.Icon(open ? G.ChevronDown : G.ChevronRight, 10, Theme.Text2));
        var toggle = Ui.Plain(head, () => { if (!R.Expanded.Remove(row.Id)) R.Expanded.Add(row.Id); Render(); }, new Thickness(0));
        toggle.HorizontalAlignment = HorizontalAlignment.Stretch;
        toggle.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        var col = Ui.Col(8, toggle);
        if (open)
        {
            var text = row.Output.Length == 0 ? (row.Done ? L.T("(tidak ada output)") : "…") : row.Output + (row.Truncated ? "\n" + L.T("… (output dipotong di 256 KB)") : "");
            col.Children.Add(new Border
            {
                Background = Theme.Brush("#000000", 0.25), CornerRadius = new CornerRadius(8), Padding = new Thickness(10),
                Child = new ScrollViewer
                {
                    MaxHeight = 200, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                    Content = new TextBlock { Text = text, FontFamily = Theme.MonoFont, FontSize = 11.5, IsTextSelectionEnabled = true },
                },
            });
        }
        return new Border { Child = col, Padding = new Thickness(10), CornerRadius = new CornerRadius(10), Background = Theme.Ink(0.04) };
    }
}
