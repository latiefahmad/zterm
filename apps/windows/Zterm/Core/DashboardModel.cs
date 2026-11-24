using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using uniffi.zterm_core;

namespace Zterm;

/// <summary>Satu server di Dashboard: koneksi SSH (ServerMonitor), sampel tiap 5 detik, sambung ulang sendiri. Padanan ServerTile di DashboardView.swift.</summary>
internal sealed class ServerTile
{
    public enum Status { Connecting, Online, Offline }
    public enum Level { Ok, Warn, Critical }

    public Host Host { get; set; }
    public string Id => Host.Id;
    public Status State { get; private set; } = Status.Connecting;
    public string? Error { get; private set; }
    public ServerInfo? Info { get; set; }
    public ServerSample? Sample { get; private set; }
    public List<double> Cpu { get; } = [];
    public double Rx { get; private set; }
    public double Tx { get; private set; }
    public bool Running => _cts != null;

    private readonly DispatcherQueue _dq = DispatcherQueue.GetForCurrentThread();
    private readonly Action _changed;
    private CancellationTokenSource? _cts;
    private ServerMonitor? _monitor;
    private (ServerSample s, DateTime t)? _prev;
    /// <summary>Kejadian yang layak dinotifikasi: (judul, isi, kunci).</summary>
    public Action<string, string, string>? OnAlert { get; set; }
    private bool _wasOnline;
    /// <summary>Metrik yang sedang di atas 90% (sudah dinotifikasi; dilepas lagi di bawah 85%).</summary>
    private readonly HashSet<string> _alerting = [];

    public ServerTile(Host host, Action changed) { Host = host; _changed = changed; }

    public void Start(SshTarget? target)
    {
        if (_cts != null) return;
        if (State == Status.Offline) State = Status.Connecting;
        var cts = new CancellationTokenSource();
        _cts = cts;
        _ = Task.Run(async () =>
        {
            while (!cts.IsCancellationRequested)
            {
                try
                {
                    if (target == null) throw new CoreException.NotFound();
                    var m = await ServerMonitor.Connect(target);
                    if (cts.IsCancellationRequested) { await m.Close(); return; }
                    _monitor = m;
                    if (Info == null)
                    {
                        try { var info = await m.Info(); Post(cts, () => Info = info); } catch { }
                    }
                    while (!cts.IsCancellationRequested)
                    {
                        var s = await m.Sample();
                        Post(cts, () => Add(s));
                        await Task.Delay(5000, cts.Token);
                    }
                }
                catch (OperationCanceledException) { return; }
                catch (Exception e)
                {
                    if (cts.IsCancellationRequested) return;
                    var m = _monitor;
                    _monitor = null;
                    if (m != null) { try { await m.Close(); } catch { } }
                    _prev = null;
                    var msg = Errors.Text(e);
                    Post(cts, () =>
                    {
                        if (State == Status.Online) OnAlert?.Invoke(L.T("{} tidak bisa dihubungi", Host.Title()), msg, "down:" + Id);
                        _alerting.Clear();
                        State = Status.Offline; Error = msg;
                    });
                    try { await Task.Delay(20000, cts.Token); } catch (OperationCanceledException) { return; }
                }
            }
        });
    }

    public void Stop()
    {
        _cts?.Cancel();
        _cts = null;
        var m = _monitor;
        _monitor = null;
        if (m != null) _ = Task.Run(async () => { try { await m.Close(); } catch { } });
    }

    public void Restart(SshTarget? target)
    {
        Stop();
        State = Status.Connecting;
        Error = null;
        _changed();
        Start(target);
    }

    private void Post(CancellationTokenSource cts, Action a) => _dq.TryEnqueue(() =>
    {
        if (cts.IsCancellationRequested) return;
        a();
        _changed();
    });

    private void Add(ServerSample s)
    {
        var now = DateTime.UtcNow;
        double rx = 0, tx = 0;
        if (_prev is { } p && s.NetRxBytes >= p.s.NetRxBytes && s.NetTxBytes >= p.s.NetTxBytes)
        {
            var dt = Math.Max(0.5, (now - p.t).TotalSeconds);
            rx = (s.NetRxBytes - p.s.NetRxBytes) / dt;
            tx = (s.NetTxBytes - p.s.NetTxBytes) / dt;
        }
        _prev = (s, now);
        if (State == Status.Offline && _wasOnline) OnAlert?.Invoke(L.T("{} kembali online", Host.Title()), L.T("Server bisa dihubungi lagi."), "down:" + Id);
        _wasOnline = true;
        Sample = s; State = Status.Online; Error = null; Rx = rx; Tx = tx;
        Cpu.Add(s.CpuPercent);
        if (Cpu.Count > 30) Cpu.RemoveRange(0, Cpu.Count - 30);
        CheckAlerts(s);
    }

    /// <summary>Notifikasi sekali saat CPU / RAM / disk melewati 90%; aktif lagi setelah turun di bawah 85%.</summary>
    private void CheckAlerts(ServerSample s)
    {
        var metrics = new (string Name, double F, string Detail)[]
        {
            ("CPU", Cpu.Count >= 3 ? CpuNow / 100 : 0, L.T("rata-rata 15 detik terakhir")),
            ("RAM", MemFraction, L.T("{} dari {} terpakai", Ui.Bytes(s.MemUsedBytes), Ui.Bytes(s.MemTotalBytes))),
            ("Disk", DiskFraction, L.T("{} dari {} terpakai", Ui.Bytes(s.DiskUsedBytes), Ui.Bytes(s.DiskTotalBytes))),
        };
        foreach (var (name, f, detail) in metrics)
        {
            if (f >= 0.9 && _alerting.Add(name)) OnAlert?.Invoke($"{Host.Title()}: {name} {f * 100:0}%", detail, $"{name}:{Id}");
            else if (f < 0.85) _alerting.Remove(name);
        }
    }

