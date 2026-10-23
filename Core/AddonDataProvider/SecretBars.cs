using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Advanced;
using SixLabors.ImageSharp.PixelFormats;

using System;
using System.Runtime.CompilerServices;

namespace Core;

/// <summary>
/// Reads the secret value bars the addon draws right after the data strip.
/// Modern clients (WoW Forever) hide values like energy or mob health from addons,
/// but a StatusBar can still display them. Each bar is red where filled, blue where
/// empty, and fully green when the value is not secret (then the cell value is used).
/// The filled fraction times the visible max cell gives the current value.
/// Order must match SECRET_BAR_* in Addons/DataToColor/DataToColor.lua.
/// </summary>
public static class SecretBars
{
    /// <summary>Extra physical pixels captured to the right of the last data cell.</summary>
    public const int CaptureExtraWidth = 1600;

    public const int BarCount = 5;

    /// <summary>Bars shorter than this are noise, not a bar.</summary>
    public const int MinBarPixels = 16;

    /// <summary>Allowed difference in length between bars (all bars have the same width).</summary>
    public const int BarLengthTolerance = 4;

    /// <summary>Largest gap between the strip and the first bar, and between bars.</summary>
    public const int MaxGapPixels = 24;

    private const int Bright = 150;
    private const int Dim = 90;
    private const int Dark = 60;

    // (max cell, current cell) per bar
    public const int PowerMaxCell = 12;
    public const int PowerCell = 13;
    public const int ManaMaxCell = 14;
    public const int ManaCell = 15;
    public const int PlayerHealthMaxCell = 10;
    public const int PlayerHealthCell = 11;
    public const int TargetHealthMaxCell = 18;
    public const int TargetHealthCell = 19;
    public const int PetHealthMaxCell = 38;
    public const int PetHealthCell = 39;

    private static readonly (int Max, int Current)[] cells =
    [
        (PowerMaxCell, PowerCell),
        (ManaMaxCell, ManaCell),
        (PlayerHealthMaxCell, PlayerHealthCell),
        (TargetHealthMaxCell, TargetHealthCell),
        (PetHealthMaxCell, PetHealthCell),
    ];

    private enum Kind : byte { Black, Fill, Empty, Inactive, Edge, Other }

    private struct Bar
    {
        public int Fill2;
        public int Empty2;
        public int Inactive;
        public int Length;
    }

    public static int CaptureWidth(int stripWidth, int screenWidth)
    {
        return Math.Max(stripWidth, Math.Min(stripWidth + CaptureExtraWidth, screenWidth));
    }

    [SkipLocalsInit]
    public static void Apply(Image<Bgra32> image, ReadOnlySpan<DataFrame> frames, Span<int> output)
    {
        DataFrame last = frames[^1];
        if (last.Y >= image.Height)
            return;

        ReadOnlySpan<Bgra32> row = image.DangerousGetPixelRowMemory(last.Y).Span;

        Span<Bar> bars = stackalloc Bar[BarCount];
        bars.Clear();

        int x = last.X + 1;
        // the last data cell itself can be a few pixels wide
        while (x < row.Length && Classify(row[x]) != Kind.Black)
            x++;

        for (int i = 0; i < BarCount; i++)
        {
            int gapStart = x;
            while (x < row.Length && Classify(row[x]) is Kind.Black or Kind.Other)
            {
                x++;
                if (x - gapStart > MaxGapPixels)
                    return;
            }

            ref Bar bar = ref bars[i];
            while (x < row.Length)
            {
                Kind kind = Classify(row[x]);
                if (kind == Kind.Black)
                    break;

                switch (kind)
                {
                    case Kind.Fill: bar.Fill2 += 2; break;
                    case Kind.Empty: bar.Empty2 += 2; break;
                    case Kind.Inactive: bar.Inactive++; break;
                    case Kind.Edge: bar.Fill2++; bar.Empty2++; break;
                }
                bar.Length++;
                x++;
            }

            // must end inside the captured area on a black gap
            if (x >= row.Length || bar.Length < MinBarPixels)
                return;

            if (Math.Abs(bar.Length - bars[0].Length) > BarLengthTolerance)
                return;
        }

        for (int i = 0; i < BarCount; i++)
        {
            Bar bar = bars[i];
            int active = bar.Fill2 + bar.Empty2;
            if (active <= bar.Inactive * 2)
                continue;

            (int maxCell, int currentCell) = cells[i];
            int max = output[maxCell];
            if (max <= 0)
                continue;

            output[currentCell] = (int)MathF.Round(max * bar.Fill2 / (float)active);
        }
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static Kind Classify(in Bgra32 p)
    {
        if (p.R < Dark && p.G < Dark && p.B < Dark)
            return Kind.Black;

        if (p.R > Bright && p.G < Dim && p.B < Dim)
            return Kind.Fill;

        if (p.B > Bright && p.R < Dim && p.G < Dim)
            return Kind.Empty;

        if (p.G > Bright && p.R < Dim && p.B < Dim)
            return Kind.Inactive;

        // boundary between filled (red) and empty (blue) blends to purple
        if (p.R > Dim && p.B > Dim && p.G < Dim)
            return Kind.Edge;

        return Kind.Other;
    }
}
