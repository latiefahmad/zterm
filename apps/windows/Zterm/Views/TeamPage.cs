using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using uniffi.zterm_core;

namespace Zterm.Views;

/// <summary>Tim: admin membagikan host ke email rekan; anggota melihat host tim di daftar Hosts. Sama dengan TeamView.swift.</summary>
internal sealed class TeamPage : PageBase
{
    public const string JoinPage = "https://latief.id/zterm/team.html";

    private readonly StackPanel _body = Ui.Col(20);
    private readonly Grid _header;
    private readonly Dictionary<string, string> _inviteDrafts = [];
    private string _shown = "";

    public TeamPage() : base("data", "team", "sync")
    {
        _header = Ui.Header(L.T("Tim"), L.T("Bagikan host ke rekan kerja — terenkripsi end-to-end lewat Google Drive"));
        Children.Add(Ui.Scroll(Ui.Col(22, _header, _body)));
        Render();
        Loaded += async (s, e) => { await M.SyncTeams(); await M.RefreshInvites(); };
    }

    /// <summary>Render ulang hanya jika isi berubah, agar kolom email yang sedang diketik tidak hilang.</summary>
    protected override void OnModelChanged(string what)
    {
        if (Signature() != _shown) Render();
    }

    private string Signature() => string.Join("|",
        M.TeamReady, M.TeamBusy, M.TeamError, M.AccountEmail,
        string.Join(";", M.TeamInvites.Select(i => i.FileId)),
        string.Join(";", M.Teams.Select(t => $"{t.Id},{t.Name},{t.Status},{t.Error},{t.LastSync / 60000},{string.Join("+", t.SharedHostIds)}," +
                                              string.Join("+", t.Members.Select(m => m.Email + m.Status)))),
        M.Hosts.Length);

    protected override void Render()
    {
        _shown = Signature();
        var actions = (StackPanel)((Grid)_header).Children[1];
        actions.Children.Clear();
        if (M.TeamReady)
        {
            if (M.TeamBusy) actions.Children.Add(new ProgressRing { IsActive = true, Width = 18, Height = 18 });
            actions.Children.Add(Ui.Secondary(L.T("Gabung tim"), G.AddFriend, () => _ = JoinDialog()));
            actions.Children.Add(Ui.Primary(L.T("Buat tim"), G.Add, () => _ = CreateDialog()));
        }

        _body.Children.Clear();
        if (M.TeamError is { } err)
            _body.Children.Add(new Border
            {
                Background = Theme.Brush(Theme.Red, 0.12), CornerRadius = new CornerRadius(10), Padding = new Thickness(12, 10, 12, 10),
                Child = Ui.Row(8, Ui.Icon(G.Warning, 14, Theme.Brush(Theme.Red)), Ui.Text(err, 13, fg: Theme.Brush(Theme.Red), wrap: true))
            });

        if (!M.TeamReady) { _body.Children.Add(SetupCard()); return; }

        if (M.TeamInvites.Length > 0)
        {
            _body.Children.Add(Ui.Caps(L.T("Undangan")));
            foreach (var inv in M.TeamInvites) _body.Children.Add(InviteRow(inv));
        }
        if (M.Teams.Length == 0) { _body.Children.Add(Intro()); return; }
        for (int i = 0; i < M.Teams.Length; i++)
        {
            var card = TeamCard(M.Teams[i]);
            _body.Children.Add(card);
            Ui.StaggerIn(card, i);
        }
    }

    private UIElement SetupCard()
    {
        var signedIn = M.AccountEmail != null;
        var btn = Ui.Primary(signedIn ? L.T("Izinkan akses Google Drive") : L.T("Masuk dengan Google"), G.Cloud, () => _ = M.GrantTeamAccess());
        btn.HorizontalAlignment = HorizontalAlignment.Left;
        var text = Ui.Col(8,
            Ui.Text(signedIn ? L.T("Izinkan Zterm mengelola file Tim") : L.T("Masuk dengan Google untuk memakai Tim"), 18, FontWeights.Bold),
            Ui.Secondary(signedIn
                ? L.T("Tim butuh izin Google Drive tambahan: hanya file yang dibuat atau kamu pilih di Zterm — bukan seluruh Drive-mu. Masuk ulang dengan Google lalu centang izin Drive.")
                : L.T("Tim memakai Google Drive milik admin untuk menyimpan host yang dibagikan. Isinya terenkripsi — Google tidak bisa membacanya."), 13, wrap: true),
            btn);
        return Ui.Card(Ui.Columns("Auto,*", 18, Ui.TintIcon(G.People, Section.Team.Tint(), 56, 24, 14), text), 22);
    }

