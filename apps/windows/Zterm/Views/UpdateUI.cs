using System;
using System.Threading.Tasks;
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

        var dialog = Ui.Dialog(L.T("Update Zterm ke {}?", update.Version), content,
            L.T("Update sekarang"), L.T("Nanti"));
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        await model.InstallUpdateAsync();
    }

    public static ProgressBar Bar(AppModel model) => new()
    {
        Minimum = 0, Maximum = 100,
        Value = Math.Clamp(model.UpdateProgress, 0, 1) * 100,
        Height = 4, CornerRadius = new CornerRadius(2),
        Foreground = Theme.BrandGradient, Background = Theme.Ink(0.08),
    };
}
