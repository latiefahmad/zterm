using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using uniffi.zterm_core;

namespace Zterm;

/// <summary>Progress backup/restore: jumlah byte (thread Rust → UI).</summary>
internal sealed class BackupProgress(DispatcherQueue dq, Action<ulong, ulong> update) : TransferProgress
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
            if ((now - _last).TotalMilliseconds < 150 && !(total > 0 && done == total)) return;
            _last = now;
        }
        dq.TryEnqueue(() => update(done, total));
    }
}

/// <summary>Jadwal backup otomatis per koneksi (tersimpan di PC ini, bukan di vault).</summary>
internal sealed class BackupSchedule
{
    public string Frequency { get; set; } = "off";   // off | daily | weekly
    public int Hour { get; set; } = 2;
    public int Keep { get; set; } = 7;
    public bool Drive { get; set; }
    public DateTimeOffset? Last { get; set; }
    public string? LastError { get; set; }
}

/// <summary>Backup & restore database ke Documents\Zterm Backups (opsional Google Drive) + jadwal. Padanan BackupModel di BackupView.swift.</summary>
internal sealed class BackupModel
{
    public sealed class Job { public bool Restore; public ulong Bytes; public ulong Total; public string Stage = ""; }
    public sealed record Item(string Path, string Name, long Size, DateTime Date);

    public Dictionary<string, Job> Jobs { get; } = [];
    private Dictionary<string, BackupSchedule> _schedules = [];
    private readonly Dictionary<string, BackupProgress> _progress = [];
    private readonly AppModel _app;
    private readonly DispatcherQueue _dq = DispatcherQueue.GetForCurrentThread();
    private DispatcherQueueTimer? _timer;
    private const string Key = "backup.schedules";

    public BackupModel(AppModel app)
    {
        _app = app;
        try
        {
            if (Settings.Str(Key) is { } json) _schedules = JsonSerializer.Deserialize<Dictionary<string, BackupSchedule>>(json) ?? [];
        }
        catch { }
    }

    private void Raise() => _app.Raise("backup");

    public static string Root => Environment.GetEnvironmentVariable("ZTERM_BACKUP_DIR") is { Length: > 0 } d ? d
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Zterm Backups");

    public static string Folder(DbConnection c)
    {
        var safe = new string(c.Title().Select(ch => char.IsLetterOrDigit(ch) || "-_ ".Contains(ch) ? ch : '_').ToArray()).Trim();
        return Path.Combine(Root, safe.Length == 0 ? c.Id : safe);
    }

    public BackupSchedule Schedule(string id) => _schedules.TryGetValue(id, out var s) ? s : new BackupSchedule();

    public void SetSchedule(string id, BackupSchedule s)
    {
        _schedules[id] = s;
        Settings.Set(Key, JsonSerializer.Serialize(_schedules));
        Raise();
    }

    public List<Item> Items(DbConnection c)
    {
        var dir = Folder(c);
        if (!Directory.Exists(dir)) return [];
        return new DirectoryInfo(dir).GetFiles("*.gz").Select(f => new Item(f.FullName, f.Name, f.Length, f.LastWriteTime)).OrderByDescending(i => i.Date).ToList();
    }

    public void Cancel(string id) { if (_progress.TryGetValue(id, out var p)) p.Cancel(); }

    private BackupProgress Progress(string id) => new(_dq, (done, total) =>
    {
        if (Jobs.TryGetValue(id, out var j)) { j.Bytes = done; j.Total = total; _app.Raise("backup.progress"); }
    });

