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
