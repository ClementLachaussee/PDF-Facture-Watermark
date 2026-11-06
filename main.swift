import Cocoa
import UniformTypeIdentifiers

// MARK: - Réglages

let watermarkText = "Facture acquittée"
let watermarkColor = NSColor(calibratedRed: 0.78, green: 0.10, blue: 0.10, alpha: 1)
let watermarkAlpha: CGFloat = 0.40      // opacité (0 à 1)
let watermarkAngle: CGFloat = 30        // inclinaison en degrés
let watermarkWidthRatio: CGFloat = 0.75 // largeur du texte par rapport au petit côté de la page

// MARK: - Filigrane

struct WMError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func uniqueOutputURL(for input: URL) -> URL {
    let dir = input.deletingLastPathComponent()
    let base = input.deletingPathExtension().lastPathComponent + " - acquittée"
    var url = dir.appendingPathComponent(base + ".pdf")
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("\(base) \(n).pdf")
        n += 1
    }
    return url
}

func drawStamp(in ctx: CGContext, size: CGSize) {
    // Calcule la taille de police pour que le texte occupe la largeur voulue
    let probe = NSAttributedString(string: watermarkText,
                                   attributes: [.font: NSFont.systemFont(ofSize: 100, weight: .heavy)])
    let widthAt100 = max(probe.size().width, 1)
    let fontSize = 100 * (min(size.width, size.height) * watermarkWidthRatio) / widthAt100

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
        .foregroundColor: watermarkColor,
    ]
    let text = NSAttributedString(string: watermarkText, attributes: attrs)
    let textSize = text.size()
    let pad = fontSize * 0.25

    ctx.saveGState()
    ctx.translateBy(x: size.width / 2, y: size.height / 2)
    ctx.rotate(by: watermarkAngle * .pi / 180)
    ctx.setAlpha(watermarkAlpha)

    // Cadre façon tampon
    let frame = CGRect(x: -textSize.width / 2 - pad,
                       y: -textSize.height / 2 - pad * 0.6,
                       width: textSize.width + 2 * pad,
                       height: textSize.height + 1.2 * pad)
    ctx.setStrokeColor(watermarkColor.cgColor)
    ctx.setLineWidth(fontSize * 0.06)
    ctx.addPath(CGPath(roundedRect: frame, cornerWidth: pad * 0.5, cornerHeight: pad * 0.5, transform: nil))
    ctx.strokePath()

    // Texte
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    text.draw(at: NSPoint(x: -textSize.width / 2, y: -textSize.height / 2))
    NSGraphicsContext.restoreGraphicsState()

    ctx.restoreGState()
}

/// Crée « <nom> - acquittée.pdf » à côté de l'original et renvoie son URL.
func addWatermark(to input: URL) throws -> URL {
    guard let doc = CGPDFDocument(input as CFURL) else { throw WMError(message: "PDF illisible") }
    if doc.isEncrypted && !doc.unlockWithPassword("") {
        throw WMError(message: "PDF protégé par mot de passe")
    }
    guard doc.numberOfPages > 0 else { throw WMError(message: "PDF vide") }

    let output = uniqueOutputURL(for: input)
    guard let ctx = CGContext(output as CFURL, mediaBox: nil, nil) else {
        throw WMError(message: "Impossible d'écrire le fichier de sortie")
    }

    for i in 1...doc.numberOfPages {
        guard let page = doc.page(at: i) else { continue }
        let box = page.getBoxRect(.cropBox)
        let swap = page.rotationAngle % 180 != 0
        var out = CGRect(x: 0, y: 0,
                         width: swap ? box.height : box.width,
                         height: swap ? box.width : box.height)

        ctx.beginPage(mediaBox: &out)
        ctx.saveGState()
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: out, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        drawStamp(in: ctx, size: out.size)
        ctx.endPage()
    }
    ctx.closePDF()
    return output
}

// MARK: - Interface

final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 14, dy: 14), xRadius: 14, yRadius: 14)
        path.lineWidth = 2
        path.setLineDash([8, 6], count: 2, phase: 0)
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
        }
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { return false }
        onDrop?(pdfs)
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "")
    private var didSetup = false

    func applicationWillFinishLaunching(_ notification: Notification) { setup() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        setup()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // PDF déposés sur l'icône du Dock ou ouverts via « Ouvrir avec »
    func application(_ sender: NSApplication, open urls: [URL]) {
        setup()
        process(urls.filter { $0.pathExtension.lowercased() == "pdf" })
    }

    private func setup() {
        guard !didSetup else { return }
        didSetup = true

        // Menu minimal (Cmd+Q)
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quitter Acquitter",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Acquitter"
        window.center()

        let content = window.contentView!

        let drop = DropView(frame: NSRect(x: 0, y: 70, width: 440, height: 230))
        drop.onDrop = { [weak self] urls in self?.process(urls) }
        content.addSubview(drop)

        let title = NSTextField(labelWithString: "Déposez vos PDF ici")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 150, width: 440, height: 28)
        content.addSubview(title)

        let button = NSButton(title: "Choisir des PDF…", target: self, action: #selector(chooseFiles))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 140, y: 108, width: 160, height: 30)
        content.addSubview(button)

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 20, y: 8, width: 400, height: 54)
        content.addSubview(status)

        window.makeKeyAndOrderFront(nil)
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { process(panel.urls) }
    }

    private func process(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        status.stringValue = "Traitement en cours…"
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            var outputs: [URL] = []
            for url in urls {
                do {
                    let out = try addWatermark(to: url)
                    outputs.append(out)
                    lines.append("✓ \(out.lastPathComponent)")
                } catch {
                    lines.append("✗ \(url.lastPathComponent) : \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.status.stringValue = lines.joined(separator: "\n")
                if !outputs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
            }
        }
    }
}

// MARK: - Lancement

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
