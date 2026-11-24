using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using uniffi.zterm_core;

namespace Zterm;

/// <summary>Docker: container, image, dan proyek Compose — di PC ini atau server lewat SSH. Padanan DockerModel di DockerView.swift.</summary>
internal sealed class DockerModel
{
    public enum Tab { Containers, Volumes, Images, Networks }

    /// <summary>null = Docker di PC ini; selain itu id host.</summary>
    public string? TargetId { get; private set; }
    public bool Connected { get; private set; }
    public bool Loading { get; private set; }
    public string? Error { get; set; }
    public DockerInfo? Info { get; private set; }
    public DockerContainer[] Containers { get; private set; } = [];
    public Dictionary<string, DockerStat> Stats { get; private set; } = [];
    public DockerImage[] Images { get; private set; } = [];
    public ComposeProject[] Projects { get; private set; } = [];
    public DockerVolume[] Volumes { get; private set; } = [];
    public DockerNetwork[] Networks { get; private set; } = [];
    /// <summary>Proyek Compose yang dilipat.</summary>
    public HashSet<string> Collapsed { get; } = [];
    public string? SelectedId { get; private set; }
    public DockerDetail? Detail { get; private set; }
    public DockerContainer? Selected => Containers.FirstOrDefault(c => c.Id == SelectedId);
    private string? _hostname;
    public HashSet<string> Busy { get; } = [];
    public Tab Current { get; set; } = Tab.Containers;
    public string Query { get; set; } = "";

    private readonly AppModel _app;
    private readonly DispatcherQueue _dq;
    private DockerClient? _client;
    private DispatcherQueueTimer? _poller;
    private int _generation;
    private int _tick;

    public DockerModel(AppModel app)
    {
        _app = app;
        _dq = DispatcherQueue.GetForCurrentThread();
    }

    private void Raise() => _app.Raise("docker");

    public async Task Select(string? id)
    {
        var gen = ++_generation;
        var old = _client;
        _client = null;
        TargetId = id; Connected = false; Info = null; Error = null; SelectedId = null; Detail = null;
        Containers = []; Images = []; Projects = []; Volumes = []; Networks = []; Stats = [];
        _hostname = id == null ? null : _app.HostById(id)?.Hostname;
        Loading = true;
        Raise();
        if (old != null) _ = old.Close();
        try
        {
            DockerClient c;
            if (id != null)
            {
                var t = _app.SshTarget(id) ?? throw new CoreException.NotFound();
                c = await DockerClient.Connect(t);
            }
            else c = DockerClient.Local();
            if (gen != _generation) { await c.Close(); return; }
            _client = c;
            Connected = true;
            await Refresh();
        }
        catch (Exception e)
        {
            if (gen != _generation) return;
            Error = Errors.Text(e); Loading = false; Raise();
        }
    }

    public async Task Refresh()
    {
        if (_client is not { } c) return;
        Loading = true; Raise();
        try
        {
            var info = c.Info(); var cs = c.Containers(); var im = c.Images(); var pr = c.ComposeProjects(); var vo = c.Volumes(); var ne = c.Networks();
            await Task.WhenAll(info, cs, im, pr, vo, ne);
            Info = info.Result; Containers = cs.Result; Images = im.Result; Projects = pr.Result; Volumes = vo.Result; Networks = ne.Result; Error = null;
        }
        catch (Exception e) { Error = Errors.Text(e); }
        Loading = false;
        Raise();
        await RefreshStats();
        if (SelectedId is { } sel) await LoadDetail(sel);
    }

    public void Choose(DockerContainer? c)
    {
        SelectedId = c?.Id;
        if (c == null) Detail = null;
        Raise();
        if (c != null) _ = LoadDetail(c.Id);
    }

    private async Task LoadDetail(string id)
    {
        if (_client is not { } c) return;
        try
        {
            var d = await c.Inspect(id);
            if (SelectedId == id) { Detail = d; Raise(); }
        }
        catch { }
    }

    public Task RemoveVolume(DockerVolume v) => Run("vol:" + v.Name, x => x.RemoveVolume(v.Name));

    /// <summary>Link port di browser: localhost untuk PC ini, hostname server untuk host SSH.</summary>
    public string Url(ushort port) => $"http://{_hostname ?? "localhost"}:{port}";

    public int Count(Tab t) => t switch
    {
        Tab.Containers => Containers.Length, Tab.Volumes => Volumes.Length, Tab.Images => Images.Length, _ => Networks.Length,
    };

    public async Task RefreshStats()
    {
        if (_client is not { } c || !Containers.Any(x => x.State == "running")) return;
        try
        {
            var s = await c.Stats();
            Stats = s.GroupBy(x => x.Id).ToDictionary(g => g.Key, g => g.First());
            Raise();
        }
        catch { }
    }

    public void StartPolling()
    {
        _poller?.Stop();
        _poller = _dq.CreateTimer();
        _poller.Interval = TimeSpan.FromSeconds(4);
        _poller.Tick += async (s, e) =>
        {
            if (!Connected || _client is not { } c) return;
            if (++_tick % 3 == 0) { try { Containers = await c.Containers(); } catch { } }
            await RefreshStats();
        };
        _poller.Start();
    }

    public void StopPolling() => _poller?.Stop();

    private async Task Run(string key, Func<DockerClient, Task> op)
    {
        if (_client is not { } c || !Busy.Add(key)) return;
        Raise();
        try { await op(c); Error = null; }
        catch (Exception e) { Error = Errors.Text(e); }
        Busy.Remove(key);
        await Refresh();
    }

    public Task Action(DockerContainer c, string action)
    {
        if (action == "rm" && SelectedId == c.Id) Choose(null);
        return Run(c.Id, x => x.ContainerAction(c.Id, action));
    }

    public Task Compose(string name, string action)
    {
        var files = Projects.FirstOrDefault(p => p.Name == name)?.ConfigFiles ?? "";
        return Run("compose:" + name, async x => await x.ComposeAction(name, files, action));
    }

    public Task RemoveImage(DockerImage i) => Run("img:" + i.Id, x => x.RemoveImage(i.Id));

    public async Task<string> Logs(string id, uint tail)
    {
        if (_client is not { } c) return "";
        try { return await c.Logs(id, tail); } catch (Exception e) { return Errors.Text(e); }
    }

    /// <summary>Buka shell di dalam container: tab SSH ke host, atau terminal lokal (PowerShell).</summary>
    public void OpenShell(DockerContainer c)
    {
        if (_client == null) return;
        string cmd;
        try { cmd = _client.ExecCommand(c.Id); } catch (Exception e) { Error = Errors.Text(e); Raise(); return; }
        if (TargetId is { } id) _app.Connect([id], cmd); else _app.OpenLocalTerminal(null, cmd);
    }

    public IEnumerable<DockerContainer> Filtered
    {
        get
        {
            var q = Query.Trim();
            return q.Length == 0 ? Containers : Containers.Where(x =>
                new[] { x.Name, x.Image, x.Project, x.Ports }.Any(v => v.Contains(q, StringComparison.OrdinalIgnoreCase)));
        }
    }

    /// <summary>Dikelompokkan per proyek Compose; container lepas di grup terakhir.</summary>
    public IEnumerable<IGrouping<string, DockerContainer>> Groups =>
        Filtered.GroupBy(x => x.Project).OrderBy(g => g.Key.Length == 0).ThenBy(g => g.Key);
}
