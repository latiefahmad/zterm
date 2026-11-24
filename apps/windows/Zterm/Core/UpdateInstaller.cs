using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace Zterm;

/// <summary>
/// Mengunduh installer dari aset GitHub Release, memeriksa checksum bila tersedia,
/// lalu menjalankan helper yang menunggu Zterm keluar, memasang, dan membuka Zterm lagi.
/// </summary>
internal static class UpdateInstaller
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(15) };

    public static async Task<string> DownloadAsync(AvailableUpdate update, IProgress<double>? progress, CancellationToken ct = default)
    {
        if (update.Download is not { Length: > 0 } url || update.AssetName is not { Length: > 0 } name)
            throw new InvalidOperationException(L.T("Pembaruan tidak tersedia untuk arsitektur ini"));

        var dir = Path.Combine(Config.LocalDir, "updates");
        Directory.CreateDirectory(dir);
        Cleanup(dir);

        var safeName = string.Concat(name.Select(ch => Path.GetInvalidFileNameChars().Contains(ch) ? '_' : ch));
        var dest = Path.Combine(dir, safeName);
        var part = dest + ".part";
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.UserAgent.ParseAdd("Zterm-Windows");
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
            if (!resp.IsSuccessStatusCode)
                throw new InvalidOperationException(L.T("Gagal mengunduh pembaruan: HTTP {}", (int)resp.StatusCode));

            var total = resp.Content.Headers.ContentLength ?? update.Size;
            string actual;
            await using (var src = await resp.Content.ReadAsStreamAsync(ct))
            await using (var dst = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, true))
            {
                var buffer = new byte[1 << 16];
                long read = 0;
                using var sha = SHA256.Create();
                int n;
                while ((n = await src.ReadAsync(buffer.AsMemory(), ct)) > 0)
                {
                    await dst.WriteAsync(buffer.AsMemory(0, n), ct);
                    sha.TransformBlock(buffer, 0, n, null, 0);
                    read += n;
                    if (total > 0) progress?.Report(Math.Clamp((double)read / total, 0, 1));
                }
                sha.TransformFinalBlock([], 0, 0);
                actual = Convert.ToHexString(sha.Hash ?? []).ToLowerInvariant();
                await dst.FlushAsync(ct);
                if (update.Size > 0 && read != update.Size)
                    throw new InvalidOperationException(L.T("Paket pembaruan tidak valid"));
            }

            if (update.Digest is { Length: > 7 } expected &&
                expected.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase) &&
                !actual.Equals(expected[7..], StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException(L.T("Checksum pembaruan tidak cocok"));

            File.Move(part, dest, true);
            return dest;
        }
        catch
        {
            try { File.Delete(part); } catch { }
            throw;
        }
    }

    /// <summary>Jalankan helper .cmd yang menunggu proses ini keluar, memasang, lalu membuka ulang.</summary>
    public static void Launch(string installerPath)
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var installed = Path.Combine(local, "Programs", "Zterm", "Zterm.exe");
        var appPath = File.Exists(installed) ? installed : Environment.ProcessPath;
        if (string.IsNullOrEmpty(appPath))
            throw new InvalidOperationException(L.T("Lokasi Zterm tidak ditemukan"));

        var script = Path.Combine(Path.GetTempPath(), $"zterm-update-{Guid.NewGuid():N}.cmd");
        var logDir = Path.Combine(Config.LocalDir, "updates");
        Directory.CreateDirectory(logDir);
        var log = Path.Combine(logDir, $"install-{DateTime.Now:yyyyMMdd-HHmmss}.log");
        File.WriteAllText(script, HelperScript.ReplaceLineEndings("\r\n"));

        var psi = new ProcessStartInfo("cmd.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            WorkingDirectory = Path.GetTempPath(),
        };
        psi.ArgumentList.Add("/c");
        psi.ArgumentList.Add(script);
        psi.ArgumentList.Add(Environment.ProcessId.ToString());
        psi.ArgumentList.Add(installerPath);
        psi.ArgumentList.Add(appPath!);
        psi.ArgumentList.Add(log);
        try
        {
            Process.Start(psi);
        }
        catch
        {
            try { File.Delete(script); } catch { }
            throw;
        }
    }

    private static void Cleanup(string dir)
    {
        try
        {
            foreach (var old in Directory.GetFiles(dir, "*.exe").Concat(Directory.GetFiles(dir, "*.part")))
                try { File.Delete(old); } catch { }
        }
        catch { }
    }

    private const string HelperScript = """
@echo off
setlocal
set "PID=%~1"
set "INSTALLER=%~2"
set "APP=%~3"
set "LOG=%~4"

:wait
tasklist /FI "PID eq %PID%" /NH 2>nul | find "%PID%" >nul
if not errorlevel 1 (
    ping -n 2 127.0.0.1 >nul
    goto wait
)

start "" /wait "%INSTALLER%" /VERYSILENT /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS /NORESTART /LOG="%LOG%"
if exist "%APP%" start "" "%APP%"
del "%~f0" >nul 2>&1
endlocal
""";
}
