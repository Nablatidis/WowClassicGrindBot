using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Advanced;
using SixLabors.ImageSharp.PixelFormats;

using System;
using System.Runtime.CompilerServices;

namespace Core;

/// <summary>
/// Reads the addon's resource tracker panel from the screen.
/// Modern clients (WoW Forever) hide values like energy, health and cooldowns
/// from addons, but StatusBars and Cooldown frames can still display them.
/// The panel position is fixed in UI units (TRACKER_* in Addons/DataToColor/DataToColor.lua),
/// and the data strip tells how many pixels one UI unit is.
/// </summary>
public static class SecretBars
{
    // Must match TRACKER_* in DataToColor.lua (UI units from the top left of UIParent)
    public const float TrackerX = 700;
    public const float TrackerY = 12;
    public const float TrackerWidth = 196;
    public const float TrackerHeight = 68;

    public const float CooldownX = 10;
    public const float CooldownY = 50;
    public const float CooldownSize = 12;
    public const float CooldownGap = 3;
    public const int CooldownCount = 12;

    /// <summary>Data strip cell pitch in UI units (CELL_SIZE + CELL_SPACING).</summary>
    public const float CellPitch = 2;

    /// <summary>Reported remaining cooldown (ms) while a cooldown sweep is visible.</summary>
    public const int SweepCooldownMs = 1000;

    /// <summary>Minimum share of bar pixels that must look like a bar.</summary>
    private const float MinBarCoverage = 0.7f;

    private const int FillMin = 110;
    private const int EmptyMax = 60;

    /// <summary>Grey outline around each bar (TRACKER_BAR_BORDER), 0.35 grey = 89.</summary>
    public const float BarBorder = 2;
    private const int BorderMin = 70;
    private const int BorderMax = 105;

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

    private readonly record struct BarDef(float X, float Y, float W, float H,
        int MaxCell, int Cell, bool AlwaysUseBar);

    // x, y, w, h inside the panel. Values that are visible arrive exact in the cell;
    // a hidden value arrives as 0, so the bar is used then. Target health keeps
    // sending the last visible value, so its bar is always used.
    private static readonly BarDef[] bars =
    [
        new(8, 8, 180, 8, PowerMaxCell, PowerCell, false),
        new(8, 29, 88, 6, PlayerHealthMaxCell, PlayerHealthCell, false),
        new(102, 29, 86, 6, TargetHealthMaxCell, TargetHealthCell, true),
        new(8, 41, 88, 4, ManaMaxCell, ManaCell, false),
        new(102, 41, 86, 4, PetHealthMaxCell, PetHealthCell, false),
    ];

    private static readonly bool[] cooldownActive = new bool[CooldownCount];

    /// <summary>True when the tracker panel was found on the last frame.</summary>
    public static bool Detected { get; private set; }

    /// <summary>
    /// Remaining cooldown estimate for a main action bar button, from the
    /// tracker's cooldown sweep. 0 when ready or unknown.
    /// </summary>
    public static int CooldownMs(int slotIndex)
    {
        // main bar 1-12, and the stance/stealth pages that replace it (73+)
        if (!Detected || (slotIndex >= CooldownCount && slotIndex < 72))
            return 0;

        return cooldownActive[slotIndex % CooldownCount] ? SweepCooldownMs : 0;
    }

    private readonly record struct Geometry(float OriginX, float OriginY, float Scale)
    {
        public int X(float unit) => (int)MathF.Round(OriginX + unit * Scale);
        public int Y(float unit) => (int)MathF.Round(OriginY + unit * Scale);
    }

    private static bool TryGeometry(ReadOnlySpan<DataFrame> frames, out Geometry geometry)
    {
        geometry = default;
        if (frames.Length < 2)
            return false;

        DataFrame first = frames[0];
        DataFrame last = frames[^1];
        float scale = (last.X - first.X) / ((last.Index - first.Index) * CellPitch);
        if (scale <= 0)
            return false;

        // frame positions are cell centers; cell 0 starts at UI (0, 0)
        geometry = new(first.X - scale / 2f, first.Y - scale / 2f, scale);
        return true;
    }