    private UIElement Intro()
    {
        var steps = Ui.Columns("*,*,*", 12,
            Step(1, L.T("Buat tim"), L.T("Pilih host yang dibagikan — password & SSH key ikut, terenkripsi.")),
            Step(2, L.T("Undang email"), L.T("Google mengirim email undangan ke rekanmu.")),
            Step(3, L.T("Rekan bergabung"), L.T("Mereka klik Gabung tim di Zterm; host muncul di daftar Hosts.")));
        steps.MaxWidth = 780;
        return Ui.Col(18, Ui.EmptyState(G.People, L.T("Belum ada tim"), L.T("Buat tim untuk membagikan host ke rekan kerja, atau gabung ke tim yang mengundangmu.")), steps);
    }

    private static UIElement Step(int n, string title, string text) => Ui.Card(Ui.Col(6,
        new Border
        {
            Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Background = Theme.AccentBrush, HorizontalAlignment = HorizontalAlignment.Left,
            Child = new TextBlock { Text = n.ToString(), FontSize = 12, FontWeight = FontWeights.Bold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Foreground = Theme.Brush("#000000", 0.75) }
        },
        Ui.Text(title, 13, FontWeights.SemiBold), Ui.Secondary(text, 12, wrap: true)), 14);

    private UIElement InviteRow(TeamInvite inv)
    {
        var join = Ui.Primary(L.T("Gabung"), null, () => { });
        join.Click += async (s, e) => { join.IsEnabled = false; await M.JoinTeam(inv.FileId); join.IsEnabled = true; };
        return Ui.HoverCard(Ui.Columns("Auto,*,Auto", 12, Ui.TintIcon(G.Mail, Section.Team.Tint(), 34, 14, 9),
            Ui.Col(2, Ui.Text(inv.Name, 13, FontWeights.SemiBold), Ui.Text(L.T("dari {}", inv.OwnerEmail), 11, fg: Theme.Text2)), join));
    }

    // MARK: Kartu tim

    private UIElement TeamCard(TeamInfo t)
    {
        var title = Ui.Row(8, Ui.Text(t.Name, 17, FontWeights.Bold), Ui.Badge(t.IsOwner ? "ADMIN" : L.T("ANGGOTA"), t.IsOwner ? Theme.Accent : Theme.Accent2));
        if (!t.IsOwner)
            title.Children.Add(t.Status switch
            {
                TeamStatus.Active => Ui.Badge(L.T("AKTIF"), Theme.Green),
                TeamStatus.Waiting => Ui.Badge(L.T("MENUNGGU ADMIN"), Theme.Orange),
                _ => Ui.Badge(L.T("AKSES DICABUT"), Theme.Red),
            });
        var sub = new List<string> { t.IsOwner ? L.T("{} anggota", t.Members.Length) : L.T("Admin: {}", t.OwnerEmail) };
        if (t.LastSync > 0) sub.Add(L.T("disinkron {}", Ui.Relative(Ui.FromMs(t.LastSync))));
        if (t.Error is { } e) sub.Add("⚠ " + L.Msg(e));

        var menu = new MenuFlyout();
        var syncItem = new MenuFlyoutItem { Text = L.T("Sinkronkan sekarang"), Icon = new FontIcon { Glyph = G.Sync } };
        syncItem.Click += (s, e2) => _ = M.SyncTeams();
        var leave = new MenuFlyoutItem { Text = t.IsOwner ? L.T("Hapus tim…") : L.T("Keluar dari tim…"), Icon = new FontIcon { Glyph = G.Delete }, Foreground = Theme.Brush("#E5484D") };
        leave.Click += async (s, e2) =>
        {
            var ok = await Ui.Confirm(t.IsOwner ? L.T("Hapus tim {}?", t.Name) : L.T("Keluar dari {}?", t.Name),
                t.IsOwner ? L.T("File tim dipindah ke sampah Google Drive-mu dan semua anggota kehilangan akses ke host tim.")
                          : L.T("Host tim hilang dari Zterm-mu. Admin bisa mengundangmu lagi nanti."),
                t.IsOwner ? L.T("Hapus tim") : (L10n.English ? "Leave" : "Keluar"));
            if (ok) await M.LeaveTeam(t);
        };
        menu.Items.Add(syncItem); menu.Items.Add(new MenuFlyoutSeparator()); menu.Items.Add(leave);
        var more = Ui.IconBtn(G.More, L.T("Lainnya"), () => { });
        more.Flyout = menu;

        var head = Ui.Columns("Auto,*,Auto", 12, Ui.TintIcon(G.People, Section.Team.Tint(), 42, 18, 12),
            Ui.Col(3, title, Ui.Text(string.Join(" · ", sub), 11.5, fg: Theme.Text2).With(x => x.TextTrimming = TextTrimming.CharacterEllipsis)), more);
        var body = t.IsOwner ? OwnerBody(t) : MemberBody(t);
        return Ui.Card(Ui.Col(16, head, body), 18, 16);
    }

