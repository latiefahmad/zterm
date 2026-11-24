using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using uniffi.zterm_core;

namespace Zterm.Views;

/// <summary>Aturan port forwarding (-L / -R / -D) yang bisa dinyalakan dengan satu saklar.</summary>
internal sealed class ForwardingPage : PageBase
{
    private readonly StackPanel _list = Ui.Col(10);

    public ForwardingPage() : base("data", "tunnels")
    {
        var add = Ui.Primary(L.T("Aturan Baru"), G.Add, () => _ = Editor(HostExt.BlankForward(M.Hosts.FirstOrDefault()?.Id ?? "")));
        add.IsEnabled = M.Hosts.Length > 0;
        var header = Ui.Header(L.T("Port Forwarding"), L.T("Teruskan port lewat SSH — buka database, dashboard, atau proxy SOCKS dengan aman."), add);
        Children.Add(Ui.Scroll(Ui.Col(22, header, _list)));
        Render();
    }

    protected override void Render()
    {
        _list.Children.Clear();
        if (M.Forwards.Length == 0)
        {
            _list.Children.Add(Ui.EmptyState(G.Forward, L.T("Belum ada aturan"),
                M.Hosts.Length == 0 ? L.T("Tambahkan host dulu, lalu buat aturan port forwarding.") : L.T("Contoh: teruskan 127.0.0.1:5433 ke database PostgreSQL di server."),
                M.Hosts.Length == 0 ? null : Ui.Primary(L.T("Aturan Baru"), G.Add, () => _ = Editor(HostExt.BlankForward(M.Hosts[0].Id)))));
            return;
        }
        for (int i = 0; i < M.Forwards.Length; i++)
        {
            var row = Row(M.Forwards[i]);
            _list.Children.Add(row);
            Ui.StaggerIn(row, i);
        }
    }

