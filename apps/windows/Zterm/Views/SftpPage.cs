using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using uniffi.zterm_core;

namespace Zterm.Views;

/// <summary>SFTP dua panel: PC ini ↔ server. Drag & drop antarpanel dan dari File Explorer.</summary>
internal sealed class SftpPage : PageBase
{
    private SftpModel S => M.Sftp;
    private readonly Border _top = new();
    private readonly Border _localPane = new();
    private readonly Border _remotePane = new();
    private readonly Border _transfers = new();
    private readonly Grid _connected;
    private readonly Border _picker = new();
    private readonly Grid _editorLayer = new() { Visibility = Visibility.Collapsed };
    private RemoteEditorDoc? _shownDoc;
    private HostKeyConflict? _conflictShown;
    private TextBlock? _edDirty, _edLines;
    private Button? _edSave;
    private ListView? _localList, _remoteList;
    private static readonly CultureInfo Id = new(L10n.English ? "en-US" : "id-ID");
    private const string DragFormat = "zterm-sftp";

    public SftpPage() : base("sftp", "transfers", "data")
    {
        var panes = Ui.Columns("*,*", 12, _localPane, _remotePane);
        _connected = Ui.Rows("Auto,*,Auto", 12, _top, panes, _transfers);
        _connected.Padding = new Thickness(20, 16, 20, 16);
        Children.Add(_connected);
        Children.Add(_picker);
        Children.Add(_editorLayer);
        Render();
    }

    protected override void OnModelChanged(string what)
    {
        if (what == "transfers") { if (_connected.Visibility == Visibility.Visible) RenderTransfers(); }
        else Render();
    }

    protected override void Render()
    {
        var showPicker = S.State == SftpModel.Status.Idle;
        _picker.Visibility = showPicker ? Visibility.Visible : Visibility.Collapsed;
        _connected.Visibility = showPicker ? Visibility.Collapsed : Visibility.Visible;
        if (showPicker) { RenderPicker(); return; }
        RenderTop();
        RenderLocal();
        RenderRemote();
        RenderTransfers();
        RenderEditor();
        if (S.Conflict is { } conflict && !ReferenceEquals(conflict, _conflictShown))
        {
            _conflictShown = conflict;
            _ = ShowHostKeyConflict(conflict);
        }
    }

    /// <summary>Dialog konflik host key: bandingkan fingerprint lama & baru sebelum mengganti.</summary>
    private async Task ShowHostKeyConflict(HostKeyConflict c)
    {
        static UIElement Fingerprint(string label, string keyType, string fingerprint)
        {
            var type = string.IsNullOrEmpty(keyType) ? "" : $" · {keyType}";
            var value = string.IsNullOrEmpty(fingerprint) ? L.T("Tidak tercatat") : fingerprint;
            return Ui.Col(3,
                Ui.Text(label + type, 11, fg: Theme.Text2),
                Ui.Text(value, 12, mono: true).With(t =>
                {
                    t.IsTextSelectionEnabled = true;
                    t.TextWrapping = TextWrapping.Wrap;
                    t.TextTrimming = TextTrimming.None;
                }));
        }

        var body = Ui.Col(14,
            Ui.Text(L.T("Kunci server ini berbeda dari yang tercatat. Bandingkan fingerprint lama dan baru sebelum memutuskan. Jika kamu tidak yakin server memang berganti kunci, batalkan dan periksa server."), 12.5, wrap: true),
            Ui.Card(Ui.Col(10,
                Ui.Text(c.Address, 12, fg: Theme.Text2, mono: true),
                Ui.Divider(),
                Fingerprint(L.T("Fingerprint lama"), c.OldKeyType, c.OldFingerprint),
                Ui.Divider(),
                Fingerprint(L.T("Fingerprint baru"), c.NewKeyType, c.NewFingerprint)), 14));
        var d = Ui.Dialog(L.T("Kunci server berubah"), body, L.T("Ganti key"));
        d.SecondaryButtonText = L.T("Buka Known Hosts");
        d.DefaultButton = ContentDialogButton.Close;
        d.PrimaryButtonStyle = Ui.DangerStyle();
        var result = await d.ShowAsync();
        if (result == ContentDialogResult.Primary) await S.ReplaceHostKey();
        else if (result == ContentDialogResult.Secondary)
        {
            S.DismissConflict();
            M.Navigate(Section.KnownHosts);
        }
        else S.DismissConflict();
    }