    private UIElement OwnerBody(TeamInfo t)
    {
        // Anggota
        var members = Ui.Col(0);
        foreach (var m in t.Members)
        {
            var status = Ui.Text(m.IsAdmin ? "Admin" : m.Status == MemberStatus.Joined ? L.T("Aktif") : L.T("Belum bergabung di Zterm"), 11,
                fg: m.IsAdmin || m.Status == MemberStatus.Joined ? Theme.Text2 : Theme.Brush(Theme.Orange));
            UIElement? remove = m.IsAdmin ? null : Ui.IconBtn(G.RemovePerson, L.T("Keluarkan dari tim"), async () =>
            {
                if (await Ui.Confirm(L.T("Keluarkan {}?", m.Email),
                        L.T("Akses Google Drive-nya dicabut dan kunci tim diganti, jadi perubahan host berikutnya tidak bisa dibaca lagi olehnya. Ganti juga password server yang sempat ia lihat."),
                        L.T("Keluarkan")))
                    await M.RemoveFromTeam(t, m.Email);
            }, Theme.Brush("#E5484D"));
            members.Children.Add(new Border
            {
                Padding = new Thickness(0, 7, 0, 7), BorderBrush = Theme.Ink(0.06),
                BorderThickness = new Thickness(0, 0, 0, m == t.Members.Last() ? 0 : 1),
                Child = Ui.Columns("Auto,*,Auto", 10, Ui.Avatar(null, m.Email, 28), Ui.Col(1, Ui.Text(m.Email, 12.5, FontWeights.Medium), status), remove)
            });
        }
        var email = Ui.Field(L.T("email@rekan.com"), _inviteDrafts.GetValueOrDefault(t.Id, ""));
        var invite = Ui.Primary(L.T("Undang"), null, () => { });
        async Task DoInvite()
        {
            var v = email.Text.Trim();
            if (!v.Contains('@')) return;
            invite.IsEnabled = false;
            if (await M.InviteToTeam(t, v)) { email.Text = ""; _inviteDrafts.Remove(t.Id); }
            invite.IsEnabled = true;
        }
        invite.Click += async (s, e) => await DoInvite();
        email.TextChanged += (s, e) => _inviteDrafts[t.Id] = email.Text;
        email.KeyDown += async (s, e) => { if (e.Key == Windows.System.VirtualKey.Enter) await DoInvite(); };
        var left = Ui.Col(10, Ui.Caps(L.T("Anggota")), members, Ui.Columns("*,Auto", 8, email, invite),
            Ui.Text(L.T("Google mengirim email undangan. Rekan lalu membuka Tim → Gabung tim di Zterm miliknya, masuk dengan email yang diundang."), 11, fg: Theme.Text3, wrap: true));

        // Host dibagikan
        var shared = M.OwnHosts.Where(h => t.SharedHostIds.Contains(h.Id)).ToList();
        var hosts = Ui.Col(6);
        if (shared.Count == 0)
            hosts.Children.Add(new Border
            {
                MinHeight = 80, CornerRadius = new CornerRadius(12), Background = Theme.Ink(0.04),
                Child = Ui.Secondary(L.T("Belum ada host yang dibagikan.")).With(x => { x.HorizontalAlignment = HorizontalAlignment.Center; x.VerticalAlignment = VerticalAlignment.Center; })
            });
        foreach (var h in shared) hosts.Children.Add(HostChip(h));
        var right = Ui.Col(10,
            Ui.Columns("*,Auto", 8, Ui.Caps(L.T("Host dibagikan")), Ui.Secondary(L.T("Pilih host"), G.Checklist, () => _ = ShareDialog(t))),
            hosts,
            Ui.Text(L.T("Password & SSH key host ikut dibagikan, terenkripsi. Perubahan host otomatis terkirim ke anggota."), 11, fg: Theme.Text3, wrap: true));
        return Ui.Columns("*,*", 18, left, right);
    }

