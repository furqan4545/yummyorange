import AppKit

/// Actions on the Actions wheel (⌥ by default). They act on the files themselves and work for any file or folder.
enum FileAction: String, CaseIterable {
    case copy = "Copy"
    case copyPath = "Copy Path"
    case reveal = "Reveal"
    case terminal = "Terminal"
    case airDrop = "AirDrop"
    case moveTo = "Move To…"

    func perform(on urls: [URL]) {
        switch self {
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls as [NSURL])
            HUD.shared.flash("Copied \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")")
        case .copyPath:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            HUD.shared.flash("Copied \(urls.count == 1 ? "path" : "\(urls.count) paths")")
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        case .terminal:
            guard let first = urls.first else { return }
            let isDir = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let folder = isDir ? first : first.deletingLastPathComponent()
            let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
                ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        case .airDrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                HUD.shared.flash("AirDrop isn’t available for these files", isError: true)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: urls)
        case .moveTo:
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Move Here"
            panel.message = "Choose where to move \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")"
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            var moved: [URL] = []
            for url in urls {
                let target = dest.appendingPathComponent(url.lastPathComponent)
                do { try FileManager.default.moveItem(at: url, to: target); moved.append(target) }
                catch { HUD.shared.flash(error.localizedDescription, isError: true); return }
            }
            NSWorkspace.shared.activateFileViewerSelecting(moved)
        }
    }
}