    // MARK: Editor teks bawaan

    /// <summary>Teks dari TextBox (akhir baris "\r") → akhir baris asli file.</summary>
    private static string FromBox(string boxText, string eol) => boxText.Replace("\r\n", "\n").Replace("\r", "\n").Replace("\n", eol);

    private void RenderEditor()
    {
        var doc = S.Editor;
        if (doc == null) { _editorLayer.Visibility = Visibility.Collapsed; _editorLayer.Children.Clear(); _shownDoc = null; return; }
        if (doc == _shownDoc) { UpdateEditorState(doc); return; }
        _shownDoc = doc;

        var lines = new TextBlock { FontFamily = Theme.MonoFont, FontSize = 13, Foreground = Theme.Text3, TextAlignment = TextAlignment.Right, Padding = new Thickness(0, 9, 10, 9) };
        var box = new TextBox
        {
            AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, FontFamily = Theme.MonoFont, FontSize = 13,
            IsSpellCheckEnabled = false, IsTextPredictionEnabled = false, BorderThickness = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Padding = new Thickness(10, 9, 10, 9), MinWidth = 400,
        };
        // Text diisi SETELAH AcceptsReturn: kalau sebelumnya, TextBox memotong teks ke baris pertama.
        box.Text = doc.Text;
        ScrollViewer.SetHorizontalScrollBarVisibility(box, ScrollBarVisibility.Disabled);
        void Numbers()
        {
            var n = box.Text.Split('\r').Length;
            if (box.Text.EndsWith('\r')) n--;
            lines.Text = string.Join("\n", Enumerable.Range(1, Math.Max(1, n)));
            if (_edLines != null) _edLines.Text = L.T("{} baris", Math.Max(1, n));
        }
        box.TextChanged += (_, _) => { doc.Text = FromBox(box.Text, doc.LineEnding); Numbers(); UpdateEditorState(doc); };
        var gutter = new Border { Child = lines, Background = Theme.Panel, MinWidth = 48 };
        var body = Ui.Columns("Auto,*", 0, gutter, box);
        var scroll = new ScrollViewer { Content = body, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Enabled, ZoomMode = ZoomMode.Disabled };

        _edDirty = Ui.Text("●", 12, fg: Theme.Brush(Theme.Orange));
        _edSave = Ui.Primary(L.T("Simpan"), G.Save, () => _ = Save(doc, false));
        var openWith = new DropDownButton { Content = Ui.Row(6, Ui.Icon(G.Export, 12), Ui.Text(L.T("Buka dengan"), 12.5)) };
        openWith.Flyout = OpenWithFlyout(new FileItem(doc.Name, doc.Path, false, 0, null, 0), () => S.CloseEditor());
        var title = Ui.Col(1, Ui.Row(8, Ui.Text(doc.Name, 15, FontWeights.SemiBold), _edDirty),
            Ui.Text(doc.Path, 11, fg: Theme.Text2, mono: true).With(t => t.TextTrimming = TextTrimming.CharacterEllipsis));
        var head = Ui.Columns("Auto,*,Auto,Auto,Auto", 10, Ui.TintIcon(G.Document, Theme.Accent, 32, 13, 9), title, openWith, _edSave,
            Ui.IconBtn(G.Close, L.T("Tutup (Esc)"), () => _ = CloseEditor(doc)));
        head.Padding = new Thickness(16, 12, 14, 12);
        _edLines = Ui.Text("", 11.5, fg: Theme.Text2);
        var foot = Ui.Columns("Auto,Auto,Auto,*,Auto", 16, _edLines, Ui.Text(doc.LineEnding == "\r\n" ? "UTF-8 · CRLF" : "UTF-8 · LF", 11.5, fg: Theme.Text2),
            Ui.Text(S.Host is { } h ? $"SFTP · {h.Title()}" : "SFTP", 11.5, fg: Theme.Text2), null, Ui.Text(L.T("Ctrl+S simpan · Esc tutup"), 11.5, fg: Theme.Text3));
        foot.Padding = new Thickness(16, 7, 16, 8);
        var sep1 = new Border { Height = 1, Background = Theme.Ink(0.08) };
        var sep2 = new Border { Height = 1, Background = Theme.Ink(0.08) };
        var card = new Border
        {
            Child = Ui.Rows("Auto,Auto,*,Auto,Auto", 0, head, sep1, scroll, sep2, foot),
            Background = Theme.Bg, BorderBrush = Theme.CardStroke, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(14),
            Margin = new Thickness(24),
        };
        var save = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.S, Modifiers = Windows.System.VirtualKeyModifiers.Control };
        save.Invoked += (s, e) => { e.Handled = true; _ = Save(doc, false); };
        var esc = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.Escape };
        esc.Invoked += (s, e) => { e.Handled = true; _ = CloseEditor(doc); };
        card.KeyboardAccelerators.Add(save);
        card.KeyboardAccelerators.Add(esc);
        card.KeyboardAcceleratorPlacementMode = Microsoft.UI.Xaml.Input.KeyboardAcceleratorPlacementMode.Hidden;

        _editorLayer.Children.Clear();
        _editorLayer.Children.Add(new Border { Background = Theme.Brush("#000000", 0.45) });
        _editorLayer.Children.Add(card);
        _editorLayer.Visibility = Visibility.Visible;
        Numbers();
        UpdateEditorState(doc);
        Ui.StaggerIn(card, 0);
        DispatcherQueue.TryEnqueue(() => box.Focus(FocusState.Programmatic));
    }

    private void UpdateEditorState(RemoteEditorDoc doc)
    {
        if (_edDirty != null) _edDirty.Visibility = doc.Dirty ? Visibility.Visible : Visibility.Collapsed;
        if (_edSave != null) _edSave.IsEnabled = doc.Dirty && !doc.Saving;
    }

    private async Task Save(RemoteEditorDoc doc, bool force)
    {
        var r = await S.SaveEditor(doc, force);
        if (r == "conflict" && await Ui.Confirm(L.T("File di server sudah berubah"), L.T("{} diubah di server setelah kamu membukanya. Simpan akan menimpa perubahan itu.", doc.Name), L.T("Timpa")))
            await S.SaveEditor(doc, true);
        else if (r != null && r != "conflict") await Ui.Confirm(L.T("Gagal menyimpan"), r, "OK", false);
        UpdateEditorState(doc);
    }

    private async Task CloseEditor(RemoteEditorDoc doc)
    {
        if (!doc.Dirty) { S.CloseEditor(); return; }
        var d = new ContentDialog
        {
            Title = L.T("Simpan perubahan di {}?", doc.Name), Content = L.T("Perubahan belum disimpan ke server."), PrimaryButtonText = L.T("Simpan & tutup"),
            SecondaryButtonText = L.T("Buang perubahan"), CloseButtonText = L.T("Batal"), DefaultButton = ContentDialogButton.Primary, XamlRoot = Ui.Root,
        };
        var res = await d.ShowAsync();
        if (res == ContentDialogResult.Primary) { if (await S.SaveEditor(doc) == null) S.CloseEditor(); }
        else if (res == ContentDialogResult.Secondary) S.CloseEditor();
    }

    /// <summary>Menu "Buka dengan": aplikasi bawaan, aplikasi umum yang terpasang, dialog Open with Windows.</summary>
    private MenuFlyout OpenWithFlyout(FileItem item, Action? before = null)
    {
        var f = new MenuFlyout();
        void Add(string text, string? app)
        {
            var i = new MenuFlyoutItem { Text = text };
            i.Click += (_, _) => { before?.Invoke(); _ = S.OpenWith(item, app); };
            f.Items.Add(i);
        }
        Add(L.T("Aplikasi bawaan"), null);
        var apps = RemoteFiles.CommonApps();
        if (apps.Count > 0) f.Items.Add(new MenuFlyoutSeparator());
        foreach (var (name, exe) in apps) Add(name, exe);
        f.Items.Add(new MenuFlyoutSeparator());
        Add(L.T("Pilih aplikasi lain…"), "choose");
        return f;
    }

    // MARK: Pilih server

    private void RenderPicker()
    {
        var header = Ui.Header("SFTP", L.T("Kelola file di server: upload, download, ganti nama, atur izin."));
        var col = Ui.Col(22, header);
        if (M.Hosts.Length == 0)
            col.Children.Add(Ui.EmptyState(G.Folder, L.T("Belum ada host"), L.T("Tambahkan host dulu di menu Hosts, lalu buka SFTP-nya di sini.")));
        else
        {
            col.Children.Add(Ui.Caps(L.T("Pilih server")));
            var rep = new ItemsRepeater
            {
                Layout = new UniformGridLayout { MinItemWidth = 240, MinItemHeight = 72, MinColumnSpacing = 12, MinRowSpacing = 12, ItemsStretch = UniformGridLayoutItemsStretch.Fill },
                ItemsSource = M.Hosts.Select((h, i) =>
                {
                    var row = Ui.Columns("Auto,*,Auto", 12, Ui.TintIcon(G.Folder, h.Color, 38, 15, 10),
                        Ui.Col(2, Ui.Text(h.Title(), 13.5, FontWeights.SemiBold), Ui.Text(h.DisplayAddress(M.HideAddresses), 11, fg: Theme.Text2, mono: true)),
                        Ui.Icon(G.ChevronRight, 11, Theme.Text3));
                    var b = Ui.Plain(row, () => _ = M.OpenSftp(h), new Thickness(14, 12, 14, 12));
                    b.Background = Theme.Card; b.BorderBrush = Theme.CardStroke; b.BorderThickness = new Thickness(1); b.CornerRadius = new CornerRadius(12);
                    b.HorizontalAlignment = HorizontalAlignment.Stretch;
                    Ui.StaggerIn(b, i);
                    return (object)b;
                }).ToList()
            };
            col.Children.Add(rep);
        }
        _picker.Child = Ui.Scroll(col);
    }

    // MARK: Bar atas

    private void RenderTop()
    {
        var h = S.Host;
        UIElement status = S.State switch
        {
            SftpModel.Status.Connecting => Ui.Row(6, new ProgressRing { Width = 14, Height = 14, IsActive = true }, Ui.Text(L.T("Menyambung…"), 12, fg: Theme.Text2)),
            SftpModel.Status.Failed => Ui.Row(6, Ui.Icon(G.Warning, 12, Theme.Brush(Theme.Orange)), Ui.Text(S.FailMessage ?? L.T("Gagal"), 12, fg: Theme.Brush(Theme.Orange)).With(t => t.MaxWidth = 520)),
            _ => Ui.Row(6, new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(4), Background = Theme.Brush(Theme.Green) }, Ui.Text(L.T("Tersambung"), 12, fg: Theme.Brush(Theme.Green))),
        };
        var title = Ui.Row(10, Ui.TintIcon(G.Folder, h?.Color ?? Theme.Accent, 30, 13, 8), Ui.Col(1, Ui.Text(h?.Title() ?? "SFTP", 15, FontWeights.Bold), status));
        var hidden = new ToggleSwitch { IsOn = S.ShowHidden, OnContent = L.T("File tersembunyi"), OffContent = L.T("File tersembunyi"), MinWidth = 0 };
        hidden.Toggled += (_, _) => { if (hidden.IsOn != S.ShowHidden) S.SetShowHidden(hidden.IsOn); };
        var actions = Ui.Row(8, hidden,
            S.State == SftpModel.Status.Failed && h != null ? Ui.Secondary(L.T("Coba lagi"), G.Refresh, () => _ = M.OpenSftp(h)) : null,
            Ui.Secondary(L.T("Ganti server"), G.Server, () => _ = S.Disconnect()),
            h != null ? Ui.Secondary("Terminal", G.Terminal, () => M.Connect([h.Id])) : null);
        var row = Ui.Columns("*,Auto", 12, title, actions);
        var err = S.Error is { } e ? new InfoBar { Severity = InfoBarSeverity.Warning, Message = e, IsOpen = true, IsClosable = false } : null;
        _top.Child = Ui.Col(8, row, err);
    }

    // MARK: Panel

    private Border Pane(string title, string glyph, string path, Action up, Action home, Action refresh, Action<string> go, Action newFolder, ListView list, UIElement? extra)
    {
        var pathBox = new TextBox { Text = path, FontFamily = Theme.MonoFont, FontSize = 12 };
        pathBox.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) go(pathBox.Text.Trim()); };
        var tools = Ui.Row(2, Ui.IconBtn(G.Up, L.T("Folder induk"), up), Ui.IconBtn(G.Home, L.T("Folder rumah"), home),
            Ui.IconBtn(G.Refresh, L.T("Muat ulang"), refresh), Ui.IconBtn(G.NewFolder, L.T("Folder baru"), newFolder));
        var head = Ui.Columns("Auto,*,Auto", 8, Ui.Row(7, Ui.Icon(glyph, 13, Theme.AccentBrush), Ui.Text(L.T(title), 13, FontWeights.SemiBold)), new Border(), extra);
        var bar = Ui.Columns("*,Auto", 6, pathBox, tools);
        var cols = Ui.Columns("26,*,90,130,90", 8, new Border(), Ui.Caps(L.T("Nama")), Ui.Caps(L.T("Ukuran")).With(t => t.HorizontalAlignment = HorizontalAlignment.Right), Ui.Caps(L.T("Diubah")), Ui.Caps(title == "Server" ? L.T("Izin") : ""));
        cols.Padding = new Thickness(12, 0, 12, 0);
        var root = Ui.Rows("Auto,Auto,Auto,*", 8, head, bar, cols, list);
        return new Border { Child = root, Padding = new Thickness(12), CornerRadius = new CornerRadius(14), Background = Theme.Card, BorderBrush = Theme.CardStroke, BorderThickness = new Thickness(1) };
    }

    private ListView MakeList(List<FileItem> items, bool remote)
    {
        var lv = new ListView { SelectionMode = ListViewSelectionMode.Extended, CanDragItems = true, AllowDrop = true, IsDoubleTapEnabled = true };
        foreach (var it in items) lv.Items.Add(new ListViewItem { Content = Row(it, remote), Tag = it, Padding = new Thickness(4, 0, 4, 0), MinHeight = 32 });
        if (items.Count == 0)
            lv.Header = Ui.Secondary(remote && S.RemoteLoading ? L.T("Memuat…") : L.T("Folder kosong"), 12).With(t => { t.Margin = new Thickness(14, 10, 0, 0); });
        lv.DoubleTapped += (_, e) =>
        {
            if ((e.OriginalSource as FrameworkElement)?.DataContext is not null) { }
            if (lv.SelectedItem is ListViewItem { Tag: FileItem f })
            {
                if (f.IsDir) { if (remote) _ = S.OpenRemote(f.Path); else S.OpenLocal(f.Path); }
                else if (remote) { if (RemoteFiles.IsTextLike(f)) _ = S.OpenEditor(f); else _ = S.OpenWith(f); }
                else if (S.Connected) S.Upload([f.Path]);
            }
        };
        lv.DragItemsStarting += (_, e) =>
        {
            var paths = e.Items.OfType<ListViewItem>().Select(i => ((FileItem)i.Tag).Path).ToList();
            e.Data.SetData(DragFormat, (remote ? "remote\n" : "local\n") + string.Join("\n", paths));
            e.Data.RequestedOperation = DataPackageOperation.Copy;
        };
        lv.DragOver += (_, e) =>
        {
            var ok = e.DataView.Contains(DragFormat) || (remote && e.DataView.Contains(StandardDataFormats.StorageItems));
            e.AcceptedOperation = ok ? DataPackageOperation.Copy : DataPackageOperation.None;
            if (ok) e.DragUIOverride.Caption = remote ? L.T("Upload ke server") : L.T("Download ke sini");
        };
        lv.Drop += async (_, e) =>
        {
            if (e.DataView.Contains(DragFormat))
            {
                var text = (string)await e.DataView.GetDataAsync(DragFormat);
                var lines = text.Split('\n');
                var fromRemote = lines[0] == "remote";
                var paths = lines.Skip(1).Where(p => p.Length > 0).ToList();
                if (remote && !fromRemote) S.Upload(paths);
                else if (!remote && fromRemote) S.Download(S.RemoteItems.Where(i => paths.Contains(i.Path)).ToList());
            }
            else if (remote && e.DataView.Contains(StandardDataFormats.StorageItems))
            {
                var items = await e.DataView.GetStorageItemsAsync();
                S.Upload(items.Select(i => i.Path).ToList());
            }
        };
        lv.ContextFlyout = remote ? RemoteMenu(lv) : LocalMenu(lv);
        return lv;
    }

    private static List<FileItem> Selected(ListView lv) => lv.SelectedItems.OfType<ListViewItem>().Select(i => (FileItem)i.Tag).ToList();

    private UIElement Row(FileItem f, bool remote)
    {
        var icon = Ui.Icon(f.IsDir ? G.Folder : G.Document, 14, f.IsDir ? Theme.Brush("#F2C55A") : Theme.Text2);
        var size = Ui.Text(f.IsDir ? "—" : Ui.Bytes(f.Size), 11.5, fg: Theme.Text2).With(t => t.HorizontalAlignment = HorizontalAlignment.Right);
        var mod = Ui.Text(f.Modified?.LocalDateTime.ToString("d MMM yy HH.mm", Id) ?? "", 11.5, fg: Theme.Text2);
        var perm = Ui.Text(remote ? SftpModel.PermissionString(f.Permissions, f.IsDir) : "", 11, fg: Theme.Text3, mono: true);
        return Ui.Columns("26,*,90,130,90", 8, icon, Ui.Text(f.Name, 12.5), size, mod, perm);
    }

    private void RenderLocal()
    {
        _localList = MakeList(S.LocalItems, false);
        _localPane.Child = Pane("PC ini", G.Home, S.LocalPath, S.LocalUp,
            () => S.OpenLocal(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)), S.ReloadLocal,
            p => { if (System.IO.Directory.Exists(p)) S.OpenLocal(p); }, () => _ = NewFolder(false), _localList,
            Ui.Primary("Upload", G.Upload, () => { var sel = Selected(_localList); if (sel.Count > 0) S.Upload(sel.Select(f => f.Path).ToList()); }).With(b => b.IsEnabled = S.Connected));
    }

    private void RenderRemote()
    {
        _remoteList = MakeList(S.RemoteItems, true);
        _remotePane.Child = Pane("Server", G.Server, S.RemotePath, () => _ = S.RemoteUp(), () => _ = S.RemoteHome(), () => _ = S.RefreshRemote(),
            p => _ = S.OpenRemote(p), () => _ = NewFolder(true), _remoteList,
            Ui.Primary("Download", G.Download, () => { var sel = Selected(_remoteList); if (sel.Count > 0) S.Download(sel); }).With(b => b.IsEnabled = S.Connected));
    }

    private MenuFlyout RemoteMenu(ListView lv)
    {
        var f = new MenuFlyout();
        void Item(string t, string g, Action<List<FileItem>> a, bool single = false)
        {
            var i = new MenuFlyoutItem { Text = L.T(t), Icon = new FontIcon { Glyph = g } };
            i.Click += (_, _) => { var sel = Selected(lv); if (sel.Count > 0 && (!single || sel.Count == 1)) a(sel); };
            f.Items.Add(i);
        }
        Item("Edit di Zterm", G.Edit, sel => { if (!sel[0].IsDir) _ = S.OpenEditor(sel[0]); }, true);
        var openWith = new MenuFlyoutSubItem { Text = L.T("Buka dengan"), Icon = new FontIcon { Glyph = G.Export } };
        void OW(string text, string? app)
        {
            var i = new MenuFlyoutItem { Text = text };
            i.Click += (_, _) => { var sel = Selected(lv); if (sel.Count == 1 && !sel[0].IsDir) _ = S.OpenWith(sel[0], app); };
            openWith.Items.Add(i);
        }
        OW(L.T("Aplikasi bawaan"), null);
        foreach (var (name, exe) in RemoteFiles.CommonApps()) OW(name, exe);
        openWith.Items.Add(new MenuFlyoutSeparator());
        OW(L.T("Pilih aplikasi lain…"), "choose");
        f.Items.Add(openWith);
        f.Items.Add(new MenuFlyoutSeparator());
        Item("Download", G.Download, sel => S.Download(sel));
        Item(L10n.English ? "Open" : "Buka", G.Folder, sel => { if (sel[0].IsDir) _ = S.OpenRemote(sel[0].Path); }, true);
        Item("Ganti nama…", G.Rename, sel => _ = Rename(sel[0], true), true);
        Item("Izin (chmod)…", G.Permissions, sel => _ = Chmod(sel[0]), true);
        Item("Salin path", G.Copy, sel => Ui.CopyText(string.Join("\n", sel.Select(x => x.Path))));
        f.Items.Add(new MenuFlyoutSeparator());
        Item("Hapus", G.Delete, async sel =>
        {
            if (await Ui.Confirm(sel.Count == 1 ? L.T("Hapus “{}”?", sel[0].Name) : L.T("Hapus {} item?", sel.Count), L.T("File di server akan dihapus permanen (folder beserta isinya).")))
                await S.DeleteRemote(sel);
        });
        return f;
    }

    private MenuFlyout LocalMenu(ListView lv)
    {
        var f = new MenuFlyout();
        void Item(string t, string g, Action<List<FileItem>> a, bool single = false)
        {
            var i = new MenuFlyoutItem { Text = L.T(t), Icon = new FontIcon { Glyph = g } };
            i.Click += (_, _) => { var sel = Selected(lv); if (sel.Count > 0 && (!single || sel.Count == 1)) a(sel); };
            f.Items.Add(i);
        }
        Item("Upload ke server", G.Upload, sel => S.Upload(sel.Select(x => x.Path).ToList()));
        Item("Ganti nama…", G.Rename, sel => _ = Rename(sel[0], false), true);
        Item("Tampilkan di File Explorer", G.Folder, sel =>
        {
            try { System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{sel[0].Path}\""); } catch { }
        }, true);
        f.Items.Add(new MenuFlyoutSeparator());
        Item("Hapus", G.Delete, async sel =>
        {
            if (await Ui.Confirm(sel.Count == 1 ? L.T("Hapus “{}”?", sel[0].Name) : L.T("Hapus {} item?", sel.Count), L.T("File di PC ini akan dihapus permanen.")))
                S.DeleteLocal(sel);
        });
        return f;
    }

    private async Task NewFolder(bool remote)
    {
        var name = Ui.Field(L.T("Nama folder"));
        var d = Ui.Dialog(L.T("Folder baru"), name, L.T("Buat"));
        name.Loaded += (_, _) => name.Focus(FocusState.Programmatic);
        if (await d.ShowAsync() != ContentDialogResult.Primary || name.Text.Trim().Length == 0) return;
        if (remote) await S.MkdirRemote(name.Text.Trim()); else S.MkdirLocal(name.Text.Trim());
    }

    private async Task Rename(FileItem item, bool remote)
    {
        var name = Ui.Field(L.T("Nama baru"), item.Name);
        var d = Ui.Dialog(L.T("Ganti nama"), name, L.T("Simpan"));
        name.Loaded += (_, _) => { name.Focus(FocusState.Programmatic); name.SelectAll(); };
        if (await d.ShowAsync() != ContentDialogResult.Primary) return;
        if (remote) await S.RenameRemote(item, name.Text.Trim()); else S.RenameLocal(item, name.Text.Trim());
    }

    private async Task Chmod(FileItem item)
    {
        var mode = item.Permissions & 0x1FF;
        var boxes = new List<CheckBox>();
        var grid = new Grid { ColumnSpacing = 8, RowSpacing = 4 };
        // "Lainnya"/"Jalankan" punya arti lain di kamus (More/Run), jadi label chmod dipilih langsung.
        string[] who = L10n.English ? ["Owner", "Group", "Others"] : ["Pemilik", "Grup", "Lainnya"];
        string[] what = L10n.English ? ["Read", "Write", "Execute"] : ["Baca", "Tulis", "Jalankan"];
        for (int c = 0; c < 4; c++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = c == 0 ? new GridLength(80) : GridLength.Auto });
        for (int r = 0; r < 4; r++) grid.RowDefinitions.Add(new RowDefinition());
        var octal = Ui.Field("", Convert.ToString(mode, 8).PadLeft(3, '0'), mono: true, width: 90);
        void UpdateOctal()
        {
            uint m = 0;
            for (int i = 0; i < 9; i++) if (boxes[i].IsChecked == true) m |= 1u << (8 - i);
            octal.Text = Convert.ToString(m, 8).PadLeft(3, '0');
        }
        for (int c = 0; c < 3; c++) { var t = Ui.Caps(what[c]); Grid.SetColumn(t, c + 1); grid.Children.Add(t); }
        for (int r = 0; r < 3; r++)
        {
            var l = Ui.Text(who[r], 12.5); Grid.SetRow(l, r + 1); grid.Children.Add(l);
            for (int c = 0; c < 3; c++)
            {
                var bit = 8 - (r * 3 + c);
                var cb = new CheckBox { IsChecked = (mode & (1u << bit)) != 0, MinWidth = 0 };
                cb.Click += (_, _) => UpdateOctal();
                Grid.SetRow(cb, r + 1); Grid.SetColumn(cb, c + 1);
                grid.Children.Add(cb);
                boxes.Add(cb);
            }
        }
        var content = Ui.Col(12, Ui.Text(item.Name, 13, FontWeights.SemiBold, mono: true), grid, Ui.Row(8, Ui.Text(L.T("Oktal"), 12.5), octal));
        var d = Ui.Dialog(L.T("Izin file"), content, L.T("Terapkan"));
        if (await d.ShowAsync() != ContentDialogResult.Primary) return;
        try { await S.ChmodRemote(item, Convert.ToUInt32(octal.Text.Trim(), 8)); }
        catch { M.Flash(L.T("Format oktal tidak valid (mis. 755)")); }
    }

    // MARK: Transfer

    private void RenderTransfers()
    {
        if (S.Transfers.Count == 0 && S.Watched.Count == 0) { _transfers.Child = null; _transfers.Visibility = Visibility.Collapsed; return; }
        _transfers.Visibility = Visibility.Visible;
        var watched = Ui.Col(6);
        if (S.Watched.Count > 0)
        {
            watched.Children.Add(Ui.Row(8, Ui.Icon(G.Sync, 13, Theme.AccentBrush), Ui.Text(L.T("Dibuka di aplikasi lain — disimpan otomatis ke server"), 13, FontWeights.SemiBold)));
            foreach (var w in S.Watched)
            {
                var state = w.Uploading ? Ui.Text(L.T("Mengunggah…"), 11.5, fg: Theme.AccentBrush)
                    : w.LastUpload is { } t ? Ui.Text(L.T("✓ Tersimpan {}", t.ToString("HH.mm")), 11.5, fg: Theme.Brush(Theme.Green)) : Ui.Text(L.T("Menunggu perubahan"), 11.5, fg: Theme.Text3);
                watched.Children.Add(Ui.Columns("Auto,Auto,*,Auto,Auto", 10, Ui.Icon(G.Document, 13, Theme.Text2),
                    Ui.Text(System.IO.Path.GetFileName(w.LocalPath), 12.5, FontWeights.Medium), Ui.Text(L.T("di {}", w.AppName), 11.5, fg: Theme.Text2), state,
                    Ui.Secondary(L.T("Berhenti"), null, () => S.StopWatching(w))));
            }
        }
        if (S.Transfers.Count == 0) { _transfers.Child = Ui.Card(watched, 12, 12); return; }
        var head = Ui.Columns("*,Auto", 8, Ui.Row(8, Ui.Text("Transfer", 13, FontWeights.SemiBold), Ui.Pill(L.T("{} berjalan", S.Transfers.Count(t => t.Status == Transfer.State.Running)))),
            Ui.Secondary(L.T("Bersihkan"), null, S.ClearFinished));
        var list = Ui.Col(6);
        foreach (var t in S.Transfers.Take(30))
        {
            var bar = new ProgressBar { Maximum = 1, Value = t.Fraction, Height = 4 };
            var (text, color) = t.Status switch
            {
                Transfer.State.Running => (t.Total > 0 ? $"{Ui.Bytes(t.Done)} / {Ui.Bytes(t.Total)}" : L.T("Menyiapkan…"), Theme.Accent2),
                Transfer.State.Done => (L.T("Selesai"), Theme.Green),
                Transfer.State.Cancelled => (L.T("Dibatalkan"), "#94A3B8"),
                _ => (t.Error ?? L.T("Gagal"), Theme.Orange),
            };
            if (t.Status != Transfer.State.Running) bar.Foreground = Theme.Brush(color);
            var cancel = t.Status == Transfer.State.Running ? Ui.IconBtn(G.Close, L.T("Batalkan"), () => S.Cancel(t), size: 10) : null;
            var row = Ui.Columns("Auto,180,*,220,Auto", 10,
                Ui.Icon(t.Direction == Transfer.Kind.Upload ? G.Upload : G.Download, 13, Theme.AccentBrush),
                Ui.Text(t.Name, 12.5, FontWeights.Medium), bar, Ui.Text(text, 11.5, fg: Theme.Brush(color)).With(x => x.HorizontalAlignment = HorizontalAlignment.Right), cancel);
            if (t.Status == Transfer.State.Running && t.CurrentFile.Length > 0) ToolTipService.SetToolTip(row, t.CurrentFile);
            list.Children.Add(row);
        }
        _transfers.Child = Ui.Card(Ui.Col(8, S.Watched.Count > 0 ? watched : null, head, new ScrollViewer { Content = list, MaxHeight = 150 }), 12, 12);
    }
}
