using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;

namespace Zterm;

/// <summary>Ikon Phosphor Duotone: dua path 256x256 yang diskalakan bersama lewat Viewbox.</summary>
internal static class Ph
{
    private static readonly Regex Token = new(@"([MLCZ])|(-?\d*\.?\d+)", RegexOptions.Compiled);

    /// <summary>
    /// Parser khusus data Phosphor hasil generator: perintah absolut M/L/C/Z.
    /// WinUI tidak punya Geometry.Parse, dan satu Geometry tidak boleh dipakai di beberapa Path.
    /// Karena itu geometri selalu dibuat baru untuk setiap ikon.
    /// </summary>
    private static Geometry GeometryFor(string data)
    {
        var path = new PathGeometry { FillRule = FillRule.Nonzero };
        PathFigure? figure = null;
        var command = '\0';
        var numbers = new List<double>(6);

        void Flush()
        {
            switch (command)
            {
                case 'M' when numbers.Count >= 2:
                    var first = true;
                    while (numbers.Count >= 2)
                    {
                        if (first)
                        {
                            figure = new PathFigure { StartPoint = new Point(numbers[0], numbers[1]), IsFilled = true };
                            path.Figures.Add(figure);
                            first = false;
                        }
                        else
                        {
                            figure.Segments.Add(new LineSegment { Point = new Point(numbers[0], numbers[1]) });
                        }
                        numbers.RemoveRange(0, 2);
                    }
                    break;
                case 'L':
                    while (numbers.Count >= 2)
                    {
                        figure?.Segments.Add(new LineSegment { Point = new Point(numbers[0], numbers[1]) });
                        numbers.RemoveRange(0, 2);
                    }
                    break;
                case 'C':
                    while (numbers.Count >= 6)
                    {
                        figure?.Segments.Add(new BezierSegment
                        {
                            Point1 = new Point(numbers[0], numbers[1]),
                            Point2 = new Point(numbers[2], numbers[3]),
                            Point3 = new Point(numbers[4], numbers[5]),
                        });
                        numbers.RemoveRange(0, 6);
                    }
                    break;
                case 'Z':
                    if (figure != null) figure.IsClosed = true;
                    break;
            }
            numbers.Clear();
        }

        foreach (Match match in Token.Matches(data))
        {
            if (match.Groups[1].Success)
            {
                Flush();
                command = match.Groups[1].Value[0];
                if (command == 'Z' && figure != null) figure.IsClosed = true;
            }
            else
            {
                numbers.Add(double.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture));
            }
        }
        Flush();

