using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Zterm;

/// <summary>Bahasa app: Indonesia (teks asli di kode) atau Inggris (kamus en.json dari folder i18n repo, di-embed).
/// Pilihan disimpan di PC ini (Settings "app.language": system | id | en); berlaku setelah app dibuka ulang.</summary>
internal static class L10n
{
    public const string Key = "app.language";
    public static readonly string[] Choices = ["system", "id", "en"];

    public static string Choice
    {
        get => Settings.Str(Key) is { } v && Choices.Contains(v) ? v : "system";
        set => Settings.Set(Key, value);
    }

    /// <summary>"id" atau "en", ditetapkan sekali saat app dibuka.</summary>
    public static readonly string Resolved = Resolve();
    public static bool English => Resolved == "en";

    private static readonly Dictionary<string, string> Table = Load();
    private static readonly List<(Regex Re, string Out)> Patterns = Table
        .Where(kv => kv.Key.Contains("{}"))
        .Select(kv => (new Regex("^" + string.Join("(.+?)", kv.Key.Split("{}").Select(Regex.Escape)) + "$", RegexOptions.Singleline), kv.Value))
        .OrderByDescending(p => p.Item1.ToString().Replace("(.+?)", "").Length)
        .ToList();

    private static string Resolve()
    {
        if (Environment.GetEnvironmentVariable("ZTERM_LANG") is "id" or "en") return Environment.GetEnvironmentVariable("ZTERM_LANG")!;
        return Choice switch
        {
            "id" => "id",
            "en" => "en",
            _ => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName is "id" or "in" ? "id" : "en",
        };
    }

    private static Dictionary<string, string> Load()
    {
        if (!English) return [];
        try
        {
            using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("en.json");
            if (s == null) return [];
            return JsonSerializer.Deserialize<Dictionary<string, string>>(s) ?? [];
        }
        catch { return []; }
    }

    public static string Text(string s) => English && Table.TryGetValue(s, out var t) ? t : s;

    /// <summary>Terjemahkan pesan utuh (mis. error dari core) memakai entri persis atau berpola ({} = teks apa saja).</summary>
    public static string Message(string s)
    {
        if (!English || s.Length == 0) return s;
        if (Match(s) is { } t) return t;
        // App sering menaikkan huruf pertama pesan core ("server tidak…" → "Server tidak…")
        if (char.IsUpper(s[0]) && Match(char.ToLowerInvariant(s[0]) + s[1..]) is { } t2 && t2.Length > 0)
            return char.ToUpperInvariant(t2[0]) + t2[1..];
        return s;
    }

    private static string? Match(string s)
    {
        if (Table.TryGetValue(s, out var t)) return t;
        foreach (var (re, outText) in Patterns)
        {
            var m = re.Match(s);
            if (!m.Success) continue;
            var result = outText;
            for (int i = 1; i < m.Groups.Count; i++)
            {
                var at = result.IndexOf("{}", StringComparison.Ordinal);
                if (at < 0) break;
                result = result[..at] + Message(m.Groups[i].Value) + result[(at + 2)..];
            }
            return result;
        }
        return null;
    }

    public static string Title(string choice) => choice switch
    {
        "id" => "Bahasa Indonesia",
        "en" => "English",
        _ => L.T("Ikuti sistem"),
    };
}

/// <summary>Singkatan: <c>L.T("Backup {} selesai", name)</c> untuk teks UI, <c>L.Msg(pesan)</c> untuk pesan dari core/server.</summary>
internal static class L
{
    public static string T(string s, params object?[] args)
    {
        var o = L10n.Text(s);
        foreach (var a in args)
        {
            var at = o.IndexOf("{}", StringComparison.Ordinal);
            if (at < 0) break;
            o = o[..at] + (a?.ToString() ?? "") + o[(at + 2)..];
        }
        return o;
    }

    public static string Msg(string s) => L10n.Message(s);
}
