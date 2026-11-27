using System;
using System.IO;

namespace Zterm;

/// <summary>
/// Catatan langkah update di %LOCALAPPDATA%\Zterm\updates\update.log.
/// Dipakai untuk mendiagnosis kegagalan yang tidak terlihat di UI.
/// </summary>
internal static class UpdateLog
{
    private const long MaxBytes = 256 * 1024;

    public static void Write(string message)
    {
        try
        {
            var dir = Path.Combine(Config.LocalDir, "updates");
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, "update.log");
            if (File.Exists(path) && new FileInfo(path).Length > MaxBytes)
                File.Move(path, path + ".old", true);
            File.AppendAllText(path, $"{DateTime.Now:O} {message}\n");
        }
        catch { }
    }
}
