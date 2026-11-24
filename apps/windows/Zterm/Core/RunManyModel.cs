using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using uniffi.zterm_core;

namespace Zterm;

/// <summary>"Jalankan perintah di banyak server": paralel (maks. 8), hasil per server. Padanan RunManyModel di RunManyView.swift.</summary>
internal sealed class RunManyModel
{
    public enum Status { Waiting, Running, Ok, Failed, Timeout, Error }

    public sealed class Row
    {
        public required string Id { get; init; }
        public Status State { get; set; } = Status.Waiting;
        public uint? ExitCode { get; set; }
        public string Output { get; set; } = "";
        public string? Error { get; set; }
        public ulong DurationMs { get; set; }
        public bool Truncated { get; set; }
        public bool Done => State is not (Status.Waiting or Status.Running);
        public bool Success => State == Status.Ok;
    }

    public const int Parallel = 8;

    public string Command { get; set; } = "";
    public HashSet<string> Targets { get; }
    public uint Timeout { get; set; } = 120;
    public List<Row> Rows { get; private set; } = [];
    public bool Running { get; private set; }
    public HashSet<string> Expanded { get; } = [];
    public event Action? Changed;

    private readonly AppModel _app;
    private readonly DispatcherQueue _dq = DispatcherQueue.GetForCurrentThread();
    private CancellationTokenSource? _cts;

    public RunManyModel(AppModel app, IEnumerable<string> targets) { _app = app; Targets = [.. targets]; }

    public int OkCount => Rows.Count(r => r.Success);
    public int FailCount => Rows.Count(r => r.Done && !r.Success);
    public int PendingCount => Rows.Count(r => !r.Done);

    /// <summary>Jalankan di semua target terpilih, atau hanya <paramref name="only"/> (mis. ulang yang gagal).</summary>
    public void Run(IReadOnlyList<string>? only = null)
    {
        var cmd = Command.Trim();
        if (cmd.Length == 0 || Running) return;
        var ids = only ?? _app.Hosts.Select(h => h.Id).Where(Targets.Contains).ToList();
        if (ids.Count == 0) return;
        if (only == null) { Rows = ids.Select(id => new Row { Id = id }).ToList(); Expanded.Clear(); }
        else foreach (var id in ids) { var i = Rows.FindIndex(r => r.Id == id); if (i >= 0) Rows[i] = new Row { Id = id }; }
        Running = true;
        var cts = new CancellationTokenSource();
        _cts = cts;
        var jobs = ids.Select(id => (id, target: _app.SshTarget(id))).ToList();
        var timeout = Timeout;
        Changed?.Invoke();
        _ = Task.Run(async () =>
        {
            using var gate = new SemaphoreSlim(Parallel);
            var tasks = jobs.Select(async j =>
            {
                try { await gate.WaitAsync(cts.Token); } catch (OperationCanceledException) { return; }
                try
                {
                    if (cts.IsCancellationRequested) return;
                    Post(() => Find(j.id)!.State = Status.Running);
                    RemoteRun? r = null; string? err = null;
                    try
                    {
                        if (j.target == null) err = L.T("Host tidak ditemukan");
                        else r = await ZtermCoreMethods.RunRemote(j.target, cmd, timeout);
                    }
                    catch (Exception e) { err = Errors.Text(e); }
                    if (!cts.IsCancellationRequested) Post(() => Finish(j.id, r, err));
                }
                finally { gate.Release(); }
            });
            await Task.WhenAll(tasks);
            Post(() =>
            {
                foreach (var row in Rows.Where(r => !r.Done)) { row.State = Status.Error; row.Error = L.T("Dibatalkan"); }
                Running = false;
            });
        });
    }

    public void Cancel() => _cts?.Cancel();

    private Row? Find(string id) => Rows.FirstOrDefault(r => r.Id == id);

    private void Post(Action a) => _dq.TryEnqueue(() => { a(); Changed?.Invoke(); });

    private void Finish(string id, RemoteRun? r, string? err)
    {
        if (Find(id) is not { } row) return;
        if (r != null)
        {
            row.Output = r.Output; row.DurationMs = r.DurationMs; row.Truncated = r.Truncated; row.ExitCode = r.ExitCode;
            row.State = r.TimedOut ? Status.Timeout : r.ExitCode == 0 ? Status.Ok : Status.Failed;
        }
        else { row.State = Status.Error; row.Error = err ?? L.T("Gagal"); }
        if (!row.Success) Expanded.Add(id);
    }

    public static string Label(Row r) => r.State switch
    {
        Status.Waiting => L.T("Menunggu"),
        Status.Running => L.T("Berjalan…"),
        Status.Ok => L.T("Sukses"),
        Status.Failed => r.ExitCode is { } c ? L.T("Gagal · exit {}", c) : L.T("Gagal"),
        Status.Timeout => L.T("Timeout"),
        _ => r.Error ?? L.T("Gagal"),
    };

    /// <summary>Semua output, dipisah per server — untuk disalin.</summary>
    public string Report() => string.Join("\n\n", Rows.Select(r =>
        $"=== {_app.HostById(r.Id)?.Title() ?? r.Id} — {Label(r)} ===\n{r.Output}"));
}
