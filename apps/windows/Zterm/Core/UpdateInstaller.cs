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
/// lalu menjalankan installer secara senyap. Installer menutup Zterm yang masih berjalan,
/// memasang versi baru, dan membuka Zterm lagi lewat entri [Run] di Zterm.iss.
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
        UpdateLog.Write($"Mulai unduh {name} ({update.Size} bytes) dari {url}");

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
                long lastReport = -1000;
                var clock = Stopwatch.StartNew();
                using var sha = SHA256.Create();
                int n;
                while ((n = await src.ReadAsync(buffer.AsMemory(), ct)) > 0)
                {
                    await dst.WriteAsync(buffer.AsMemory(0, n), ct);
                    sha.TransformBlock(buffer, 0, n, null, 0);
                    read += n;
                    if (total > 0)
                    {
                        // Jangan banjiri UI dengan satu laporan per potongan 64 KB.
                        // Cukup ~12 laporan/detik; bilah progress menghaluskan sisanya.
                        var now = clock.ElapsedMilliseconds;
                        if (read >= total || now - lastReport >= 80)
                        {
                            lastReport = now;
                            progress?.Report(Math.Clamp((double)read / total, 0, 1));
                        }
                    }
                }
                sha.TransformFinalBlock([], 0, 0);
                actual = Convert.ToHexString(sha.Hash ?? []).ToLowerInvariant();
                await dst.FlushAsync(ct);
                if (update.Size > 0 && read != update.Size)
                    throw new InvalidOperationException(L.T("Paket pembaruan tidak valid"));
                progress?.Report(1);
            }

            if (update.Digest is { Length: > 7 } expected &&
                expected.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase) &&
                !actual.Equals(expected[7..], StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException(L.T("Checksum pembaruan tidak cocok"));

            File.Move(part, dest, true);
            UpdateLog.Write($"Unduhan tersimpan: {dest} (sha256 {actual})");
            return dest;
        }
        catch (Exception e)
        {
            UpdateLog.Write("Unduh gagal: " + e);
            try { File.Delete(part); } catch { }
            throw;
        }
    }

    /// <summary>
    /// Jalankan installer secara senyap. Inno Setup menutup Zterm yang masih memakai file lama
    /// (CloseApplications=force), memasang, lalu membuka Zterm lagi karena entri [Run] juga
    /// dijalankan saat mode senyap. Tidak ada helper .cmd yang harus bertahan setelah app keluar.
    /// </summary>
    public static void Launch(string installerPath)
    {
        var logDir = Path.Combine(Config.LocalDir, "updates");
        Directory.CreateDirectory(logDir);
        var log = Path.Combine(logDir, $"install-{DateTime.Now:yyyyMMdd-HHmmss}.log");

        var psi = new ProcessStartInfo(installerPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            WorkingDirectory = Path.GetDirectoryName(installerPath) ?? Path.GetTempPath(),
            // Tanpa /SUPPRESSMSGBOXES supaya kegagalan pemasangan terlihat, bukan senyap.
            Arguments = "/VERYSILENT /NORESTART /CLOSEAPPLICATIONS /FORCECLOSEAPPLICATIONS /LOG=\"" + log + "\"",
        };
        UpdateLog.Write($"Menjalankan installer: {installerPath} (log: {log})");
        Process.Start(psi);
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
}
