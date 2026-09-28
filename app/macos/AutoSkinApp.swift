import AppKit
import Foundation
import ServiceManagement

private struct CommandResult {
    let exitCode: Int32
    let output: String
}

private final class AutoSkinAppDelegate: NSObject, NSApplicationDelegate {
    private let worker = DispatchQueue(label: "app.autoskin.codex.worker", qos: .userInitiated)
    private var statusItem: NSStatusItem!
    private var themesMenu: NSMenu!
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        unregisterLoginItem()
        ensureReady()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        // The skin is tied to the app lifecycle: shutting the app down must
        // return Codex to the original skin. Run synchronously because the
        // process exits right after this callback returns.
        let pause = Process()
        pause.executableURL = URL(fileURLWithPath: "/bin/bash")
        pause.arguments = [commandScript.path, "shutdown"]
        pause.standardOutput = FileHandle.nullDevice
        pause.standardError = FileHandle.nullDevice
        do {
            try pause.run()
            pause.waitUntilExit()
        } catch {
            // Nothing further to do while terminating; the paused marker from
            // a previous shutdown is cleared on next launch.
        }
    }

    private func unregisterLoginItem() {
        // The skin only applies while the app is explicitly running, so the
        // app must not start itself at login.
        guard #available(macOS 13.0, *) else { return }
        if SMAppService.mainApp.status != .notRegistered {
            try? SMAppService.mainApp.unregister()
        }
    }

    private var commandScript: URL {
        guard let resources = Bundle.main.resourceURL else {
            fatalError("CodexSkin.app has no resource directory")
        }
        return resources.appendingPathComponent("autoskin-app-command.sh")
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "paintpalette.fill", accessibilityDescription: "CodexSkin")
            button.toolTip = "CodexSkin for Codex"
        }

        let menu = NSMenu()
        let themesItem = NSMenuItem(title: "Themes", action: nil, keyEquivalent: "")
        themesMenu = NSMenu()
        themesMenu.addItem(NSMenuItem(title: "Detecting themes…", action: nil, keyEquivalent: ""))
        themesItem.submenu = themesMenu
        menu.addItem(themesItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Theme Folder", #selector(openThemeFolder)))
        menu.addItem(.separator())
        menu.addItem(item("Quit CodexSkin", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
        result.target = self
        return result
    }

    private func run(_ command: String, arguments: [String] = []) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [commandScript.path, command] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(
                exitCode: process.terminationStatus,
                output: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        } catch {
            return CommandResult(exitCode: 127, output: error.localizedDescription)
        }
    }

    private func setBusy(_ text: String?) {
        statusItem.button?.appearsDisabled = text != nil
        statusItem.button?.toolTip = text ?? "CodexSkin for Codex"
    }

    private func runAction(
        _ command: String,
        arguments: [String] = [],
        title: String,
        showSuccess: Bool = false
    ) {
        setBusy("Working: \(title)…")
        worker.async { [weak self] in
            guard let self else { return }
            let result = self.run(command, arguments: arguments)
            DispatchQueue.main.async {
                self.setBusy(nil)
                self.refreshStatus()
                if result.exitCode != 0 || showSuccess {
                    self.showResult(title: title, result: result)
                }
            }
        }
    }

    private func showResult(title: String, result: CommandResult) {
        let alert = NSAlert()
        alert.alertStyle = result.exitCode == 0 ? .informational : .critical
        alert.messageText = result.exitCode == 0 ? "\(title) completed" : "\(title) failed"
        alert.informativeText = result.output.isEmpty ? "No additional output." : result.output
        alert.runModal()
    }

    private func refreshStatus() {
        worker.async { [weak self] in
            guard let self else { return }
            let result = self.run("status")
            let lines = result.output.split(separator: "\n").map(String.init)
            let values = Dictionary(uniqueKeysWithValues: lines.compactMap { line -> (String, String)? in
                guard let split = line.firstIndex(of: "=") else { return nil }
                return (String(line[..<split]), String(line[line.index(after: split)...]))
            })
            let session = values["session"] ?? (result.exitCode == 0 ? "unknown" : "not installed")
            let themeResult = self.run("themes")
            DispatchQueue.main.async {
                self.statusItem.button?.contentTintColor = session == "active" ? .systemTeal : nil
                self.updateThemesMenu(
                    themeResult,
                    selected: values["theme"] ?? "",
                    originalSelected: session == "paused"
                )
            }
        }
    }

    private func updateThemesMenu(_ result: CommandResult, selected: String, originalSelected: Bool) {
        themesMenu.removeAllItems()
        let original = item("Original Codex Skin", #selector(selectTheme))
        original.representedObject = "__original__"
        original.state = originalSelected ? .on : .off
        themesMenu.addItem(original)

        guard result.exitCode == 0,
              let data = result.output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let themes = object["themes"] as? [[String: Any]],
              !themes.isEmpty else {
            return
        }
        themesMenu.addItem(.separator())
        for theme in themes {
            guard let identifier = theme["name"] as? String else { continue }
            let title = (theme["button"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? identifier
            let entry = item(title, #selector(selectTheme))
            entry.representedObject = identifier
            entry.state = identifier == selected ? .on : .off
            themesMenu.addItem(entry)
        }
    }

    private func ensureReady() {
        setBusy("Detecting Codex and themes…")
        worker.async { [weak self] in
            guard let self else { return }
            let result = self.run("launch")
            DispatchQueue.main.async {
                self.setBusy(nil)
                self.refreshStatus()
                if result.exitCode != 0 {
                    self.showResult(title: "Automatic CodexSkin setup", result: result)
                }
            }
        }
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        if identifier == "__original__" {
            runAction("original", title: "Use Original Codex Skin")
        } else {
            runAction("theme", arguments: [identifier], title: "Switch to \(sender.title)")
        }
    }

    @objc private func openThemeFolder() {
        runAction("open-themes", title: "Open Theme Folder")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
private let delegate = AutoSkinAppDelegate()
application.delegate = delegate
application.run()
