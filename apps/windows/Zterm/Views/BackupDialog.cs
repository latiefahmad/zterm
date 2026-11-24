using System;
using System.Linq;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using uniffi.zterm_core;

namespace Zterm.Views;

/// <summary>Dialog Backup & restore satu koneksi database — padanan BackupSheet di BackupView.swift.</summary>
internal sealed class BackupDialog
{
    private readonly AppModel M = App.Model;
    private BackupModel B => M.Backups;
    private readonly DbConnection _db;
    private readonly ContentDialog _dialog;
    private readonly StackPanel _now = Ui.Col(0);
    private readonly StackPanel _sched = Ui.Col(10);
    private readonly StackPanel _list = Ui.Col(6);
    private readonly TextBlock _listTitle = Ui.Caps("");

    public BackupDialog(DbConnection db)
    {
        _db = db;
        var sub = db.SshHostId != null ? L.T("Dump dijalankan di server lewat SSH, hasilnya disimpan di PC ini") : L.T("Memakai alat dump di PC ini (termasuk komponen Server Lokal)");
        var body = Ui.Col(16, Ui.Secondary(sub, 12.5, true), _now, Ui.Caps(L.T("Jadwal otomatis")), _sched, _listTitle,
            new ScrollViewer { Content = _list, MaxHeight = 240 });
        body.Width = 560;
        _dialog = Ui.Dialog(L.T("Backup · {}", db.Title()), body, null, L.T("Selesai"));
        _dialog.Resources["ContentDialogMaxWidth"] = 700.0;
        void Changed(string what) { if (what is "backup" or "backup.progress") Render(what == "backup"); }
        M.Changed += Changed;
        _dialog.Closed += (_, _) => M.Changed -= Changed;
        Render(true);
    }

    public async void Show() => await _dialog.ShowAsync();

    private void Render(bool full)
    {
        RenderNow();
        if (!full) return;
        RenderSchedule();
        RenderList();
    }

    private void RenderNow()
    {
        _now.Children.Clear();
        UIElement content;
        if (B.Jobs.TryGetValue(_db.Id, out var j))
        {
            var done = Ui.Bytes(j.Bytes);
            var detail = j.Total > 0 ? $"{done} / {Ui.Bytes(j.Total)}" : j.Restore ? L.T("{} dikirim", done) : L.T("{} data", done);
            content = Ui.Columns("Auto,*,Auto", 10, new ProgressRing { Width = 18, Height = 18, IsActive = true },
                Ui.Col(2, Ui.Text(j.Stage, 13, FontWeights.Medium), Ui.Text(detail, 11.5, fg: Theme.Text2)),
                Ui.Secondary(L.T("Batalkan"), null, () => B.Cancel(_db.Id)));
        }
        else
        {
            var folder = Ui.Secondary(L.T("Buka folder"), G.Folder, () => { System.IO.Directory.CreateDirectory(BackupModel.Folder(_db)); Ui.Open(BackupModel.Folder(_db)); });
            content = Ui.Row(10, Ui.Primary(L.T("Backup sekarang"), G.Download, () => _ = B.Backup(_db)), folder);
        }
        _now.Children.Add(new Border { Child = content, Padding = new Thickness(12), CornerRadius = new CornerRadius(12), Background = Theme.Ink(0.04) });
    }

