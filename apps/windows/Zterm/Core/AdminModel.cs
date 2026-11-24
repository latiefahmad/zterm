using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using uniffi.zterm_core;

namespace Zterm;

/// <summary>Kelola Server: proses, service systemd, crontab, dan log lewat SSH. Padanan AdminModel di AdminView.swift.</summary>
internal sealed class AdminModel
{
    public enum Tab { Processes, Services, Cron, Logs }
    public enum ProcSort { Cpu, Mem, Pid }
    public enum SvcFilter { All, Running, Failed, Boot }

    public string? TargetId { get; private set; }
    public AdminSystem? System { get; private set; }
    public bool Connecting { get; private set; }
    public string? Error { get; set; }
    public Tab Current { get; set; } = Tab.Processes;

    public ServerProcess[] Processes { get; private set; } = [];
    public string ProcQuery { get; set; } = "";
    public ProcSort Sort { get; set; } = ProcSort.Cpu;
    public ServiceUnit[] Services { get; private set; } = [];
    public string SvcQuery { get; set; } = "";
    public SvcFilter Filter { get; set; } = SvcFilter.All;
    public string? SelectedService { get; private set; }
    public string? ServiceStatus { get; private set; }
    public CronLine[] Cron { get; private set; } = [];
    public bool CronLoaded { get; private set; }
    public LogSource[] Sources { get; private set; } = [];
    public string LogSource { get; set; } = "";
    public string LogUnit { get; set; } = "";
    public string LogPriority { get; set; } = "";
    public uint LogLines { get; set; } = 500;
    public List<string> LogText { get; } = [];
    public string LogQuery { get; set; } = "";
    public bool Follow { get; set; } = true;
    public bool LogViaSudo { get; private set; }
    public HashSet<string> Busy { get; } = [];
    /// <summary>Baris log yang baru ditambahkan sejak render terakhir (untuk mode ikuti).</summary>
    public int Appended { get; set; }

    public const int MaxLogLines = 5000;

    private readonly AppModel _app;
    private readonly DispatcherQueue _dq = DispatcherQueue.GetForCurrentThread();
    private ServerAdmin? _admin;
    private DispatcherQueueTimer? _poller;
    private int _generation;
    private int _tick;
    private string _logCursor = "";
    private bool _polling;

    public AdminModel(AppModel app) { _app = app; }

    public bool Connected => _admin != null && System != null;

    private void Raise(string what = "admin") => _app.Raise(what);

    public async Task Select(string? id)
    {
        var gen = ++_generation;
        var old = _admin;
        _admin = null;
        if (old != null) _ = old.Close();
        TargetId = id; System = null; Error = null;
        Processes = []; Services = []; Cron = []; CronLoaded = false; Sources = []; LogText.Clear();
        SelectedService = null; ServiceStatus = null; LogSource = ""; LogUnit = ""; _logCursor = "";
        if (id == null) { Raise(); return; }
        if (_app.SshTarget(id) is not { } target) { Error = L.T("Host tidak ditemukan"); Raise(); return; }
        Connecting = true;
        Raise();
        try
        {
            var a = await ServerAdmin.Connect(target);
            if (gen != _generation) { await a.Close(); return; }
            var sys = await a.System();
            if (gen != _generation) { await a.Close(); return; }
            _admin = a; System = sys; Connecting = false;
            Raise();
            await Load();
        }
        catch (Exception e)
        {
            if (gen != _generation) return;
            Error = Errors.Text(e); Connecting = false;
            Raise();
        }
    }

    public async Task Load()
    {
        if (_admin is not { } a) return;
        try
        {
            switch (Current)
            {
                case Tab.Processes:
                    Processes = await a.Processes();
                    break;
                case Tab.Services:
                    if (System?.Systemd != true) break;
                    Services = await a.Services();
                    if (SelectedService is { } s) await LoadStatus(s);
                    break;
                case Tab.Cron:
                    if (System?.Crontab != true) break;
                    Cron = await a.CronList();
                    CronLoaded = true;
                    break;
                case Tab.Logs:
                    if (Sources.Length == 0)
                    {
                        Sources = await a.LogSources();
                        if (LogSource.Length == 0) LogSource = Sources.FirstOrDefault()?.Id ?? "";
                    }
                    if (System?.Systemd == true && Services.Length == 0) { try { Services = await a.Services(); } catch { } }
                    await ReloadLog();
                    break;
            }
            Error = null;
        }
        catch (Exception e) { Error = Errors.Text(e); }
        Raise();
    }

    public void StartPolling()
    {
        _poller?.Stop();
        _poller = _dq.CreateTimer();
        _poller.Interval = TimeSpan.FromSeconds(2);
        _poller.Tick += async (_, _) =>
        {
            if (_polling || !Connected || _admin is not { } a) return;
            _polling = true;
            try
            {
                _tick++;
                switch (Current)
                {
                    case Tab.Processes when _tick % 2 == 0:
                        try { Processes = await a.Processes(); Raise("admin.list"); } catch { }
                        break;
                    case Tab.Services when _tick % 3 == 0:
                        try { Services = await a.Services(); Raise("admin.list"); } catch { }
                        break;
                    case Tab.Logs when Follow:
                        await AppendLog();
                        break;
                }
            }
            finally { _polling = false; }
        };
        _poller.Start();
    }

    public void StopPolling() => _poller?.Stop();

    // MARK: Proses

    public IEnumerable<ServerProcess> FilteredProcesses
    {
        get
        {
            var q = ProcQuery.Trim();
            var list = q.Length == 0 ? Processes : Processes.Where(p => $"{p.Pid} {p.User} {p.Command}".Contains(q, StringComparison.OrdinalIgnoreCase));
            return Sort switch
            {
                ProcSort.Mem => list.OrderByDescending(p => p.RssBytes),
                ProcSort.Pid => list.OrderBy(p => p.Pid),
                _ => list,
            };
        }
    }

