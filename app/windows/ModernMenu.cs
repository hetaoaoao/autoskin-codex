using Microsoft.Win32;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace AutoSkin.Windows;

internal sealed record ModernMenuPalette(
    Color Background,
    Color Foreground,
    Color Secondary,
    Color Hover,
    Color Pressed,
    Color Border,
    Color Separator,
    Color Accent)
{
    public static ModernMenuPalette Current()
    {
        var light = true;
        try
        {
            using var personalize = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            light = Convert.ToInt32(personalize?.GetValue("AppsUseLightTheme", 1)) != 0;
        }
        catch { }
        return light
            ? new ModernMenuPalette(
                Color.FromArgb(252, 252, 252), Color.FromArgb(31, 31, 31), Color.FromArgb(96, 96, 96),
                Color.FromArgb(238, 238, 238), Color.FromArgb(226, 226, 226), Color.FromArgb(218, 218, 218),
                Color.FromArgb(226, 226, 226), Color.FromArgb(22, 171, 196))
            : new ModernMenuPalette(
                Color.FromArgb(44, 44, 44), Color.FromArgb(245, 245, 245), Color.FromArgb(190, 190, 190),
                Color.FromArgb(59, 59, 59), Color.FromArgb(69, 69, 69), Color.FromArgb(72, 72, 72),
                Color.FromArgb(75, 75, 75), Color.FromArgb(75, 201, 190));
    }
}

internal sealed class ModernContextMenuStrip : ContextMenuStrip
{
    private const int DwmWindowCornerPreference = 33;
    private const int DwmRound = 2;
    private const int DropShadowClassStyle = 0x00020000;
    private readonly ModernMenuPalette palette;

    public ModernContextMenuStrip()
    {
        palette = ModernMenuPalette.Current();
        Renderer = new ModernMenuRenderer(palette);
        BackColor = palette.Background;
        ForeColor = palette.Foreground;
        Font = CreateMenuFont();
        ShowImageMargin = false;
        ShowCheckMargin = true;
        Padding = new Padding(6);
        AutoSize = true;
    }