    private void RenderSchedule()
    {
        _sched.Children.Clear();
        var s = B.Schedule(_db.Id);
        var freqs = new[] { ("off", L.T("Mati")), ("daily", L.T("Tiap hari")), ("weekly", L.T("Tiap minggu")) };
        var seg = Ui.Segmented(freqs.Select(f => f.Item2).ToArray(), Array.FindIndex(freqs, f => f.Item1 == s.Frequency) is var i and >= 0 ? i : 0,
            k => { s.Frequency = freqs[k].Item1; B.SetSchedule(_db.Id, s); });
        seg.Width = 300;
        var row = Ui.Row(12, seg);
        if (s.Frequency != "off")
        {
            var hour = new ComboBox { MinWidth = 100 };
            for (int h = 0; h < 24; h++) hour.Items.Add(L10n.English ? $"{h:00}:00" : $"pukul {h:00}.00");
            hour.SelectedIndex = s.Hour;
            hour.SelectionChanged += (_, _) => { if (hour.SelectedIndex >= 0 && hour.SelectedIndex != s.Hour) { s.Hour = hour.SelectedIndex; B.SetSchedule(_db.Id, s); } };
            var keep = new NumberBox { Value = s.Keep, Minimum = 1, Maximum = 60, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, Width = 110, Header = null };
            keep.ValueChanged += (_, e) => { if (!double.IsNaN(e.NewValue) && (int)e.NewValue != s.Keep) { s.Keep = (int)e.NewValue; B.SetSchedule(_db.Id, s); } };
            row.Children.Add(hour);
            row.Children.Add(Ui.Row(6, Ui.Text(L10n.English ? "Keep" : "Simpan", 12.5, fg: Theme.Text2).With(t => t.VerticalAlignment = VerticalAlignment.Center), keep,
                Ui.Text(L.T("terakhir"), 12.5, fg: Theme.Text2).With(t => t.VerticalAlignment = VerticalAlignment.Center)));
        }
        _sched.Children.Add(row);
        var drive = new CheckBox { Content = L.T("Unggah juga ke Google Drive (folder “Zterm Backups”)"), IsChecked = s.Drive, IsEnabled = M.TeamReady };
        drive.Click += (_, _) => { s.Drive = drive.IsChecked == true; B.SetSchedule(_db.Id, s); };
        if (!M.TeamReady) ToolTipService.SetToolTip(drive, L.T("Masuk dengan Google dan izinkan akses Google Drive di menu Akun"));
        _sched.Children.Add(drive);
        if (s.Frequency != "off")
            _sched.Children.Add(Ui.Text(L.T("Berjalan selama Zterm terbuka. Bila PC mati saat jadwal tiba, backup dibuat begitu app dibuka lagi."), 11.5, fg: Theme.Text2, wrap: true));
        if (s.LastError is { } e) _sched.Children.Add(Ui.Text(L.T("Backup terakhir gagal: {}", e), 11.5, fg: Theme.Brush(Theme.Red), wrap: true));
        else if (s.Last is { } last) _sched.Children.Add(Ui.Text(L.T("Backup terakhir: {}", last.LocalDateTime.ToString("dd MMM yyyy HH.mm")), 11.5, fg: Theme.Text2));
    }

    private void RenderList()
    {
        var items = B.Items(_db);
        _listTitle.Text = L.T("BACKUP TERSIMPAN · {}", items.Count);
        _list.Children.Clear();
        if (items.Count == 0) { _list.Children.Add(Ui.Text(L.T("Belum ada backup."), 12.5, fg: Theme.Text2)); return; }
        var busy = B.Jobs.ContainsKey(_db.Id);
        foreach (var item in items)
        {
            var restore = Ui.Secondary(L.T("Pulihkan"), null, () => ConfirmRestore(item));
            restore.IsEnabled = !busy;
            var row = Ui.Columns("Auto,*,Auto,Auto,Auto,Auto", 10,
                Ui.Icon(G.Document, 14, Theme.Brush(Theme.Accent)),
                Ui.Col(1, Ui.Text($"{item.Date:dd MMM yyyy HH.mm}", 12.5, FontWeights.SemiBold), Ui.Text(item.Name, 11, fg: Theme.Text2).With(t => { t.FontFamily = Theme.MonoFont; t.TextTrimming = TextTrimming.CharacterEllipsis; })),
                Ui.Text(Ui.Bytes((ulong)item.Size), 11.5, fg: Theme.Text2).With(t => t.VerticalAlignment = VerticalAlignment.Center),
                restore,
                Ui.IconBtn(G.Folder, L.T("Tampilkan di Explorer"), () => System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{item.Path}\""), size: 12),
                Ui.IconBtn(G.Delete, L.T("Hapus"), () => B.Delete(item), Theme.Brush(Theme.Red), 12));
            _list.Children.Add(new Border { Child = row, Padding = new Thickness(10), CornerRadius = new CornerRadius(10), Background = Theme.Ink(0.04) });
        }
    }

    private void ConfirmRestore(BackupModel.Item item)
    {
        // ContentDialog tidak bisa bertumpuk: ganti isi dialog ini dengan konfirmasi
        var old = _dialog.Content;
        var back = Ui.Secondary(L.T("Batal"), null, () => _dialog.Content = old);
        var go = Ui.Primary(L.T("Pulihkan (timpa data)"), null, () => { _dialog.Content = old; _ = B.Restore(_db, item); });
        go.Style = Ui.DangerStyle();
        _dialog.Content = Ui.Col(14,
            Ui.Text(L.T("Pulihkan {} dari backup ini?", _db.Title()), 16, FontWeights.SemiBold),
            Ui.Text(item.Name, 12, fg: Theme.Text2).With(t => t.FontFamily = Theme.MonoFont),
            Ui.Text(L.T("Tabel di database akan dihapus & dibuat ulang sesuai isi backup. Data yang belum ada di backup akan hilang. Sebaiknya buat backup baru dulu."), 13, wrap: true),
            Ui.Row(10, go, back)).With(c => c.Width = 560);
    }
}