    public async Task Kill(ServerProcess p, bool force)
    {
        if (_admin is not { } a) return;
        Busy.Add($"pid:{p.Pid}");
        Raise();
        try
        {
            await a.Kill(p.Pid, force);
            _app.Flash(force ? L.T("Proses {} dihentikan paksa", p.Pid) : L.T("Sinyal berhenti dikirim ke proses {}", p.Pid));
            await Task.Delay(400);
            try { Processes = await a.Processes(); } catch { }
        }
        catch (Exception e) { _app.Flash(Errors.Text(e)); }
        Busy.Remove($"pid:{p.Pid}");
        Raise();
    }

    // MARK: Service

    public IEnumerable<ServiceUnit> FilteredServices
    {
        get
        {
            var q = SvcQuery.Trim();
            return Services.Where(s => Filter switch
            {
                SvcFilter.Running => s.Active == "active",
                SvcFilter.Failed => s.Active == "failed",
                SvcFilter.Boot => s.Enabled == "enabled",
                _ => true,
            }).Where(s => q.Length == 0 || s.Name.Contains(q, StringComparison.OrdinalIgnoreCase) || s.Description.Contains(q, StringComparison.OrdinalIgnoreCase));
        }
    }

    public async Task LoadStatus(string name)
    {
        if (_admin is not { } a) return;
        string? s = null;
        try { s = await a.ServiceStatus(name); } catch (Exception e) { s = Errors.Text(e); }
        if (SelectedService == name) { ServiceStatus = s; Raise(); }
    }

    public void ChooseService(string? name)
    {
        SelectedService = name; ServiceStatus = null;
        Raise();
        if (name != null) _ = LoadStatus(name);
    }

    public async Task ServiceAction(string name, string action)
    {
        if (_admin is not { } a) return;
        Busy.Add("svc:" + name);
        Raise();
        try
        {
            await a.ServiceAction(name, action);
            _app.Flash(action switch
            {
                "start" => L.T("{} dinyalakan", name), "stop" => L.T("{} dihentikan", name), "restart" => L.T("{} dimulai ulang", name),
                "reload" => L.T("{} dimuat ulang", name), "enable" => L.T("{} aktif saat boot", name), "disable" => L.T("{} tidak aktif saat boot", name),
                _ => $"{name} {action}",
            });
        }
        catch (Exception e) { _app.Flash(Errors.Text(e)); }
        try { Services = await a.Services(); } catch { }
        Busy.Remove("svc:" + name);
        await LoadStatus(name);
        Raise();
    }

    public void ShowLogs(string unit)
    {
        Current = Tab.Logs;
        if (System?.Journal == true) LogSource = "journal";
        LogUnit = unit;
        Raise();
        _ = Load();
    }

    // MARK: Cron

    public IEnumerable<(int Index, CronJob Job)> Jobs => Cron.Select((l, i) => (i, l.Job)).Where(x => x.Job != null).Select(x => (x.i, x.Job!));

    private async Task SaveCron(List<CronLine> lines, string message)
    {
        if (_admin is not { } a) return;
        Busy.Add("cron");
        Raise();
        try
        {
            await a.CronSave(lines.ToArray());
            Cron = await a.CronList();
            _app.Flash(message);
        }
        catch (Exception e) { _app.Flash(Errors.Text(e)); }
        Busy.Remove("cron");
        Raise();
    }

    public Task SetJob(int? index, CronJob job)
    {
        var lines = Cron.ToList();
        if (index is { } i) lines[i] = lines[i] with { Job = job };
        else lines.Add(new CronLine("", job));
        return SaveCron(lines, index == null ? L.T("Jadwal ditambahkan") : L.T("Jadwal disimpan"));
    }

    public Task DeleteJob(int index)
    {
        var lines = Cron.ToList();
        lines.RemoveAt(index);
        return SaveCron(lines, L.T("Jadwal dihapus"));
    }

    // MARK: Log

    public async Task ReloadLog()
    {
        if (_admin is not { } a || LogSource.Length == 0) return;
        _logCursor = "";
        try
        {
            var j = LogSource == "journal";
            var c = await a.ReadLog(LogSource, LogLines, "", j ? LogUnit : "", j ? LogPriority : "");
            _logCursor = c.Cursor;
            LogViaSudo = c.ViaSudo;
            LogText.Clear();
            LogText.AddRange(Split(c.Text));
            Appended = 0;
            Error = null;
        }
        catch (Exception e) { LogText.Clear(); Error = Errors.Text(e); }
        Raise();
    }

    private async Task AppendLog()
    {
        if (_admin is not { } a || LogSource.Length == 0 || _logCursor.Length == 0) return;
        var source = LogSource;
        LogChunk c;
        try
        {
            var j = source == "journal";
            c = await a.ReadLog(source, LogLines, _logCursor, j ? LogUnit : "", j ? LogPriority : "");
        }
        catch { return; }
        if (source != LogSource) return;
        _logCursor = c.Cursor;
        var add = Split(c.Text);
        if (add.Count == 0) return;
        LogText.AddRange(add);
        Appended += add.Count;
        if (LogText.Count > MaxLogLines) { LogText.RemoveRange(0, LogText.Count - MaxLogLines); Appended = int.MaxValue; }
        Raise("admin.log");
    }

    private static List<string> Split(string s)
    {
        var lines = s.Split('\n').Select(l => l.TrimEnd('\r')).ToList();
        while (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
        return lines;
    }

    public void Close()
    {
        StopPolling();
        var a = _admin;
        _admin = null;
        if (a != null) _ = a.Close();
        _ = Select(null);
    }
}
