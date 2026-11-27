using System;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Zterm.Views;

/// <summary>Dialog dan elemen progress yang dipakai kartu sidebar serta halaman Tentang.</summary>
internal static class UpdateUI
{
    public static async Task StartAsync(AppModel model, AvailableUpdate update)
    {
        if (model.UpdateBusy) return;
        if (update.Download == null)
        {
            model.Flash(L.T("Pembaruan tidak tersedia untuk arsitektur ini"));
            Ui.Open(update.Page);
            return;
        }

        var content = Ui.Col(10,
            Ui.Secondary(L.T("Zterm akan mengunduh pembaruan, menutup aplikasi, lalu membuka ulang."), 13, true),
            Ui.Secondary(L.T("Kamu memakai {}.", Config.Version), 12, true));
        content.MaxWidth = 440;

        try
        {
            var dialog = Ui.Dialog(L.T("Update Zterm ke {}?", update.Version), content,
                L.T("Update sekarang"), L.T("Nanti"));
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        }
        catch (Exception e)
        {
            UpdateLog.Write("Dialog update gagal: " + e);
            return;
        }
        await model.InstallUpdateAsync();
    }
}

/// <summary>
/// Bilah progress yang bergerak halus menuju nilai terakhir. Laporan unduhan datang
/// ~12 kali/detik; timer 60 fps meredam lompatan supaya tidak terlihat patah-patah.
///
/// Sengaja komposisi (Grid + ProgressBar biasa), bukan subclass ProgressBar: WinUI 3
/// gagal menerapkan style default ProgressBar ke subclass managed dan melempar
/// COMException 0x800F1000 sebelum unduhan sempat dimulai.
/// </summary>
internal sealed class UpdateBar : Grid
{
    private readonly ProgressBar _bar;
    private readonly DispatcherQueueTimer _timer;
    private double _target;

    public UpdateBar(double fraction)
    {
        _bar = new ProgressBar
        {
            Minimum = 0,
            Maximum = 100,
            Height = 4,
            CornerRadius = new CornerRadius(2),
            Foreground = Theme.AccentBrush,
            Background = Theme.Ink(0.08),
            VerticalAlignment = VerticalAlignment.Center,
        };

        var shown = Math.Clamp(fraction, 0, 1) * 100;
        _bar.Value = shown;
        _target = shown;
        Children.Add(_bar);

        _timer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(16);
        _timer.IsRepeating = true;
        _timer.Tick += (_, _) => Step();
        Unloaded += (_, _) => _timer.Stop();
    }

    public void SetTarget(double fraction)
    {
        _target = Math.Clamp(fraction, 0, 1) * 100;
        if (!_timer.IsRunning) _timer.Start();
    }

    private void Step()
    {
        var diff = _target - _bar.Value;
        if (Math.Abs(diff) <= 0.1)
        {
            _bar.Value = _target;
            _timer.Stop();
            return;
        }
        _bar.Value += diff * 0.2;
    }
}