    // MARK: Kesehatan

    /// <summary>CPU rata-rata 3 sampel terakhir — lonjakan sesaat tidak langsung dianggap masalah.</summary>
    public double CpuNow => Cpu.Count == 0 ? 0 : Cpu.TakeLast(3).Average();
    public double MemFraction => Sample is { MemTotalBytes: > 0 } s ? (double)s.MemUsedBytes / s.MemTotalBytes : 0;
    public double DiskFraction => Sample is { DiskTotalBytes: > 0 } s ? (double)s.DiskUsedBytes / s.DiskTotalBytes : 0;

    public static Level LevelOf(double f) => f >= 0.9 ? Level.Critical : f >= 0.75 ? Level.Warn : Level.Ok;

    public Level Health => State != Status.Online ? Level.Ok
        : (Level)new[] { (int)LevelOf(CpuNow / 100), (int)LevelOf(MemFraction), (int)LevelOf(DiskFraction) }.Max();

    public List<string> Issues
    {
        get
        {
            var o = new List<string>();
            if (State != Status.Online) return o;
            if (LevelOf(CpuNow / 100) == Level.Critical) o.Add($"CPU {CpuNow:0}%");
            if (LevelOf(MemFraction) == Level.Critical) o.Add($"RAM {MemFraction * 100:0}%");
            if (LevelOf(DiskFraction) == Level.Critical) o.Add($"Disk {DiskFraction * 100:0}%");
            return o;
        }
    }

    public bool NeedsAttention => State == Status.Offline || Health == Level.Critical;
}

/// <summary>Dashboard semua server. Padanan DashboardModel di DashboardView.swift.</summary>
internal sealed class DashboardModel
{
    public enum Filter { All, Attention, Offline }

    public Dictionary<string, ServerTile> Tiles { get; } = [];
    public HashSet<string> Selection { get; } = [];
    public Filter Current { get; set; } = Filter.All;
    /// <summary>Pantau terus di latar belakang & kirim notifikasi (tersimpan di PC ini).</summary>
    public bool Alerts
    {
        get => Settings.Bool(Settings.DashboardAlerts, false);
        set => Settings.Set(Settings.DashboardAlerts, value);
    }
    public string Query { get; set; } = "";

    private readonly AppModel _app;
    public DashboardModel(AppModel app) { _app = app; }

    private void Raise() => _app.Raise("dashboard");

    /// <summary>Sambungkan semua host (host baru ikut, yang dihapus dilepas).</summary>
    public void Start()
    {
        var ids = _app.Hosts.Select(h => h.Id).ToHashSet();
        foreach (var id in Tiles.Keys.Where(k => !ids.Contains(k)).ToList()) { Tiles[id].Stop(); Tiles.Remove(id); }
        Selection.IntersectWith(ids);
        foreach (var h in _app.Hosts)
        {
            if (!Tiles.TryGetValue(h.Id, out var t))
            {
                t = new ServerTile(h, Raise) { OnAlert = (title, body, key) => { if (Alerts) Notifier.Send(title, body, key); } };
                Tiles[h.Id] = t;
            }
            else if (!t.Host.Equals(h))
            {
                var o = t.Host;
                var reconnect = o.Hostname != h.Hostname || o.Port != h.Port || o.Username != h.Username || o.Auth != h.Auth || o.KeyId != h.KeyId || o.Password != h.Password;
                t.Host = h;
                if (reconnect) { t.Info = null; t.Restart(_app.SshTarget(h.Id)); continue; }
            }
            t.Start(_app.SshTarget(h.Id));
        }
    }

    public void Stop() { foreach (var t in Tiles.Values) t.Stop(); }

    /// <summary>Saat vault dikunci: putus semua dan lupakan datanya.</summary>
    public void Reset() { Stop(); Tiles.Clear(); Selection.Clear(); }

    public void RetryOffline()
    {
        foreach (var t in Tiles.Values.Where(t => t.State == ServerTile.Status.Offline).ToList()) t.Restart(_app.SshTarget(t.Id));
    }

    public void Retry(ServerTile t) => t.Restart(_app.SshTarget(t.Id));

    public void Toggle(string id)
    {
        if (!Selection.Remove(id)) Selection.Add(id);
        Raise();
    }

    public List<ServerTile> Ordered
    {
        get
        {
            var q = Query.Trim();
            return _app.Hosts.Select(h => Tiles.GetValueOrDefault(h.Id)).OfType<ServerTile>()
                .Where(t => Current switch
                {
                    Filter.Attention => t.NeedsAttention || t.Health == ServerTile.Level.Warn,
                    Filter.Offline => t.State == ServerTile.Status.Offline,
                    _ => true,
                })
                .Where(t => q.Length == 0 || new[] { t.Host.Title(), t.Host.Hostname, t.Host.Group ?? "", t.Info?.Os ?? "" }
                    .Any(v => v.Contains(q, StringComparison.OrdinalIgnoreCase)))
                .ToList();
        }
    }

    public int Online => Tiles.Values.Count(t => t.State == ServerTile.Status.Online);
    public int Attention => Tiles.Values.Count(t => t.NeedsAttention);
    public List<string> SelectedIds => _app.Hosts.Select(h => h.Id).Where(Selection.Contains).ToList();
}