    private FrameworkElement Row(PortForward f)
    {
        var host = M.HostById(f.HostId);
        var st = M.Tunnels.StatusOf(f.Id);
        var running = M.Tunnels.IsRunning(f.Id);
        var color = f.Kind switch { ForwardKind.Local => "#10B981", ForwardKind.Remote => "#5B9CF5", _ => "#9D7CF2" };
        var glyph = f.Kind switch { ForwardKind.Local => G.Next, ForwardKind.Remote => G.Back, _ => G.Globe };
        var icon = Ui.TintIcon(glyph, color, 40, 15, 11);
        var summary = Ui.Text(f.Summary(host?.Title() ?? L.T("host terhapus"), M.HideAddresses), 12, fg: Theme.Text2, mono: true);
        UIElement? state = st?.State switch
        {
            TunnelManager.State.Starting => Ui.Row(6, new ProgressRing { Width = 12, Height = 12, IsActive = true }, Ui.Text(L.T("Menghubungkan…"), 11.5, fg: Theme.Text2)),
            TunnelManager.State.Running => Ui.Row(6, new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(4), Background = Theme.Brush(Theme.Green) }.With(Ui.Pulse),
                Ui.Text(L.T("Aktif"), 11.5, FontWeights.SemiBold, Theme.Brush(Theme.Green))),
            TunnelManager.State.Failed => Ui.Row(6, Ui.Icon(G.Warning, 12, Theme.Brush(Theme.Orange)), Ui.Text(st.Message is { } sm ? L.Msg(sm) : L.T("Gagal"), 11.5, fg: Theme.Brush(Theme.Orange)).With(t => t.MaxWidth = 420)),
            _ => null,
        };
        var info = Ui.Col(4, Ui.Row(8, Ui.Text(string.IsNullOrEmpty(f.Label) ? f.Kind.Short() : f.Label, 14, FontWeights.SemiBold), Ui.Badge(f.Kind.Short(), color)), summary, state);
        var toggle = new ToggleSwitch { IsOn = running, OnContent = "", OffContent = "", MinWidth = 0 };
        toggle.Toggled += (_, _) => { if (toggle.IsOn != M.Tunnels.IsRunning(f.Id)) M.ToggleTunnel(f); };
        var copy = f.Kind == ForwardKind.Remote ? null : Ui.IconBtn(G.Copy, L.T("Salin alamat lokal"), () => { Ui.CopyText($"{f.BindAddress}:{f.BindPort}"); M.Flash(L.T("Alamat disalin")); });
        var actions = Ui.Row(4, copy, Ui.IconBtn(G.Edit, L.T("Edit"), () => _ = Editor(f)),
            Ui.IconBtn(G.Delete, L.T("Hapus"), async () => { if (await Ui.Confirm(L.T("Hapus aturan ini?"), L.T("Tunnel yang sedang berjalan akan dihentikan."))) M.Delete(f); }, Theme.Brush("#E5484D")),
            toggle);
        return Ui.HoverCard(Ui.Columns("Auto,*,Auto", 14, icon, info, actions), 14);
    }

    private async Task Editor(PortForward original)
    {
        var f = original;
        var label = Ui.Field(L.T("Nama (mis. Postgres produksi)"), f.Label);
        var host = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch, Header = L.T("Lewat host") };
        foreach (var h in M.Hosts) host.Items.Add(new ComboBoxItem { Content = h.Title(), Tag = h.Id });
        host.SelectedItem = host.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == f.HostId) ?? host.Items.FirstOrDefault();
        var kindBox = new Border();
        var explain = Ui.Secondary("", 12, true);
        var bindAddr = Ui.Field(L.T("Alamat"), f.BindAddress, mono: true);
        var bindPort = Ui.Number(f.BindPort, 1, 65535, 100);
        var destHost = Ui.Field(L.T("Host tujuan"), f.DestHost, mono: true);
        var destPort = Ui.Number(f.DestPort, 1, 65535, 100);
        var destRow = Ui.Columns("*,Auto", 8, destHost, destPort);
        var bindTitle = Ui.Text("", 12, FontWeights.SemiBold);
        var destTitle = Ui.Text("", 12, FontWeights.SemiBold);
        void RenderKind()
        {
            kindBox.Child = Ui.Segmented(["Local (-L)", "Remote (-R)", "SOCKS (-D)"], (int)f.Kind, i => { f = f with { Kind = (ForwardKind)i }; RenderKind(); });
            explain.Text = f.Kind.Explanation();
            bindTitle.Text = f.Kind == ForwardKind.Remote ? L.T("Port di server") : L.T("Port di PC ini");
            destTitle.Text = f.Kind == ForwardKind.Remote ? L.T("Tujuan di sisi PC ini") : L.T("Tujuan (dilihat dari server)");
            destRow.Visibility = destTitle.Visibility = f.Kind == ForwardKind.Dynamic ? Visibility.Collapsed : Visibility.Visible;
        }
        RenderKind();
        var content = Ui.Col(10, label, host, kindBox, explain, bindTitle, Ui.Columns("*,Auto", 8, bindAddr, bindPort), destTitle, destRow);
        content.Width = 460;
        var d = Ui.Dialog(string.IsNullOrEmpty(original.Id) ? L.T("Aturan baru") : L.T("Edit aturan"), content, L.T("Simpan"));
        if (await d.ShowAsync() != ContentDialogResult.Primary) return;
        var saved = f with
        {
            Label = label.Text.Trim(), HostId = (host.SelectedItem as ComboBoxItem)?.Tag as string ?? f.HostId,
            BindAddress = bindAddr.Text.Trim().Length == 0 ? "127.0.0.1" : bindAddr.Text.Trim(),
            BindPort = (ushort)(double.IsNaN(bindPort.Value) ? 8080 : bindPort.Value),
            DestHost = destHost.Text.Trim().Length == 0 ? "localhost" : destHost.Text.Trim(),
            DestPort = (ushort)(double.IsNaN(destPort.Value) ? 80 : destPort.Value),
        };
        var wasRunning = M.Tunnels.IsRunning(original.Id);
        if (wasRunning) M.Tunnels.Stop(original.Id);
        M.Save(saved);
        if (wasRunning && M.Forwards.FirstOrDefault(x => x.Id == original.Id) is { } updated) M.ToggleTunnel(updated);
    }
}
