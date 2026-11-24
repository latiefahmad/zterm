using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using uniffi.zterm_core;

namespace Zterm;

/// <summary>Progress unduhan komponen Server Lokal (thread Rust → UI, throttle ±10 fps).</summary>
internal sealed class StackProgress(DispatcherQueue dq, Action<double, string> update) : TransferProgress
{
    private volatile bool _cancelled;
    private DateTime _last = DateTime.MinValue;
    private readonly object _lock = new();

    public void Cancel() => _cancelled = true;
    public bool IsCancelled() => _cancelled;

    public void OnProgress(ulong done, ulong total, string currentFile)
    {
        lock (_lock)
        {
            var now = DateTime.UtcNow;
            if ((now - _last).TotalMilliseconds < 100 && done != total) return;
            _last = now;
        }
        var frac = total > 0 ? (double)done / total : 0;
        var label = total > 0 ? $"{currentFile} · {Ui.Bytes(done)} / {Ui.Bytes(total)}" : currentFile;
        dq.TryEnqueue(() => update(frac, label));
    }
}

/// <summary>Server Lokal: web server (Apache / Nginx + PHP) dan database lokal — padanan StackModel di LocalServerView.swift.</summary>
internal sealed class StackModel
{
    public sealed record Download(double Fraction, string Label);

    public LocalStack? Stack { get; }
    public StackComponent[] Components { get; private set; } = [];
    public StackService[] Services { get; private set; } = [];
    public StackSettings Settings { get; private set; }
    public Dictionary<string, Download> Downloads { get; } = [];
    public HashSet<string> Busy { get; } = [];
    public string? Error { get; set; }

    private readonly AppModel _app;
    private readonly DispatcherQueue _dq;
    private readonly Dictionary<string, StackProgress> _bridges = [];
    private DispatcherQueueTimer? _poller;

    public StackModel(AppModel app)
    {
        _app = app;
        _dq = DispatcherQueue.GetForCurrentThread();
        var root = Path.Combine(Config.LocalDir, "stack");
#if DEBUG
        if (Environment.GetEnvironmentVariable("ZTERM_STACK_ROOT") is { Length: > 0 } r) root = r;
#endif
        try { Stack = new LocalStack(root); } catch (Exception e) { Error = Errors.Text(e); }
        Settings = Stack?.Settings() ?? new StackSettings("nginx", 8080, Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Sites"), 3306, 5432, 27017);
        Refresh();
    }

    private void Raise() => _app.Raise("stack");

    public StackComponent? Component(string id) => Components.FirstOrDefault(c => c.Id == id);
    public StackService? Service(string id) => Services.FirstOrDefault(s => s.Id == id);
    public bool AnyRunning => Services.Any(s => s.Running);
    public string RootPath => Stack?.RootPath() ?? "";
    public string WebUrl => $"http://localhost:{Settings.WebPort}/";
    public bool NeedsVcRuntime => Stack?.NeedsVcRuntime() == true;

    public void Refresh()
    {
        if (Stack == null) return;
        Components = Stack.Components();
        Services = Stack.Services();
    }

    /// <summary>Perbarui status tiap 2 detik selama halaman terbuka (layanan bisa berhenti sendiri).</summary>
    public void StartPolling()
    {
        _poller?.Stop();
        _poller = _dq.CreateTimer();
        _poller.Interval = TimeSpan.FromSeconds(2);
        _poller.Tick += (s, e) =>
        {
            var before = string.Join(",", Services.Select(x => $"{x.Id}{x.Running}{x.Error}"));
            Refresh();
            if (before != string.Join(",", Services.Select(x => $"{x.Id}{x.Running}{x.Error}"))) Raise();
        };
        _poller.Start();
    }

    public void StopPolling() => _poller?.Stop();

    public void SaveSettings(StackSettings s)
    {
        try { Stack?.SetSettings(s); Settings = s; Error = null; }
        catch (Exception e) { Error = Errors.Text(e); }
        Refresh();
        Raise();
    }

    public void Install(string id)
    {
        if (Stack == null || Downloads.ContainsKey(id)) return;
        var bridge = new StackProgress(_dq, (f, l) => { Downloads[id] = new Download(f, l); Raise(); });
        _bridges[id] = bridge;
        Downloads[id] = new Download(0, L.T("Menyiapkan unduhan…"));
        Refresh();
        Raise();
        _ = Task.Run(async () =>
        {
            string? err = null;
            try { await Stack.Install(id, bridge); }
            catch (CoreException.Cancelled) { }
            catch (Exception e) { err = Errors.Text(e); }
            _dq.TryEnqueue(() =>
            {
                Downloads.Remove(id);
                _bridges.Remove(id);
                Error = err;
                Refresh();
                Raise();
            });
        });
    }

    public void CancelInstall(string id) { if (_bridges.TryGetValue(id, out var b)) b.Cancel(); }

    public void Uninstall(string id)
    {
        try { Stack?.Uninstall(id); Error = null; } catch (Exception e) { Error = Errors.Text(e); }
        Refresh();
        Raise();
    }

    public void InstallMissing(string service)
    {
        foreach (var id in Service(service)?.Missing ?? []) Install(id);
    }

    public async Task Toggle(string service)
    {
        if (Stack == null || !Busy.Add(service)) return;
        Raise();
        var running = Service(service)?.Running == true;
        try
        {
            if (running) await Stack.Stop(service); else await Stack.Start(service);
        }
        catch { /* error tampil di kartu layanannya (StackService.Error) */ }
        Busy.Remove(service);
        Refresh();
        Raise();
    }

    public async Task StartAll() { foreach (var s in Services.Where(s => !s.Running && s.Missing.Length == 0).ToList()) await Toggle(s.Id); }
    public async Task StopAll() { foreach (var s in Services.Where(s => s.Running).ToList()) await Toggle(s.Id); }

    public string Log(string service) => Stack?.LogTail(service, 60) ?? "";

    /// <summary>Unduh & jalankan installer Microsoft Visual C++ Runtime (diperlukan Apache, PHP, MySQL).</summary>
    public async Task InstallVcRuntime()
    {
        try
        {
            var file = Path.Combine(Path.GetTempPath(), "vc_redist.x64.exe");
            var bytes = await GoogleAuth.Http.GetByteArrayAsync("https://aka.ms/vs/17/release/vc_redist.x64.exe");
            await File.WriteAllBytesAsync(file, bytes);
            var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(file, "/install /passive /norestart") { UseShellExecute = true, Verb = "runas" });
            if (p != null) await p.WaitForExitAsync();
            Error = null;
        }
        catch (System.ComponentModel.Win32Exception) { Error = L.T("Pemasangan Visual C++ Runtime dibatalkan"); }
        catch (Exception e) { Error = L.T("Gagal memasang Visual C++ Runtime: {}", e.Message); }
        Refresh();
        Raise();
    }
}