    /// <summary>Capture area needed for the strip plus the tracker panel.</summary>
    public static Size CaptureSize(ReadOnlySpan<DataFrame> frames, Size strip, int screenWidth, int screenHeight)
    {
        if (!TryGeometry(frames, out Geometry g))
            return strip;

        int width = Math.Max(strip.Width, g.X(TrackerX + TrackerWidth) + 3);
        int height = Math.Max(strip.Height, g.Y(TrackerY + TrackerHeight) + 3);
        return new(Math.Min(width, screenWidth), Math.Min(height, screenHeight));
    }

    [SkipLocalsInit]
    public static void Apply(Image<Bgra32> image, ReadOnlySpan<DataFrame> frames, Span<int> output)
    {
        Detected = false;
        if (!TryGeometry(frames, out Geometry g))
            return;

        Span<float> fractions = stackalloc float[bars.Length];
        for (int i = 0; i < bars.Length; i++)
        {
            BarDef bar = bars[i];
            if (!TryReadBar(image, g, TrackerX + bar.X, TrackerY + bar.Y, bar.W, bar.H, out fractions[i]))
                return; // panel not on screen (hidden, setup mode, old addon)
        }

        Detected = true;

        for (int i = 0; i < bars.Length; i++)
        {
            BarDef bar = bars[i];
            int max = output[bar.MaxCell];
            if (max <= 0 || (!bar.AlwaysUseBar && output[bar.Cell] != 0))
                continue;

            output[bar.Cell] = (int)MathF.Round(max * fractions[i]);
        }

        for (int i = 0; i < CooldownCount; i++)
        {
            float x = TrackerX + CooldownX + i * (CooldownSize + CooldownGap);
            cooldownActive[i] = ReadSweep(image, g, x, TrackerY + CooldownY);
        }
    }

    private static bool TryReadBar(Image<Bgra32> image, Geometry g,
        float x, float y, float w, float h, out float fraction)
    {
        fraction = 0;

        int py = g.Y(y + h / 2f);
        int x0 = g.X(x) + 1;
        int x1 = g.X(x + w) - 1;
        if (py < 0 || py >= image.Height || x0 < 0 || x1 >= image.Width || x1 <= x0)
            return false;

        ReadOnlySpan<Bgra32> row = image.DangerousGetPixelRowMemory(py).Span;

        // the grey outline on both ends tells the panel apart from the game world
        if (!HasBorder(row, g.X(x - BarBorder), g.X(x)) ||
            !HasBorder(row, g.X(x + w), g.X(x + w + BarBorder)))
            return false;

        int fill = 0;
        int empty = 0;
        for (int px = x0; px <= x1; px++)
        {
            int m = Brightness(row[px]);
            if (m >= FillMin)
                fill++;
            else if (m <= EmptyMax)
                empty++;
        }

        int samples = x1 - x0 + 1;
        if (fill + empty < samples * MinBarCoverage)
            return false;

        fraction = fill / (float)(fill + empty);
        return true;
    }

    /// <summary>
    /// The sweep covers the remaining part of the cooldown and always touches
    /// 12 o'clock, so a row through the upper quarter of the square crosses it.
    /// </summary>
    private static bool ReadSweep(Image<Bgra32> image, Geometry g, float x, float y)
    {
        int py = g.Y(y + CooldownSize / 4f);
        int x0 = g.X(x) + 1;
        int x1 = g.X(x + CooldownSize) - 1;
        if (py < 0 || py >= image.Height || x0 < 0 || x1 >= image.Width)
            return false;

        ReadOnlySpan<Bgra32> row = image.DangerousGetPixelRowMemory(py).Span;
        int lit = 0;
        for (int px = x0; px <= x1; px++)
        {
            if (Brightness(row[px]) >= FillMin)
                lit++;
        }
        return lit >= 2;
    }

    private static bool HasBorder(ReadOnlySpan<Bgra32> row, int from, int to)
    {
        if (from < 0 || to >= row.Length)
            return false;

        for (int px = from; px <= to; px++)
        {
            if (IsBorder(row[px]))
                return true;
        }
        return false;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static bool IsBorder(in Bgra32 p)
    {
        int m = Brightness(p);
        return m >= BorderMin && m <= BorderMax &&
            Math.Abs(p.R - p.G) < 20 && Math.Abs(p.G - p.B) < 20;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static int Brightness(in Bgra32 p) => Math.Max(p.R, Math.Max(p.G, p.B));
}
