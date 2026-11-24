using System;
using Microsoft.UI.Dispatching;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Zterm;

/// <summary>Notifikasi Windows untuk peringatan Dashboard (server mati, CPU/RAM/disk di atas 90%). Klik → buka Dashboard.</summary>
internal static class Notifier
{
    private static bool _registered;

    public static void Install(DispatcherQueue dq)
    {
        try
        {
            AppNotificationManager.Default.NotificationInvoked += (_, _) => dq.TryEnqueue(() =>
            {
                App.Window?.BringToFront();
                if (App.Model.Phase == Phase.Main) App.Model.Navigate(Section.Dashboard);
            });
            AppNotificationManager.Default.Register();
            _registered = true;
        }
        catch { }
    }

    /// <summary>False bila notifikasi dimatikan di Settings Windows (Sistem → Notifikasi).</summary>
    public static bool Allowed
    {
        get
        {
            if (!_registered) return false;
            try { return AppNotificationManager.Default.Setting == AppNotificationSetting.Enabled; } catch { return false; }
        }
    }

    /// <summary><paramref name="key"/> mengelompokkan notifikasi yang sama (yang baru menggantikan yang lama).</summary>
    public static void Send(string title, string body, string key)
    {
        if (!_registered) return;
        try
        {
            var n = new AppNotificationBuilder().AddText(title).AddText(body).BuildNotification();
            n.Tag = key.Length > 64 ? key[..64] : key;
            n.Group = "dashboard";
            AppNotificationManager.Default.Show(n);
        }
        catch { }
    }

    public static void Uninstall()
    {
        if (!_registered) return;
        try { AppNotificationManager.Default.Unregister(); } catch { }
    }
}