        return path;
    }

    public static Viewbox Icon(string name, double size = 16, Brush? fg = null, double secondaryOpacity = 0.2)
    {
        var brush = fg ?? Theme.Text;
        var canvas = new Grid { Width = 256, Height = 256 };
        if (PhosphorData.All.TryGetValue(name, out var glyph))
        {
            canvas.Children.Add(new Path { Data = GeometryFor(glyph.Secondary), Fill = brush, Opacity = secondaryOpacity });
            canvas.Children.Add(new Path { Data = GeometryFor(glyph.Primary), Fill = brush });
        }
        return new Viewbox
        {
            Child = canvas,
            Width = size,
            Height = size,
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    public static Button Btn(string name, string tip, System.Action click, Brush? fg = null, double size = 15)
    {
        var b = new Button
        {
            Content = Icon(name, size, fg ?? Theme.Text2),
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(7),
            CornerRadius = new CornerRadius(7),
            MinWidth = 0,
            MinHeight = 0,
        };
        b.Resources["ButtonBackgroundPointerOver"] = Theme.Ink(0.07);
        b.Resources["ButtonBackgroundPressed"] = Theme.Ink(0.12);
        ToolTipService.SetToolTip(b, tip);
        b.Click += (_, _) => click();
        return b;
    }
}

/// <summary>
/// Peta glyph Segoe lama (G.*) ke Phosphor. Dipakai selama migrasi halaman,
/// supaya helper Ui.Icon/TintIcon/EmptyState otomatis memakai ikon baru.
/// </summary>
internal static class PhGlyph
{
    private static readonly Dictionary<string, string> Map = Build();

    private static Dictionary<string, string> Build()
    {
        var m = new Dictionary<string, string>();
        void Add(string glyph, string name) { if (!string.IsNullOrEmpty(glyph)) m.TryAdd(glyph, name); }
        Add(G.Server, "hard-drives");
        Add(G.Key, "key");
        Add(G.Forward, "arrows-left-right");
        Add(G.Folder, "folder");
        Add(G.Database, "database");
        Add(G.Code, "file-code");
        Add(G.Fingerprint, "fingerprint");
        Add(G.History, "arrow-counter-clockwise");
        Add(G.Heart, "heart");
        Add(G.Info, "info");
        Add(G.Person, "user");
        Add(G.Lock, "lock-simple");
        Add(G.Search, "magnifying-glass");
        Add(G.Add, "plus");
        Add(G.Edit, "pencil-simple");
        Add(G.Delete, "trash");
        Add(G.Copy, "copy");
        Add(G.Refresh, "arrows-clockwise");
        Add(G.Play, "play");
        Add(G.Bolt, "lightning");
        Add(G.Eye, "eye");
        Add(G.EyeOff, "eye-slash");
        Add(G.Grid, "squares-four");
        Add(G.List, "list-dashes");
        Add(G.More, "dots-three");
        Add(G.Close, "x");
        Add(G.Upload, "upload-simple");
        Add(G.Download, "download-simple");
        Add(G.NewFolder, "folder-plus");
        Add(G.Up, "arrow-up");
        Add(G.Home, "house");
        Add(G.Sync, "arrows-clockwise");
        Add(G.Cloud, "cloud");
        Add(G.Globe, "globe");
        Add(G.Back, "arrow-left");
        Add(G.Next, "arrow-right");
        Add(G.Save, "floppy-disk");
        Add(G.Terminal, "terminal-window");
        Add(G.Table, "table");
        Add(G.Check, "check");
        Add(G.Warning, "warning");
        Add(G.Sparkle, "sparkle");
        Add(G.Sun, "sun");
        Add(G.Moon, "moon");
        Add(G.Contrast, "circle-half");
        Add(G.Apps, "squares-four");
        Add(G.Document, "file");
        Add(G.Link, "link-simple");
        Add(G.Link2, "link-simple");
        Add(G.Bug, "bug");
        Add(G.Chat, "chat-circle-dots");
        Add(G.Hello, "sparkle");
        Add(G.SignOut, "sign-out");
        Add(G.Tag, "tag");
        Add(G.Text, "file-text");
        Add(G.Clock, "clock");
        Add(G.Filter, "funnel");
        Add(G.Export, "arrow-square-out");
        Add(G.Structure, "tree-structure");
        Add(G.First, "caret-double-left");
        Add(G.Prev, "caret-left");
        Add(G.NextPage, "caret-right");
        Add(G.Last, "caret-double-right");
        Add(G.ChevronDown, "caret-down");
        Add(G.ChevronRight, "caret-right");
        Add(G.Shield, "shield-check");
        Add(G.Rename, "pencil-simple");
        Add(G.Permissions, "key");
        Add(G.Stop, "stop");
        Add(G.People, "users");
        Add(G.Stack, "stack");
        Add(G.AddFriend, "user-plus");
        Add(G.Mail, "envelope-simple");
        Add(G.RemovePerson, "user-minus");
        Add(G.Checklist, "list-checks");
        Add(G.Gauge, "gauge");
        Add(G.Wrench, "wrench");
        Add(G.Settings, "gear-six");
        return m;
    }

    public static string? Name(string? glyph) =>
        glyph != null && Map.TryGetValue(glyph, out var name) ? name : null;
}
