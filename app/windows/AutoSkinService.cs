using Microsoft.Win32;
using System.Diagnostics;
using System.Net.Http.Json;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;

namespace AutoSkin.Windows;

internal sealed record ThemeEntry(string Id, string Title);
internal sealed record SkinStatus(string Session, string? Theme, string? Layout, int Port);
internal sealed record CodexInstall(string Executable, string PackageRoot, string PackageFullName, string FamilyName, string AppId);
internal sealed record RuntimeState(int schemaVersion, int port, int injectorPid, string nodePath, string runtimeRoot, string? theme = null);

internal sealed class AutoSkinService
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true, WriteIndented = true };
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(2) };
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly string stateRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexAutoSkin");
    private string RuntimeRoot => Path.Combine(stateRoot, "runtime");
    private string PrivateThemes => Path.Combine(stateRoot, "themes-private");
    private string StatePath => Path.Combine(stateRoot, "state.json");
    private string PausePath => Path.Combine(stateRoot, "paused");
    private string BundledRoot => Path.Combine(AppContext.BaseDirectory, "AutoSkinRuntime");

    public async Task<int> WriteDoctorReportAsync(string outputPath)
    {
        try
        {
            var node = await FindNodeAsync();
            var python = await FindPythonAsync();
            var codex = FindCodex();
            var required = new[]
            {
                "assets\\renderer-inject.js", "styles\\dream\\style.css", "scripts\\injector.mjs",
                "scripts\\set-theme.mjs", "examples\\chiikawa-summer\\theme.json"
            };
            var missing = required.Where(relative => !File.Exists(Path.Combine(BundledRoot, relative))).ToArray();
            if (missing.Length > 0) throw new InvalidOperationException("Bundled runtime is incomplete: " + string.Join(", ", missing));
            AssertNoReparsePoints(BundledRoot);
            var nodeCheck = await RunAsync(node, "--check", Path.Combine(BundledRoot, "scripts", "injector.mjs"));
            var rendererCheck = await RunAsync(node, "--check", Path.Combine(BundledRoot, "assets", "renderer-inject.js"));
            var themeCheck = await RunAsync(python, Path.Combine(BundledRoot, "scripts", "theme_tool.py"), "validate", Path.Combine(BundledRoot, "examples", "chiikawa-summer"));
            if (nodeCheck.ExitCode != 0 || rendererCheck.ExitCode != 0 || themeCheck.ExitCode != 0)
                throw new InvalidOperationException(string.Join(Environment.NewLine, new[] { nodeCheck.Output, rendererCheck.Output, themeCheck.Output }.Where(value => !string.IsNullOrWhiteSpace(value))));
            await WriteJsonAtomicAsync(outputPath, new
            {
                ok = true,
                checkedAt = DateTimeOffset.UtcNow,
                node,
                python,
                codexVersion = ParsePackageVersion(codex.PackageFullName).ToString(),
                codexPackage = codex.PackageFullName,
                bundledRuntime = BundledRoot,
                starterTheme = "chiikawa-summer"
            });
            return 0;
        }
        catch (Exception error)
        {
            await WriteJsonAtomicAsync(outputPath, new { ok = false, checkedAt = DateTimeOffset.UtcNow, error = error.Message });
            return 1;
        }
    }

    public async Task EnsureReadyAsync()
    {
        await gate.WaitAsync();
        try
        {
            Directory.CreateDirectory(stateRoot);
            AssertManagedStateRoot();
            var node = await FindNodeAsync();
            _ = FindCodex();
            await StopRecordedInjectorAsync();
            var nativeThemeChanged = await InstallRuntimeAsync(node);
            RegisterLoginStart();
            RegisterStartMenuShortcut();
            if (!File.Exists(PausePath)) await StartAsync(node, restartExisting: true, forceRestart: nativeThemeChanged);
        }
        finally { gate.Release(); }
    }

    public async Task SelectThemeAsync(string themeId)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(themeId, "^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"))
            throw new InvalidOperationException("Invalid theme identifier.");
        await gate.WaitAsync();
        try
        {
            var node = await FindNodeAsync();
            var status = await GetStatusCoreAsync();
            if (status.Session != "active") await StartAsync(node, restartExisting: true);
            var result = await RunAsync(node, Path.Combine(RuntimeRoot, "scripts", "set-theme.mjs"), themeId, "--port", status.Port.ToString());
            if (result.ExitCode != 0) throw new InvalidOperationException(result.Output);
            if (File.Exists(PausePath)) File.Delete(PausePath);
        }
        finally { gate.Release(); }
    }

    public async Task PauseAsync()
    {
        await gate.WaitAsync();
        try
        {
            Directory.CreateDirectory(stateRoot);
            await File.WriteAllTextAsync(PausePath, DateTimeOffset.UtcNow.ToString("O"), new UTF8Encoding(false));
            var state = await ReadStateAsync();
            if (state is not null)
            {
                var node = await FindNodeAsync();
                await RunAsync(node, Path.Combine(RuntimeRoot, "scripts", "injector.mjs"), "--remove", "--port", state.port.ToString(), "--timeout-ms", "3000");
            }
            await StopRecordedInjectorAsync();
        }
        finally { gate.Release(); }
    }

    public Task OpenThemeFolderAsync()
    {
        Directory.CreateDirectory(PrivateThemes);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{PrivateThemes}\"") { UseShellExecute = true });
        return Task.CompletedTask;
    }

    public async Task<SkinStatus> GetStatusAsync()
    {
        await gate.WaitAsync();
        try { return await GetStatusCoreAsync(); }
        finally { gate.Release(); }
    }

    public async Task<IReadOnlyList<ThemeEntry>> GetThemesAsync()
    {
        if (!File.Exists(Path.Combine(RuntimeRoot, "scripts", "injector.mjs"))) return [];
        try
        {
            var node = await FindNodeAsync();
            var result = await RunAsync(node, Path.Combine(RuntimeRoot, "scripts", "injector.mjs"), "--themes");
            if (result.ExitCode != 0) return [];
            using var document = JsonDocument.Parse(ExtractJsonObject(result.Output));
            if (!document.RootElement.TryGetProperty("themes", out var themes)) return [];
            return themes.EnumerateArray().Select(item => new ThemeEntry(
                item.GetProperty("name").GetString()!,
                item.TryGetProperty("button", out var button) && !string.IsNullOrWhiteSpace(button.GetString())
                    ? button.GetString()! : item.GetProperty("name").GetString()!)).ToArray();
        }
        catch { return []; }
    }

    private async Task<SkinStatus> GetStatusCoreAsync()
    {
        var state = await ReadStateAsync();
        var port = state?.port ?? await ReadDefaultPortAsync() ?? 9335;
        if (File.Exists(PausePath)) return new SkinStatus("paused", null, null, port);
        if (state is null || !IsExpectedNodeProcess(state.injectorPid) || !await HasCodexTargetAsync(port))
            return new SkinStatus("inactive", null, null, port);
        try
        {
            var result = await RunAsync(state.nodePath, Path.Combine(RuntimeRoot, "scripts", "set-theme.mjs"), "--list", "--port", port.ToString());
            using var json = JsonDocument.Parse(ExtractJsonObject(result.Output));
            return new SkinStatus("active", json.RootElement.GetProperty("theme").GetString(), json.RootElement.GetProperty("layout").GetString(), port);
        }
        catch { return new SkinStatus("active", state.theme, null, port); }
    }

    private async Task<bool> InstallRuntimeAsync(string node)
    {
        foreach (var relative in new[] { "assets\\renderer-inject.js", "styles\\dream\\style.css", "scripts\\injector.mjs" })
            if (!File.Exists(Path.Combine(BundledRoot, relative))) throw new InvalidOperationException($"Bundled runtime is incomplete: {relative}");
        AssertNoReparsePoints(BundledRoot);
        var staging = Path.Combine(stateRoot, $".runtime-next-{Environment.ProcessId}");
        var backup = Path.Combine(stateRoot, $".runtime-backup-{Environment.ProcessId}");
        DeleteManagedDirectory(staging);
        Directory.CreateDirectory(staging);
        try
        {
            foreach (var folder in new[] { "assets", "styles", "themes", "scripts" })
                CopyDirectory(Path.Combine(BundledRoot, folder), Path.Combine(staging, folder));
            AssertNoReparsePoints(staging);
            if (Directory.Exists(RuntimeRoot)) Directory.Move(RuntimeRoot, backup);
            try { Directory.Move(staging, RuntimeRoot); }
            catch
            {
                if (Directory.Exists(backup) && !Directory.Exists(RuntimeRoot)) Directory.Move(backup, RuntimeRoot);
                throw;
            }
            DeleteManagedDirectory(backup);
        }
        finally { DeleteManagedDirectory(staging); }

        Directory.CreateDirectory(PrivateThemes);
        var starterDestination = Path.Combine(PrivateThemes, "chiikawa-summer");
        if (!Directory.Exists(starterDestination)) await BuildStarterThemeAsync(starterDestination);
        var config = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "config.toml");
        var backupConfig = Path.Combine(stateRoot, "config.before-autoskin.toml");
        if (File.Exists(config) && !File.Exists(backupConfig)) File.Copy(config, backupConfig);
        var nativeThemeChanged = false;
        if (File.Exists(config))
        {
            var sourceTheme = Path.Combine(BundledRoot, "examples", "chiikawa-summer", "theme.json");
            var themeHash = Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(sourceTheme)))[..12].ToLowerInvariant();
            var marker = Path.Combine(stateRoot, $"native-theme-{themeHash}.applied");
            if (!File.Exists(marker))
            {
                var python = await FindPythonAsync();
                var install = await RunAsync(python, Path.Combine(BundledRoot, "scripts", "install_theme.py"),
                    Path.GetDirectoryName(sourceTheme)!, "--runtime-root", RuntimeRoot);
                if (install.ExitCode != 0) throw new InvalidOperationException($"Native theme transaction failed: {install.Output}");
                await File.WriteAllTextAsync(marker, DateTimeOffset.UtcNow.ToString("O"), new UTF8Encoding(false));
                nativeThemeChanged = true;
            }
        }
        await WriteJsonAtomicAsync(Path.Combine(stateRoot, "install-state.json"), new
        {
            schemaVersion = 1,
            installedAt = DateTimeOffset.UtcNow,
            runtimeRoot = RuntimeRoot,
            nodePath = node,
            defaultPort = await ReadDefaultPortAsync() ?? 9335,
            appVersion = Assembly.GetExecutingAssembly().GetName().Version?.ToString()
        });
        return nativeThemeChanged;
    }

    private async Task BuildStarterThemeAsync(string destination)
    {
        var python = await FindPythonAsync();
        var temporary = Path.Combine(stateRoot, $".starter-source-{Environment.ProcessId}");
        DeleteManagedDirectory(temporary);
        try
        {
            CopyDirectory(Path.Combine(BundledRoot, "examples", "chiikawa-summer"), temporary);
            var tool = Path.Combine(BundledRoot, "scripts", "theme_tool.py");
            var result = await RunAsync(python, tool, "build", temporary);
            if (result.ExitCode != 0) throw new InvalidOperationException($"Starter theme build failed: {result.Output}");
            CopyDirectory(Path.Combine(temporary, ".build", "chiikawa-summer"), destination);
        }
        finally { DeleteManagedDirectory(temporary); }
    }

    private async Task StartAsync(string node, bool restartExisting, bool forceRestart = false)
    {
        var port = await ReadDefaultPortAsync() ?? 9335;
        if (forceRestart || !await HasCodexTargetAsync(port))
        {
            var codex = FindCodex();
            var running = GetCodexProcesses(codex).ToArray();
            if (running.Length > 0 && !restartExisting) throw new InvalidOperationException("Codex is already running without AutoSkin.");
            foreach (var process in running)
            {
                try { process.Kill(true); process.WaitForExit(10_000); } finally { process.Dispose(); }
            }
            _ = PackageLauncher.Launch($"{codex.FamilyName}!{codex.AppId}",
                $"--remote-debugging-port={port} --remote-debugging-address=127.0.0.1");
            var deadline = DateTime.UtcNow.AddSeconds(35);
            while (DateTime.UtcNow < deadline && !await HasCodexTargetAsync(port)) await Task.Delay(350);
            if (!await HasCodexTargetAsync(port)) throw new InvalidOperationException($"Codex did not open its loopback debugging endpoint on port {port}.");
        }
        await StopRecordedInjectorAsync();
        if (File.Exists(PausePath)) File.Delete(PausePath);
        var injector = Path.Combine(RuntimeRoot, "scripts", "injector.mjs");
        var daemon = Process.Start(new ProcessStartInfo(node)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            Arguments = $"\"{injector}\" --watch --port {port}"
        }) ?? throw new InvalidOperationException("The AutoSkin injector could not start.");
        await WriteJsonAtomicAsync(StatePath, new RuntimeState(1, port, daemon.Id, node, RuntimeRoot));
        daemon.Dispose();
        for (var attempt = 0; attempt < 40; attempt++)
        {
            await Task.Delay(500);
            var verify = await RunAsync(node, injector, "--verify", "--port", port.ToString());
            if (verify.ExitCode == 0) return;
            if (!IsExpectedNodeProcess((await ReadStateAsync())?.injectorPid ?? -1)) break;
        }
        await StopRecordedInjectorAsync();
        throw new InvalidOperationException("AutoSkin started but live verification failed.");
    }

    private async Task StopRecordedInjectorAsync()
    {
        var state = await ReadStateAsync();
        if (state is null || !PathEquals(state.runtimeRoot, RuntimeRoot) || !IsExpectedNodeProcess(state.injectorPid)) return;
        try
        {
            using var process = Process.GetProcessById(state.injectorPid);
            process.Kill(true);
            await process.WaitForExitAsync();
        }
        catch { }
    }

    private static bool IsExpectedNodeProcess(int pid)
    {
        if (pid <= 0) return false;
        try
        {
            using var process = Process.GetProcessById(pid);
            return process.ProcessName.Equals("node", StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    private async Task<RuntimeState?> ReadStateAsync()
    {
        try { return JsonSerializer.Deserialize<RuntimeState>(await File.ReadAllTextAsync(StatePath, Encoding.UTF8), JsonOptions); }
        catch { return null; }
    }

    private async Task<int?> ReadDefaultPortAsync()
    {
        try
        {
            using var json = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(stateRoot, "install-state.json"), Encoding.UTF8));
            return json.RootElement.GetProperty("defaultPort").GetInt32();
        }
        catch { return null; }
    }

    private static async Task<string> FindNodeAsync()
    {
        var result = await RunAsync("node.exe", "-p", "process.versions.node");
        if (result.ExitCode != 0 || !Version.TryParse(result.Output.Trim(), out var version) || version.Major < 22)
            throw new InvalidOperationException("Node.js 22 or newer is required.");
        var path = await RunAsync("node.exe", "-p", "process.execPath");
        if (path.ExitCode != 0 || !File.Exists(path.Output.Trim())) throw new InvalidOperationException("Node.js could not be validated.");
        return path.Output.Trim();
    }

    private static async Task<string> FindPythonAsync()
    {
        foreach (var candidate in new[] { "python.exe", "python3.exe" })
        {
            var result = await RunAsync(candidate, "-c", "import sys; print(sys.executable if sys.version_info >= (3,9) else '')");
            if (result.ExitCode == 0 && File.Exists(result.Output.Trim())) return result.Output.Trim();
        }
        throw new InvalidOperationException("Python 3.9 or newer is required to build themes.");
    }

    private static CodexInstall FindCodex()
    {
        const string repository = @"Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages";
        using var root = Registry.CurrentUser.OpenSubKey(repository) ?? throw new InvalidOperationException("Windows app package repository is unavailable.");
        var candidates = root.GetSubKeyNames().Where(name => name.StartsWith("OpenAI.Codex_", StringComparison.OrdinalIgnoreCase))
            .Select(name => (Name: name, Version: ParsePackageVersion(name))).OrderByDescending(item => item.Version);
        foreach (var candidate in candidates)
        {
            using var key = root.OpenSubKey(candidate.Name);
            var packageRoot = key?.GetValue("PackageRootFolder") as string;
            if (string.IsNullOrWhiteSpace(packageRoot)) continue;
            var executable = Path.Combine(packageRoot, "app", "ChatGPT.exe");
            var manifestPath = Path.Combine(packageRoot, "AppxManifest.xml");
            if (!File.Exists(executable) || !File.Exists(manifestPath)) continue;
            var document = XDocument.Load(manifestPath);
            var identity = document.Descendants().FirstOrDefault(element => element.Name.LocalName == "Identity");
            var application = document.Descendants().SingleOrDefault(element => element.Name.LocalName == "Application" &&
                string.Equals((string?)element.Attribute("Executable")?.Value.Replace('/', '\\'), "app\\ChatGPT.exe", StringComparison.OrdinalIgnoreCase));
            var publisherId = candidate.Name.Split(new[] { "__" }, StringSplitOptions.None).LastOrDefault();
            var name = identity?.Attribute("Name")?.Value;
            var appId = application?.Attribute("Id")?.Value;
            if (name is null || !string.Equals(publisherId, "2p2nqsd0c76g0", StringComparison.OrdinalIgnoreCase) || appId is null) continue;
            return new CodexInstall(executable, packageRoot, candidate.Name, $"{name}_{publisherId}", appId);
        }
        throw new InvalidOperationException("The official Microsoft Store Codex app was not found.");
    }

    private static Version ParsePackageVersion(string name)
    {
        var part = name.Split('_').Skip(1).FirstOrDefault();
        return Version.TryParse(part, out var version) ? version : new Version();
    }

    private static IReadOnlyList<Process> GetCodexProcesses(CodexInstall codex)
    {
        var result = new List<Process>();
        foreach (var process in Process.GetProcessesByName("ChatGPT"))
        {
            try
            {
                var path = process.MainModule?.FileName;
                if (path is not null && PathWithin(path, codex.PackageRoot)) result.Add(process);
                else process.Dispose();
            }
            catch { process.Dispose(); }
        }
        return result;
    }

    private static async Task<bool> HasCodexTargetAsync(int port)
    {
        foreach (var host in new[] { "127.0.0.1", "[::1]" })
        {
            try
            {
                var targets = await Http.GetFromJsonAsync<JsonElement>($"http://{host}:{port}/json/list");
                if (targets.ValueKind == JsonValueKind.Array && targets.EnumerateArray().Any(item =>
                    item.TryGetProperty("type", out var type) && type.GetString() == "page" &&
                    item.TryGetProperty("url", out var url) && (url.GetString() ?? "").StartsWith("app://-/index.html", StringComparison.Ordinal))) return true;
            }
            catch { }
        }
        return false;
    }

    private static async Task<(int ExitCode, string Output)> RunAsync(string executable, params string[] arguments)
    {
        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo(executable)
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    StandardOutputEncoding = new UTF8Encoding(false),
                    StandardErrorEncoding = new UTF8Encoding(false)
                }
            };
            foreach (var argument in arguments) process.StartInfo.ArgumentList.Add(argument);
            process.Start();
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync();
            var output = (await stdout).Trim();
            var error = (await stderr).Trim();
            return (process.ExitCode, string.IsNullOrEmpty(output) ? error : output + (string.IsNullOrEmpty(error) ? "" : Environment.NewLine + error));
        }
        catch (Exception error) { return (127, error.Message); }
    }

    private static string ExtractJsonObject(string output)
    {
        var start = output.IndexOf('{');
        var end = output.LastIndexOf('}');
        if (start < 0 || end < start) throw new JsonException("Command did not return a JSON object.");
        return output[start..(end + 1)];
    }

    private void RegisterLoginStart()
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("AutoSkin executable path is unavailable.");
        using var run = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        run.SetValue("AutoSkinCodex", $"\"{executable}\"");
    }

    private void RegisterStartMenuShortcut()
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("AutoSkin executable path is unavailable.");
        var programs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Microsoft", "Windows", "Start Menu", "Programs");
        Directory.CreateDirectory(programs);
        var shortcutPath = Path.Combine(programs, "AutoSkin Codex.lnk");
        var shellType = Type.GetTypeFromProgID("WScript.Shell")
            ?? throw new InvalidOperationException("Windows shortcut service is unavailable.");
        object? shell = null;
        object? shortcut = null;
        try
        {
            shell = Activator.CreateInstance(shellType);
            shortcut = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, [shortcutPath]);
            var shortcutType = shortcut!.GetType();
            shortcutType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, [executable]);
            shortcutType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, [Path.GetDirectoryName(executable)!]);
            shortcutType.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, ["AutoSkin theme manager for Codex"]);
            shortcutType.InvokeMember("IconLocation", BindingFlags.SetProperty, null, shortcut, [$"{executable},0"]);
            shortcutType.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
        }
        finally
        {
            if (shortcut is not null && Marshal.IsComObject(shortcut)) Marshal.FinalReleaseComObject(shortcut);
            if (shell is not null && Marshal.IsComObject(shell)) Marshal.FinalReleaseComObject(shell);
        }
    }

    private static async Task WriteJsonAtomicAsync<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + $".next-{Environment.ProcessId}";
        await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(value, JsonOptions) + Environment.NewLine, new UTF8Encoding(false));
        File.Move(temporary, path, true);
    }

    private static void CopyDirectory(string source, string destination)
    {
        var root = new DirectoryInfo(source);
        if (!root.Exists) throw new DirectoryNotFoundException(source);
        if (root.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new InvalidOperationException($"Refusing reparse point: {source}");
        Directory.CreateDirectory(destination);
        foreach (var file in root.GetFiles()) file.CopyTo(Path.Combine(destination, file.Name), true);
        foreach (var directory in root.GetDirectories())
        {
            if (directory.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new InvalidOperationException($"Refusing reparse point: {directory.FullName}");
            CopyDirectory(directory.FullName, Path.Combine(destination, directory.Name));
        }
    }

    private static void AssertNoReparsePoints(string root)
    {
        if (new DirectoryInfo(root).Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new InvalidOperationException($"Refusing reparse point: {root}");
        foreach (var path in Directory.EnumerateFileSystemEntries(root, "*", SearchOption.AllDirectories))
            if (File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint)) throw new InvalidOperationException($"Runtime contains a reparse point: {path}");
    }

    private void DeleteManagedDirectory(string path)
    {
        if (!Directory.Exists(path)) return;
        if (!PathWithin(path, stateRoot) || PathEquals(path, stateRoot)) throw new InvalidOperationException($"Refusing to delete unmanaged path: {path}");
        AssertNoReparsePoints(path);
        Directory.Delete(path, true);
    }

    private void AssertManagedStateRoot()
    {
        var localAppData = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
        var managed = Path.GetFullPath(stateRoot);
        if (!PathWithin(managed, localAppData)) throw new InvalidOperationException("AutoSkin state root is outside LocalAppData.");
        var current = localAppData;
        if (new DirectoryInfo(current).Attributes.HasFlag(FileAttributes.ReparsePoint))
            throw new InvalidOperationException($"Managed path contains a reparse point: {current}");
        foreach (var component in Path.GetRelativePath(localAppData, managed).Split(Path.DirectorySeparatorChar))
        {
            current = Path.Combine(current, component);
            if (Directory.Exists(current) && new DirectoryInfo(current).Attributes.HasFlag(FileAttributes.ReparsePoint))
                throw new InvalidOperationException($"Managed path contains a reparse point: {current}");
        }
    }

    private static bool PathWithin(string path, string root) => Path.GetFullPath(path).StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    private static bool PathEquals(string left, string right) => string.Equals(Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar), Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase);
}

[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IApplicationActivationManager
{
    [PreserveSig]
    int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
}

[ComImport, Guid("45ba127d-10a8-46ea-8ab7-56ea9078943c")]
internal class ApplicationActivationManager;

internal static class PackageLauncher
{
    public static uint Launch(string appUserModelId, string arguments)
    {
        var manager = (IApplicationActivationManager)new ApplicationActivationManager();
        try
        {
            var result = manager.ActivateApplication(appUserModelId, arguments, 0, out var processId);
            Marshal.ThrowExceptionForHR(result);
            if (processId == 0) throw new InvalidOperationException("Windows did not return a Codex process ID.");
            return processId;
        }
        finally
        {
            if (Marshal.IsComObject(manager)) Marshal.FinalReleaseComObject(manager);
        }
    }
}