    protected override CreateParams CreateParams
    {
        get
        {
            var parameters = base.CreateParams;
            parameters.ClassStyle |= DropShadowClassStyle;
            return parameters;
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        var preference = DwmRound;
        _ = DwmSetWindowAttribute(Handle, DwmWindowCornerPreference, ref preference, sizeof(int));
    }

    protected override void OnOpening(System.ComponentModel.CancelEventArgs e)
    {
        ApplyModernStyle(this, palette, Renderer);
        base.OnOpening(e);
    }

    public void RefreshStyle(ToolStripDropDown dropDown) => ApplyModernStyle(dropDown, palette, Renderer);

    public static void StyleItems(ToolStripItemCollection items)
    {
        foreach (ToolStripItem item in items)
        {
            if (item is ToolStripSeparator separator)
            {
                separator.AutoSize = false;
                separator.Height = 9;
                separator.Margin = Padding.Empty;
                continue;
            }
            item.AutoSize = false;
            item.Height = 36;
            item.Width = Math.Max(item.Width, 238);
            item.Padding = new Padding(7, 0, 10, 0);
            item.Margin = new Padding(0, 1, 0, 1);
            if (item is ToolStripMenuItem menuItem && menuItem.HasDropDownItems)
                StyleItems(menuItem.DropDownItems);
        }
    }

    private static void ApplyModernStyle(ToolStripDropDown dropDown, ModernMenuPalette palette, ToolStripRenderer renderer)
    {
        dropDown.Renderer = renderer;
        dropDown.BackColor = palette.Background;
        dropDown.ForeColor = palette.Foreground;
        dropDown.Font = CreateMenuFont();
        dropDown.Padding = new Padding(6);
        if (dropDown is ToolStripDropDownMenu menu)
        {
            menu.ShowImageMargin = false;
            menu.ShowCheckMargin = true;
        }
        StyleItems(dropDown.Items);
        foreach (ToolStripItem item in dropDown.Items)
        {
            item.ForeColor = palette.Foreground;
            if (item is ToolStripMenuItem menuItem)
                ApplyModernStyle(menuItem.DropDown, palette, renderer);
        }
    }

    private static Font CreateMenuFont()
    {
        try { return new Font("Segoe UI Variable Text", 10f, FontStyle.Regular, GraphicsUnit.Point); }
        catch { return new Font("Segoe UI", 10f, FontStyle.Regular, GraphicsUnit.Point); }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int valueSize);
}

internal sealed class ModernMenuRenderer(ModernMenuPalette palette) : ToolStripProfessionalRenderer(new ModernMenuColorTable(palette))
{
    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var brush = new SolidBrush(palette.Background);
        e.Graphics.FillRectangle(brush, e.AffectedBounds);
    }

    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
    {
        using var pen = new Pen(palette.Border);
        var rectangle = new Rectangle(0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
        using var path = RoundedRectangle(rectangle, 7);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.DrawPath(pen, path);
    }

    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
    {
        if (!e.Item.Selected && !e.Item.Pressed) return;
        var color = e.Item.Pressed ? palette.Pressed : palette.Hover;
        var rectangle = new Rectangle(3, 1, e.Item.Width - 6, e.Item.Height - 2);
        using var path = RoundedRectangle(rectangle, 5);
        using var brush = new SolidBrush(color);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.FillPath(brush, path);
    }

    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
    {
        using var pen = new Pen(palette.Separator);
        var y = e.Item.Height / 2;
        e.Graphics.DrawLine(pen, 12, y, e.Item.Width - 12, y);
    }

    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
    {
        var x = e.ArrowRectangle.Left + 2;
        var y = e.ArrowRectangle.Top + e.ArrowRectangle.Height / 2;
        using var pen = new Pen(palette.Secondary, 1.5f) { StartCap = System.Drawing.Drawing2D.LineCap.Round, EndCap = System.Drawing.Drawing2D.LineCap.Round };
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.DrawLines(pen, new Point[] { new(x, y - 4), new(x + 4, y), new(x, y + 4) });
    }

    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
    {
        var center = new Point(e.ImageRectangle.Left + e.ImageRectangle.Width / 2, e.ImageRectangle.Top + e.ImageRectangle.Height / 2);
        using var accent = new SolidBrush(palette.Accent);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.FillEllipse(accent, center.X - 8, center.Y - 8, 16, 16);
        using var pen = new Pen(Color.White, 1.8f) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        e.Graphics.DrawLines(pen, new Point[] { new(center.X - 4, center.Y), new(center.X - 1, center.Y + 3), new(center.X + 5, center.Y - 4) });
    }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        e.TextColor = e.Item.Enabled ? palette.Foreground : palette.Secondary;
        base.OnRenderItemText(e);
    }

    private static GraphicsPath RoundedRectangle(Rectangle rectangle, int radius)
    {
        var diameter = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(rectangle.Left, rectangle.Top, diameter, diameter, 180, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Top, diameter, diameter, 270, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rectangle.Left, rectangle.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}

internal sealed class ModernMenuColorTable(ModernMenuPalette palette) : ProfessionalColorTable
{
    public override Color ToolStripDropDownBackground => palette.Background;
    public override Color ImageMarginGradientBegin => palette.Background;
    public override Color ImageMarginGradientMiddle => palette.Background;
    public override Color ImageMarginGradientEnd => palette.Background;
    public override Color MenuBorder => palette.Border;
    public override Color MenuItemBorder => Color.Transparent;
    public override Color MenuItemSelected => palette.Hover;
    public override Color MenuItemSelectedGradientBegin => palette.Hover;
    public override Color MenuItemSelectedGradientEnd => palette.Hover;
    public override Color MenuItemPressedGradientBegin => palette.Pressed;
    public override Color MenuItemPressedGradientEnd => palette.Pressed;
    public override Color SeparatorDark => palette.Separator;
    public override Color SeparatorLight => palette.Separator;
}