    public async Task<bool> Backup(DbConnection c, bool scheduled = false)
    {
        if (Jobs.ContainsKey(c.Id)) return false;
        var db = c.Database.Length == 0 ? "" : "_" + new string(c.Database.Select(ch => char.IsLetterOrDigit(ch) || "-_".Contains(ch) ? ch : '_').ToArray());
        var dest = Path.Combine(Folder(c), $"{DateTime.Now:yyyy-MM-dd_HHmm}{db}{ZtermCoreMethods.BackupExtension(c.Engine)}");
        var p = Progress(c.Id);
        _progress[c.Id] = p;
        Jobs[c.Id] = new Job { Stage = L.T("Membuat backup…") };
        Raise();
        var s = Schedule(c.Id);
        var ok = false;
        try
        {
            var r = await ZtermCoreMethods.BackupDatabase(c, _app.SshTarget(c.SshHostId), dest, [_app.Stack.RootPath], p);
            Prune(c, s.Keep);
            var note = L.T("Backup {} selesai · {}", c.Title(), Ui.Bytes(r.Bytes));
            if (s.Drive)
            {
                Jobs[c.Id].Stage = L.T("Mengunggah ke Google Drive…");
                Jobs[c.Id].Bytes = 0;
                Raise();
                try { await ZtermCoreMethods.DriveUploadBackup(await GoogleTokens.ValidAccessToken(), r.Path, p); note += L.T(" · tersimpan juga di Google Drive"); }
                catch (Exception e) { note += L.T(" · gagal unggah ke Drive: {}", Errors.Text(e)); }
            }
            s.Last = DateTimeOffset.Now; s.LastError = null;
            SetSchedule(c.Id, s);
            _app.Flash(note);
            ok = true;
        }
        catch (CoreException.Cancelled) { _app.Flash(L.T("Backup dibatalkan")); }
        catch (Exception e)
        {
            s.LastError = Errors.Text(e);
            if (scheduled) s.Last = DateTimeOffset.Now;
            SetSchedule(c.Id, s);
            _app.Flash(L.T("Backup {} gagal: {}", c.Title(), Errors.Text(e)));
            if (scheduled) Notifier.Send(L.T("Backup {} gagal", c.Title()), Errors.Text(e), "backup:" + c.Id);
        }
        Jobs.Remove(c.Id);
        _progress.Remove(c.Id);
        Raise();
        return ok;
    }

    public async Task Restore(DbConnection c, Item item)
    {
        if (Jobs.ContainsKey(c.Id)) return;
        var p = Progress(c.Id);
        _progress[c.Id] = p;
        Jobs[c.Id] = new Job { Restore = true, Stage = L.T("Memulihkan {}…", item.Name) };
        Raise();
        try
        {
            await ZtermCoreMethods.RestoreDatabase(c, _app.SshTarget(c.SshHostId), item.Path, [_app.Stack.RootPath], p);
            _app.Flash(L.T("{} dipulihkan dari {}", c.Title(), item.Name));
        }
        catch (CoreException.Cancelled) { _app.Flash(L.T("Restore dibatalkan")); }
        catch (Exception e) { _app.Flash(L.T("Restore gagal: {}", Errors.Text(e))); }
        Jobs.Remove(c.Id);
        _progress.Remove(c.Id);
        Raise();
    }

    public void Delete(Item item)
    {
        try { File.Delete(item.Path); } catch { }
        Raise();
    }

    /// <summary>Simpan hanya <paramref name="keep"/> backup terbaru (yang lama dihapus).</summary>
    private void Prune(DbConnection c, int keep)
    {
        if (keep <= 0) return;
        foreach (var old in Items(c).Skip(keep))
        {
            try { File.Delete(old.Path); } catch { }
        }
    }

    // MARK: Jadwal

    public void StartTimer()
    {
        _timer?.Stop();
        _timer = _dq.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(60);
        _timer.Tick += async (_, _) => await RunDue();
        _timer.Start();
    }

    public void StopTimer() => _timer?.Stop();

    public async Task RunDue()
    {
        foreach (var c in _app.Databases.ToList())
        {
            var s = Schedule(c.Id);
            if (s.Frequency == "off" || !ZtermCoreMethods.BackupSupported(c.Engine) || Jobs.ContainsKey(c.Id) || !IsDue(s, DateTimeOffset.Now)) continue;
            await Backup(c, true);
        }
    }

    public static bool IsDue(BackupSchedule s, DateTimeOffset now)
    {
        var todayAt = new DateTimeOffset(now.Year, now.Month, now.Day, s.Hour, 0, 0, now.Offset);
        var slot = now >= todayAt ? todayAt : todayAt.AddDays(-1);
        var period = s.Frequency == "weekly" ? TimeSpan.FromDays(7) : TimeSpan.FromDays(1);
        if (s.Last is not { } last) return true;
        return last < slot && now - last >= period - TimeSpan.FromHours(1);
    }
}
