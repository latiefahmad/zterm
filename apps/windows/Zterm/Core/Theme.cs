using System;
using System.Globalization;
using Microsoft.UI;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;

namespace Zterm;

/// <summary>Warna & gradien Zterm — sama dengan Theme.swift di versi macOS.</summary>
internal static class Theme
{
    public static bool Dark => App.Model.IsDark;

    public static Color Hex(string? hex, byte alpha = 255)
    {
        var s = (hex ?? "").Trim().TrimStart('#');
        if (!uint.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v) || s.Length != 6) v = 0x3FD0B4;
        return Color.FromArgb(alpha, (byte)(v >> 16), (byte)(v >> 8), (byte)v);
    }

    public static string ToHex(Color c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";

    public static SolidColorBrush Brush(string hex, double opacity = 1) => new(Hex(hex, (byte)Math.Round(255 * opacity)));
    public static SolidColorBrush Brush(Color c, double opacity = 1) => new(Color.FromArgb((byte)Math.Round(c.A * opacity), c.R, c.G, c.B));

    public const string Accent = "#3FD0B4";
    public const string Accent2 = "#5B9CF5";
    public const string Accent3 = "#9D7CF2";
    public const string Green = "#4ADE80";
    public const string Orange = "#F59E0B";
    public const string Red = "#F0616D";

    /// <summary>Hitam di mode terang, putih di mode gelap (dipakai dengan opacity).</summary>
    public static SolidColorBrush Ink(double opacity) => new(Dark ? Color.FromArgb((byte)(255 * opacity), 255, 255, 255) : Color.FromArgb((byte)(255 * opacity), 0, 0, 0));

    public static SolidColorBrush Bg => Brush(Dark ? "#09090B" : "#F7F7F8");
    public static SolidColorBrush Panel => Brush(Dark ? "#0C0C0F" : "#FFFFFF");
    public static SolidColorBrush Card => Brush(Dark ? "#131316" : "#FFFFFF");
    public static SolidColorBrush CardHover => Brush(Dark ? "#18181B" : "#FAFAFA");
    public static SolidColorBrush CardStroke => Brush(Dark ? "#27272A" : "#E4E4E7");
    public static SolidColorBrush Field => Brush(Dark ? "#18181B" : "#F4F4F5");
    public static SolidColorBrush Text => Brush(Dark ? "#FAFAFA" : "#18181B");
    public static SolidColorBrush Text2 => Ink(Dark ? 0.62 : 0.56);
    public static SolidColorBrush Text3 => Ink(Dark ? 0.38 : 0.34);
    public static SolidColorBrush AccentBrush => Brush(Accent);

    public static LinearGradientBrush Gradient(params string[] hexes)
    {
        var g = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        for (int i = 0; i < hexes.Length; i++)
            g.GradientStops.Add(new GradientStop { Color = Hex(hexes[i]), Offset = hexes.Length == 1 ? 0 : (double)i / (hexes.Length - 1) });
        return g;
    }

    /// <summary>Nama lama, kini satu warna: aksen rata tanpa gradien.</summary>
    public static LinearGradientBrush BrandGradient => Gradient(Accent, Accent);

    /// <summary>Nama lama, kini satu warna: ikon host/menu memakai warna rata.</summary>
    public static LinearGradientBrush TintGradient(string hex) => Gradient(hex, hex);

    public static readonly string[] HostColors = ["#3FD0B4", "#5B9CF5", "#9D7CF2", "#F2A65A", "#F0616D", "#8BD450", "#E879C6", "#94A3B8"];
    public static readonly string[] CardPalette = ["#3FD0B4", "#22C55E", "#84CC16", "#EAB308", "#F2A65A", "#F97316", "#F0616D", "#E11D48",
                                                   "#E879C6", "#C084FC", "#9D7CF2", "#6366F1", "#5B9CF5", "#06B6D4", "#14B8A6", "#94A3B8"];

    public const string Mono = "Cascadia Mono, Consolas";
    public static FontFamily MonoFont => new(Mono);
}

/// <summary>Glyph Segoe Fluent Icons yang dipakai di app.</summary>
internal static class G
{
    public const string Server = "", Key = "", Forward = "", Folder = "", Database = "",
        Code = "", Fingerprint = "", History = "", Heart = "", Info = "", Person = "",
        Lock = "", Search = "", Add = "", Edit = "", Delete = "", Copy = "",
        Refresh = "", Play = "", Bolt = "", Eye = "", EyeOff = "", Grid = "",
        List = "", More = "", Close = "", Upload = "", Download = "", NewFolder = "",
        Up = "", Home = "", Sync = "", Cloud = "", Globe = "", Back = "",
        Next = "", Save = "", Terminal = "", Table = "", Check = "", Warning = "",
        Sparkle = "", Sun = "", Moon = "", Contrast = "", Apps = "", Document = "",
        Link = "", Bug = "", Chat = "", Hello = "", SignOut = "", Tag = "",
        Text = "", Clock = "", Filter = "", Export = "", Structure = "", First = "",
        Prev = "", NextPage = "", Last = "", ChevronDown = "", ChevronRight = "",
        Shield = "", Rename = "", Permissions = "", Stop = "", People = "", Stack = "", AddFriend = "", Mail = "", RemovePerson = "", Checklist = "", Link2 = "", Gauge = "", Wrench = "", Settings = "";
}
