using System.Drawing.Drawing2D;
using System.Diagnostics;
using System.Security.Cryptography;

namespace AutoSkin.Windows;

internal static class Program
{
    [STAThread]
    private static async Task Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Length > 0 && args[0].Equals("--doctor", StringComparison.OrdinalIgnoreCase))
        {
            var output = args.Length > 1 ? Path.GetFullPath(args[1]) : Path.Combine(Environment.CurrentDirectory, "autoskin-windows-doctor.json");
            Environment.ExitCode = await new AutoSkinService().WriteDoctorReportAsync(output);
            return;
        }
        if (SelfInstaller.InstallAndRelaunchIfNeeded()) return;
        using var mutex = new Mutex(true, "Local\\CodexAutoSkin.Tray", out var firstInstance);
        if (!firstInstance) return;
        Application.Run(new TrayApplicationContext());
    }
}

internal static class SelfInstaller
{
    public static bool InstallAndRelaunchIfNeeded()
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("AutoSkin executable path is unavailable.");
        var appRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexAutoSkin", "app");
        if (PathWithin(executable, appRoot)) return false;
        var hash = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(executable)))[..12].ToLowerInvariant();
        var destination = Path.Combine(appRoot, hash);
        var installedExecutable = Path.Combine(destination, "AutoSkin.exe");
        if (!File.Exists(installedExecutable))
        {
            Directory.CreateDirectory(appRoot);
            var staging = Path.Combine(appRoot, $".{hash}.next-{Environment.ProcessId}");
            if (Directory.Exists(staging)) Directory.Delete(staging, true);
            CopyDirectory(AppContext.BaseDirectory, staging);
            try { Directory.Move(staging, destination); }
            catch when (Directory.Exists(destination)) { Directory.Delete(staging, true); }
        }
        if (!File.Exists(installedExecutable)) throw new InvalidOperationException("The installed AutoSkin executable is missing.");
        Process.Start(new ProcessStartInfo(installedExecutable, "--installed") { UseShellExecute = true });
        return true;
    }

    private static void CopyDirectory(string source, string destination)
    {
        var root = new DirectoryInfo(source);
        if (root.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new InvalidOperationException($"Refusing reparse point: {source}");
        Directory.CreateDirectory(destination);
        foreach (var file in root.GetFiles())
        {
            if (file.Name.Equals("doctor.json", StringComparison.OrdinalIgnoreCase)) continue;
            file.CopyTo(Path.Combine(destination, file.Name), true);
        }
        foreach (var directory in root.GetDirectories())
        {
            if (directory.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new InvalidOperationException($"Refusing reparse point: {directory.FullName}");
            CopyDirectory(directory.FullName, Path.Combine(destination, directory.Name));
        }
    }

    private static bool PathWithin(string path, string root) => Path.GetFullPath(path).StartsWith(
        Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar,
        StringComparison.OrdinalIgnoreCase);
}

internal sealed class TrayApplicationContext : ApplicationContext
{
    private readonly AutoSkinService service = new();
    private readonly NotifyIcon tray;
    private readonly ToolStripMenuItem themes = new("Themes");
    private readonly System.Windows.Forms.Timer refreshTimer = new() { Interval = 10_000 };
    private int busy;

    public TrayApplicationContext()
    {
        tray = new NotifyIcon
        {
            Icon = CreatePaletteIcon(),
            Text = "AutoSkin for Codex",
            Visible = true,
            ContextMenuStrip = BuildMenu()
        };
        tray.DoubleClick += (_, _) => _ = RunActionAsync("Apply AutoSkin", service.EnsureReadyAsync);
        refreshTimer.Tick += async (_, _) => await RefreshAsync();
        refreshTimer.Start();
        _ = RunActionAsync("Automatic AutoSkin setup", service.EnsureReadyAsync, showSuccess: false);
    }

    private ContextMenuStrip BuildMenu()
    {
        var menu = new ModernContextMenuStrip();
        themes.DropDownItems.Add(new ToolStripMenuItem("Detecting themes…") { Enabled = false });
        menu.Items.Add(themes);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Open Theme Folder", null, async (_, _) => await RunActionAsync("Open Theme Folder", service.OpenThemeFolderAsync));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit AutoSkin", null, (_, _) => ExitThread());
        ModernContextMenuStrip.StyleItems(menu.Items);
        themes.DropDownOpening += (_, _) => menu.RefreshStyle(themes.DropDown);
        menu.Opening += async (_, _) => await RefreshAsync();
        return menu;
    }

    private async Task RefreshAsync()
    {
        if (Volatile.Read(ref busy) != 0) return;
        try
        {
            var status = await service.GetStatusAsync();
            var available = await service.GetThemesAsync();
            tray.Text = status.Session switch
            {
                "active" => $"AutoSkin active — {status.Theme ?? "theme"}",
                "paused" => "AutoSkin paused — Original Codex Skin",
                _ => "AutoSkin for Codex"
            };
            themes.DropDownItems.Clear();
            var original = new ToolStripMenuItem("Original Codex Skin") { Checked = status.Session == "paused" };
            original.Click += async (_, _) => await RunActionAsync("Use Original Codex Skin", service.PauseAsync);
            themes.DropDownItems.Add(original);
            if (available.Count > 0) themes.DropDownItems.Add(new ToolStripSeparator());
            foreach (var theme in available)
            {
                var item = new ToolStripMenuItem(theme.Title) { Checked = status.Session == "active" && status.Theme == theme.Id, Tag = theme.Id };
                item.Click += async (_, _) => await RunActionAsync($"Switch to {theme.Title}", () => service.SelectThemeAsync(theme.Id));
                themes.DropDownItems.Add(item);
            }
            ModernContextMenuStrip.StyleItems(themes.DropDownItems);
        }
        catch (Exception error)
        {
            tray.Text = "AutoSkin needs attention";
            if (themes.DropDownItems.Count == 0)
                themes.DropDownItems.Add(new ToolStripMenuItem(error.Message) { Enabled = false });
        }
    }

    private async Task RunActionAsync(string title, Func<Task> action, bool showSuccess = false)
    {
        if (Interlocked.Exchange(ref busy, 1) != 0) return;
        tray.Text = $"AutoSkin — {title}…";
        try
        {
            await action();
            if (showSuccess) ShowMessage(title, "Completed.", ToolTipIcon.Info);
        }
        catch (Exception error)
        {
            ShowMessage($"{title} failed", error.Message, ToolTipIcon.Error);
        }
        finally
        {
            Interlocked.Exchange(ref busy, 0);
            await RefreshAsync();
        }
    }

    private void ShowMessage(string title, string text, ToolTipIcon icon)
    {
        tray.BalloonTipTitle = title;
        tray.BalloonTipText = text.Length > 240 ? text[..240] : text;
        tray.BalloonTipIcon = icon;
        tray.ShowBalloonTip(5000);
    }

    protected override void ExitThreadCore()
    {
        refreshTimer.Stop();
        tray.Visible = false;
        tray.Dispose();
        base.ExitThreadCore();
    }

    private static Icon CreatePaletteIcon()
    {
        using var bitmap = new Bitmap(32, 32);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var gradient = new LinearGradientBrush(new Rectangle(2, 2, 28, 28), Color.FromArgb(77, 201, 190), Color.FromArgb(121, 85, 210), 45f);
        graphics.FillEllipse(gradient, 2, 2, 28, 28);
        using var white = new SolidBrush(Color.White);
        graphics.FillEllipse(white, 8, 9, 4, 4);
        graphics.FillEllipse(white, 14, 6, 4, 4);
        graphics.FillEllipse(white, 20, 10, 4, 4);
        graphics.FillEllipse(white, 19, 18, 5, 5);
        return Icon.FromHandle(bitmap.GetHicon());
    }
}