    private UIElement MemberBody(TeamInfo t)
    {
        switch (t.Status)
        {
            case TeamStatus.Active:
                var mine = M.Hosts.Where(h => h.Id.StartsWith($"team:{t.Id}:")).ToList();
                var grid = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 260, ItemHeight = 52 };
                foreach (var h in mine) grid.Children.Add(HostChip(h).With(c => c.Margin = new Thickness(0, 0, 8, 8)));
                return Ui.Col(10,
                    Ui.Columns("*,Auto", 8, Ui.Caps(L.T("{} host dari tim", mine.Count)), Ui.Secondary(L.T("Buka Hosts"), G.Server, () => M.Navigate(Section.Hosts))),
                    grid);
            case TeamStatus.Waiting when t.Error is { } err:
                return Ui.Columns("Auto,*", 8, Ui.Icon(G.Clock, 14, Theme.Text2), Ui.Secondary(L.Msg(err), 13, wrap: true));
            case TeamStatus.Waiting:
                return Ui.Row(8, Ui.Icon(G.Clock, 14, Theme.Text2),
                    Ui.Secondary(L.T("Menunggu {} membuka Zterm agar kunci tim terkirim. Host tim muncul otomatis setelah itu.", t.OwnerEmail), 13, wrap: true));
            default:
                return Ui.Row(8, Ui.Icon(G.Lock, 14, Theme.Text2), Ui.Secondary(L.T("Akses ke tim ini sudah dicabut atau timnya dihapus."), 13));
        }
    }

    private Border HostChip(Host h)
    {
        var auth = h.Auth switch { AuthMethod.Key => G.Key, AuthMethod.Agent => G.Person, _ => G.Lock };
        UIElement? connect = h.IsTeam() ? Ui.IconBtn(G.Play, "Connect", () => M.Connect([h.Id])) : null;
        return new Border
        {
            CornerRadius = new CornerRadius(10), Background = Theme.Ink(0.045), Padding = new Thickness(10, 7, 10, 7),
            Child = Ui.Columns("Auto,*,Auto,Auto", 10,
                new Border { Width = 8, Height = 26, CornerRadius = new CornerRadius(4), Background = Theme.Brush(h.Color) },
                Ui.Col(1, Ui.Text(h.Title(), 12.5, FontWeights.SemiBold), Ui.Text(h.DisplayAddress(M.HideAddresses), 10.5, fg: Theme.Text2, mono: true)),
                Ui.Icon(auth, 11, Theme.Text3), connect)
        };
    }

    // MARK: Dialog

    private async Task CreateDialog()
    {
        var name = Ui.Field(L.T("Nama tim (mis. Tim Ops)"));
        var content = Ui.Col(10, Ui.Secondary(L.T("File tim dibuat di Google Drive-mu ({}). Kamu jadi admin: yang bisa mengundang dan memilih host.", M.AccountEmail ?? L.T("akun Google")), 13, wrap: true), name);
        content.Width = 420;
        var d = Ui.Dialog(L.T("Buat tim"), content, L.T("Buat tim"));
        name.Loaded += (s, e) => name.Focus(FocusState.Programmatic);
        if (await d.ShowAsync() != ContentDialogResult.Primary || name.Text.Trim().Length == 0) return;
        await M.CreateTeam(name.Text.Trim());
    }

    private async Task JoinDialog()
    {
        var invites = Ui.Col(6);
        ContentDialog? d = null;
        void RenderInvites()
        {
            invites.Children.Clear();
            foreach (var inv in M.TeamInvites)
            {
                var b = Ui.Primary(L.T("Gabung"), null, () => { });
                b.Click += async (s, e) => { b.IsEnabled = false; if (await M.JoinTeam(inv.FileId)) d?.Hide(); b.IsEnabled = true; };
                invites.Children.Add(Ui.Card(Ui.Columns("*,Auto", 8, Ui.Col(1, Ui.Text(inv.Name, 13, FontWeights.SemiBold), Ui.Text(L.T("dari {}", inv.OwnerEmail), 11, fg: Theme.Text2)), b), 10, 10));
            }
        }
        var open = Ui.Secondary(L.T("Buka halaman"), G.Globe, () => Ui.Open(JoinPage));
        var check = Ui.Secondary(L.T("Cek undangan"), G.Refresh, () => { });
        check.Click += async (s, e) => { check.IsEnabled = false; await M.RefreshInvites(); RenderInvites(); check.IsEnabled = true; };
        var link = Ui.Field("https://drive.google.com/file/d/…");
        var join = Ui.Primary(L.T("Gabung"), null, () => { });
        var err = Ui.Text("", 12, fg: Theme.Brush(Theme.Red), wrap: true);
        join.Click += async (s, e) =>
        {
            if (link.Text.Trim().Length < 10) return;
            join.IsEnabled = false;
            if (await M.JoinTeam(link.Text)) d?.Hide(); else err.Text = L.Msg(M.TeamError ?? "");
            join.IsEnabled = true;
        };
        var content = Ui.Col(14,
            Ui.Columns("*,Auto", 10, Ui.Col(2, Ui.Text(L.T("1. Buka halaman Gabung tim"), 13, FontWeights.SemiBold),
                Ui.Secondary(L.T("Masuk dengan akun Google yang diundang ({}), lalu pilih file tim.", M.AccountEmail ?? "-"), 12, wrap: true)), open),
            Ui.Columns("*,Auto", 10, Ui.Col(2, Ui.Text(L.T("2. Kembali ke sini"), 13, FontWeights.SemiBold),
                Ui.Secondary(L.T("Undangan yang sudah kamu pilih muncul di bawah."), 12, wrap: true)), check),
            invites,
            Ui.Divider(),
            Ui.Secondary(L.T("Atau tempel link / ID file tim dari halaman Gabung tim:"), 12),
            Ui.Columns("*,Auto", 8, link, join),
            err);
        content.Width = 480;
        d = Ui.Dialog(L.T("Gabung tim"), content, null, L.T("Tutup"));
        RenderInvites();
        _ = M.RefreshInvites().ContinueWith(_ => DispatcherQueue.TryEnqueue(RenderInvites));
        await d.ShowAsync();
    }

    private async Task ShareDialog(TeamInfo t)
    {
        var picked = new HashSet<string>(t.SharedHostIds);
        var list = Ui.Col(4);
        var count = Ui.Secondary("", 12);
        void RenderList()
        {
            list.Children.Clear();
            foreach (var h in M.OwnHosts)
            {
                var on = picked.Contains(h.Id);
                var row = Ui.Columns("Auto,Auto,*,Auto", 10,
                    Ui.Icon(on ? G.Check : "", 14, on ? Theme.AccentBrush : Theme.Text2),
                    new Border { Width = 6, Height = 20, CornerRadius = new CornerRadius(3), Background = Theme.Brush(h.Color) },
                    Ui.Text(h.Title(), 13, FontWeights.Medium),
                    h.Group is { Length: > 0 } g ? Ui.Text(g, 11, fg: Theme.Text3) : null);
                var b = Ui.Plain(row, () => { if (!picked.Remove(h.Id)) picked.Add(h.Id); RenderList(); }, new Thickness(12, 8, 12, 8));
                b.Background = on ? Theme.Brush(Theme.Accent, 0.1) : Theme.Card;
                b.HorizontalAlignment = HorizontalAlignment.Stretch;
                list.Children.Add(b);
            }
            count.Text = L.T("{} dipilih", picked.Count);
        }
        RenderList();
        var content = Ui.Col(10,
            Ui.Secondary(L.T("Anggota bisa connect ke host ini (termasuk password & SSH key-nya), tapi tidak bisa mengubahnya."), 13, wrap: true),
            new ScrollViewer { Content = list, Height = 300 }, count);
        content.Width = 460;
        var d = Ui.Dialog(L.T("Host untuk {}", t.Name), content, L.T("Simpan"));
        if (await d.ShowAsync() != ContentDialogResult.Primary) return;
        await M.ShareHosts(t, picked);
    }
}
