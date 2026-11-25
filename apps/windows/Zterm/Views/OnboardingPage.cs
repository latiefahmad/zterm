using System;
using System.Threading.Tasks;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.System;

namespace Zterm.Views;

/// <summary>Sambutan → buat password / pulihkan dari Drive → buka kunci (padanan OnboardingViews.swift).</summary>
internal sealed class OnboardingPage : Grid
{
    private readonly AppModel _m = App.Model;
    private readonly Border _card = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Width = 420 };
    private readonly Action<string> _onChange;
    private bool _busy;

    public OnboardingPage()
    {
        Background = new RadialGradientBrush
        {
            Center = new Point(0.3, 0.2), RadiusX = 0.9, RadiusY = 0.9,
            GradientStops =
            {
                new GradientStop { Color = Theme.Hex(Theme.Accent, (byte)(App.Model.IsDark ? 30 : 24)), Offset = 0 },
                new GradientStop { Color = Colors.Transparent, Offset = 1 },
            }
        };
        Children.Add(_card);
        _onChange = w => { if (w == "phase") Render(); };
        _m.Changed += _onChange;
        Render();
    }

    public void Detach() => _m.Changed -= _onChange;

    private void Render()
    {
        UIElement content = _m.Phase switch
        {
            Phase.Welcome => Welcome(),
            Phase.CreatePassword => CreatePassword(),
            Phase.Restore => Restore(),
            _ => Locked(),
        };
        _card.Child = content;
        Ui.StaggerIn(_card, 0);
    }

    private static Image Logo(double size) => new()
    {
        Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri("ms-appx:///Assets/logo.png")),
        Width = size, Height = size, HorizontalAlignment = HorizontalAlignment.Center
    };

    private static TextBlock Center(TextBlock t) { t.HorizontalAlignment = HorizontalAlignment.Center; t.TextAlignment = TextAlignment.Center; return t; }

    /// <summary>Teks yang muncul huruf demi huruf.</summary>
    private static TextBlock Typewriter(string text, int delayMs)
    {
        var t = Center(Ui.Text("", 14, fg: Theme.Text2, mono: true));
        t.MinHeight = 20;
        _ = Task.Run(async () =>
        {
            await Task.Delay(delayMs);
            for (int i = 1; i <= text.Length; i++)
            {
                var s = text[..i];
                t.DispatcherQueue.TryEnqueue(() => t.Text = s);
                await Task.Delay(38);
            }
        });
        return t;
    }

    private UIElement Welcome()
    {
        var google = Ui.Primary(L.T("Masuk dengan Google"), G.Globe, () => _ = SignIn(), large: true).With(b => b.HorizontalAlignment = HorizontalAlignment.Stretch);
        var local = Ui.Secondary(L.T("Pakai tanpa akun"), null, () => _m.SetPhase(Phase.CreatePassword)).With(b => { b.HorizontalAlignment = HorizontalAlignment.Stretch; b.Padding = new Thickness(12, 10, 12, 10); });
        var note = Ui.Row(8, Ui.Icon(G.Shield, 13, Theme.AccentBrush),
            Ui.Secondary(L.T("Data host dienkripsi di perangkatmu. Login Google hanya untuk sync lewat Google Drive milikmu."), 12, true).With(t => t.MaxWidth = 360));
        note.HorizontalAlignment = HorizontalAlignment.Center;
        return Ui.Col(14,
            Logo(92),
            Center(Ui.Text(L.T("Selamat datang di Zterm"), 28, FontWeights.Bold, wrap: true)),
            Typewriter(L.T("Semua servermu, satu terminal."), 700),
            new Border { Height = 18 },
            google, local, new Border { Height = 6 }, note);
    }

    private async Task SignIn()
    {
        if (_busy) return;
        _busy = true;
        try
        {
            var restore = await _m.SignInGoogle();
            _m.SetPhase(restore ? Phase.Restore : Phase.CreatePassword);
        }
        catch (AuthCancelledException) { }
        catch (Exception e) { _m.Flash(Errors.Text(e)); await Ui.Confirm(L.T("Login Google gagal"), Errors.Text(e), "OK", false); }
        finally { _busy = false; }
    }

    private UIElement CreatePassword()
    {
        var pw = new PasswordBox { PlaceholderText = L.T("Master password (min. 8 karakter)") };
        var confirm = new PasswordBox { PlaceholderText = L.T("Ulangi password") };
        var error = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false, IsOpen = false };
        var strength = new ProgressBar { Maximum = 4, Value = 0, Height = 4 };
        var strengthText = Ui.Secondary("", 11.5);
        pw.PasswordChanged += (_, _) =>
        {
            var s = Strength(pw.Password);
            strength.Value = s;
            strength.Foreground = Theme.Brush(s <= 1 ? Theme.Red : s == 2 ? Theme.Orange : Theme.Green);
            strengthText.Text = pw.Password.Length == 0 ? "" : s <= 1 ? L.T("Lemah") : s == 2 ? L.T("Cukup") : s == 3 ? L.T("Kuat") : L.T("Sangat kuat");
        };
        Button submit = null!;
        async void Go()
        {
            error.IsOpen = false;
            if (pw.Password.Length < 8) { error.Message = L.T("Password minimal 8 karakter"); error.IsOpen = true; return; }
            if (pw.Password != confirm.Password) { error.Message = L.T("Password tidak sama"); error.IsOpen = true; return; }
            submit.IsEnabled = false;
            try { await _m.CreateVault(pw.Password); }
            catch (Exception e) { error.Message = Errors.Text(e); error.IsOpen = true; }
            finally { submit.IsEnabled = true; }
        }
        submit = Ui.Primary(L.T("Buat vault & mulai"), G.Lock, Go, large: true).With(b => b.HorizontalAlignment = HorizontalAlignment.Stretch);
        pw.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) confirm.Focus(FocusState.Programmatic); };
        confirm.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) Go(); };
        var desc = _m.PendingAccountEmail is { } email
            ? L.T("Masuk sebagai {}. Password ini mengunci vault-mu dan tidak pernah dikirim ke Google.", email)
            : L.T("Password ini mengunci semua host dan SSH key di perangkat ini.");
        var back = Ui.Plain(Ui.Row(6, Ui.Icon(G.Back, 11, Theme.Text2), Ui.Secondary(L.T("Kembali"), 12.5)), () => _m.SetPhase(Phase.Welcome));
        back.HorizontalAlignment = HorizontalAlignment.Left;
        var warn = Ui.Row(8, Ui.Icon(G.Warning, 13, Theme.Brush(Theme.Orange)), Ui.Text(L.T("Tidak bisa dipulihkan jika lupa. Simpan di tempat aman."), 12, fg: Theme.Brush(Theme.Orange), wrap: true));
        pw.Loaded += (_, _) => pw.Focus(FocusState.Programmatic);
        return Ui.Col(12, back, Logo(64),
            Center(Ui.Text(L.T("Buat master password"), 26, FontWeights.Bold)),
            Center(Ui.Secondary(desc, 13, true)),
            new Border { Height = 8 }, pw, Ui.Columns("*,Auto", 8, strength, strengthText), confirm, error, submit, warn);
    }

    private static int Strength(string p)
    {
        int s = 0;
        if (p.Length >= 8) s++;
        if (p.Length >= 12) s++;
        if (System.Text.RegularExpressions.Regex.IsMatch(p, "[A-Z]") && System.Text.RegularExpressions.Regex.IsMatch(p, "[a-z]")) s++;
        if (System.Text.RegularExpressions.Regex.IsMatch(p, "[0-9]") && System.Text.RegularExpressions.Regex.IsMatch(p, "[^A-Za-z0-9]")) s++;
        return Math.Min(4, s);
    }

    private UIElement Restore()
    {
        var pw = new PasswordBox { PlaceholderText = "Master password" };
        var error = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false, IsOpen = false };
        Button submit = null!;
        async void Go()
        {
            error.IsOpen = false;
            submit.IsEnabled = false;
            try { await _m.Restore(pw.Password); }
            catch (Exception e) { error.Message = Errors.Text(e); error.IsOpen = true; pw.Password = ""; }
            finally { submit.IsEnabled = true; }
        }
        submit = Ui.Primary(L.T("Pulihkan vault"), G.Cloud, Go, large: true).With(b => b.HorizontalAlignment = HorizontalAlignment.Stretch);
        pw.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) Go(); };
        pw.Loaded += (_, _) => pw.Focus(FocusState.Programmatic);
        var fresh = Ui.Plain(Center(Ui.Secondary(L.T("Mulai vault baru saja"), 12.5)), () => { _m.PendingRemoteBlob = null; _m.SetPhase(Phase.CreatePassword); });
        fresh.HorizontalAlignment = HorizontalAlignment.Center;
        return Ui.Col(12, Logo(64),
            Center(Ui.Text(L.T("Vault ditemukan di Google Drive"), 24, FontWeights.Bold, wrap: true)),
            Center(Ui.Secondary(L.T("Masukkan master password yang kamu pakai di perangkat lain untuk memulihkan host dan SSH key."), 13, true)),
            new Border { Height = 8 }, pw, error, submit, fresh);
    }

    private UIElement Locked()
    {
        var pw = new PasswordBox { PlaceholderText = "Master password" };
        var error = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false, IsOpen = false };
        Button submit = null!;
        async void Go()
        {
            error.IsOpen = false;
            submit.IsEnabled = false;
            try { await _m.Unlock(pw.Password); }
            catch (Exception e) { error.Message = Errors.Text(e); error.IsOpen = true; pw.Password = ""; Shake(_card); }
            finally { submit.IsEnabled = true; }
        }
        submit = Ui.Primary(L.T("Buka vault"), G.Lock, Go, large: true).With(b => b.HorizontalAlignment = HorizontalAlignment.Stretch);
        pw.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) Go(); };
        pw.Loaded += (_, _) => pw.Focus(FocusState.Programmatic);
        var hello = Ui.Secondary(L.T("Buka dengan Windows Hello"), G.Hello, async () =>
        {
            try { await _m.UnlockWithHello(); }
            catch (AuthCancelledException) { }
            catch (Exception e) { error.Message = Errors.Text(e); error.IsOpen = true; }
        }).With(b => { b.HorizontalAlignment = HorizontalAlignment.Stretch; b.Visibility = Visibility.Collapsed; });
        _ = ShowHelloIfAvailable(hello);
        return Ui.Col(12, Logo(80),
            Center(Ui.Text(L.T("Vault terkunci"), 28, FontWeights.Bold)),
            Center(Ui.Secondary(L.T("Masukkan master password untuk melanjutkan."))),
            new Border { Height = 8 }, pw, error, submit, hello);
    }

    private static async Task ShowHelloIfAvailable(Button b)
    {
        if (HelloUnlock.HasStoredKey && await HelloUnlock.IsAvailable()) b.Visibility = Visibility.Visible;
    }

    private static void Shake(UIElement e)
    {
        var v = Microsoft.UI.Xaml.Hosting.ElementCompositionPreview.GetElementVisual(e);
        Microsoft.UI.Xaml.Hosting.ElementCompositionPreview.SetIsTranslationEnabled(e, true);
        var a = v.Compositor.CreateVector3KeyFrameAnimation();
        float[] xs = [0, -10, 9, -7, 5, -3, 0];
        for (int i = 0; i < xs.Length; i++) a.InsertKeyFrame(i / (float)(xs.Length - 1), new System.Numerics.Vector3(xs[i], 0, 0));
        a.Duration = TimeSpan.FromMilliseconds(420);
        v.StartAnimation("Translation", a);
    }
}
