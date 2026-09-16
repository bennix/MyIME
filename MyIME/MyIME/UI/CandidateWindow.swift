import AppKit
import InputMethodKit
import SwiftUI
import IMEKit

extension Color {
    init(candidateRGB value: UInt32) {
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

private struct CandidateListView: View {
    let candidates: [Candidate]
    let highlighted: Int
    let prefs: EnginePrefs
    let expanded: Bool
    let vertical: Bool
    let availableWidth: CGFloat
    let availableHeight: CGFloat
    let onSelect: (Int) -> Void
    let onExpand: () -> Void
    let onCollapse: () -> Void

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            if vertical {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) { candidateViews }
                    }
                    .frame(width: availableWidth, height: min(availableHeight, CGFloat(candidates.count) * (prefs.fontSize * 3 + 18)))
                    .onAppear { proxy.scrollTo(highlighted, anchor: .center) }
                    .onChange(of: highlighted) { value in proxy.scrollTo(value, anchor: .center) }
                }
                controlButton(expanded ? "chevron.up" : "chevron.down", label: expanded ? "收起候选" : "展开候选", action: expanded ? onCollapse : onExpand)
            } else if expanded {
                HStack(spacing: 4) {
                    LazyVGrid(columns: gridColumns, spacing: 0) {
                        candidateViews
                    }
                    .frame(width: 620)
                    Divider().frame(height: 30)
                    controlButton("chevron.up", label: "收起候选", action: onCollapse)
                }
            } else if prefs.orientation == .horizontal {
                HStack(spacing: 2) {
                    candidateViews
                    Spacer(minLength: 4)
                    Divider().frame(height: 30)
                    controlButton("chevron.down", label: "展开候选", action: onExpand)
                }
                .frame(minWidth: 620)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    candidateViews
                }
                .frame(minWidth: 320)
            }
        }
        .font(.system(size: expanded ? min(max(prefs.fontSize - 2, 15), 19) : max(prefs.fontSize, 13)))
        .padding(expanded ? 6 : 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder private var candidateViews: some View {
        ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
            Button { onSelect(index) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    if prefs.showEnglishGloss, let gloss = candidate.displayGloss {
                        Text(gloss)
                            .font(.system(size: max(11, prefs.fontSize - 5)))
                            .foregroundStyle(Color(candidateRGB: prefs.englishTextColor))
                            .lineLimit(vertical ? nil : 1)
                            .fixedSize(horizontal: !vertical, vertical: true)
                    }
                    Text(candidateTitle(candidate.word, at: index))
                        .foregroundStyle(Color(candidateRGB: candidate.word.unicodeScalars.allSatisfy { $0.isASCII } ? prefs.englishTextColor : prefs.chineseTextColor))
                        .lineLimit(vertical ? nil : 1)
                        .fixedSize(horizontal: !vertical, vertical: true)
                        .layoutPriority(1)
                }
                    .frame(maxWidth: (expanded || vertical) ? .infinity : nil, minHeight: expanded ? 28 : 34, alignment: .leading)
                    .padding(.horizontal, expanded ? 7 : 9)
                    .padding(.vertical, 2)
                    .foregroundStyle(index == highlighted ? Color.white : Color.primary)
                    .background(index == highlighted ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(index == highlighted ? Color.accentColor : Color.clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        if expanded, index / 6 < (candidates.count - 1) / 6 {
                            Divider()
                        }
                    }
            }
            .buttonStyle(.plain)
            .id(index)
        }
    }

    private func controlButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func candidateTitle(_ word: String, at index: Int) -> String {
        if expanded {
            return index / 6 == highlighted / 6 ? "\(index % 6 + 1) \(word)" : "   \(word)"
        }
        return index < 9 ? "\(index + 1) \(word)" : "   \(word)"
    }
}

@MainActor
final class CandidateWindowController {
    var onSelect: ((Int) -> Void)?
    var onExpand: (() -> Void)?
    var onCollapse: (() -> Void)?
    private let panel: NSPanel
    private var candidates: [Candidate] = []
    private var highlighted = 0
    private var preferences = EnginePrefs()
    private var expanded = false
    private(set) var verticalLayout = false
    private var availableWidth: CGFloat = 480
    private var availableHeight: CGFloat = 360

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func update(candidates: [Candidate], highlighted: Int, prefs: EnginePrefs, expanded: Bool, client: IMKTextInput) {
        guard SelfInstaller.isCurrentInputSource else { hide(); return }
        guard !candidates.isEmpty else { hide(); return }
        var lineRect = NSRect.zero
        let selectedLocation = client.selectedRange().location
        let characterIndex = selectedLocation == NSNotFound ? 0 : selectedLocation
        _ = client.attributes(forCharacterIndex: characterIndex, lineHeightRectangle: &lineRect)
        let fallback = NSEvent.mouseLocation
        // A caret normally has zero width; it is still a valid text position.
        let hasCaret = lineRect.height > 0 && lineRect.origin.x.isFinite && lineRect.origin.y.isFinite
        let anchor = hasCaret ? lineRect : NSRect(origin: fallback, size: .zero)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) })
            ?? NSScreen.screens.first(where: { $0.frame.contains(fallback) })
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(origin: .zero, size: panel.frame.size)
        let belowSpace = max(0, anchor.minY - visibleFrame.minY - 16)
        let aboveSpace = max(0, visibleFrame.maxY - anchor.maxY - 16)
        availableWidth = min(540, max(240, visibleFrame.width - 40))
        availableHeight = max(60, min(420, max(belowSpace, aboveSpace) - 60))
        updateCandidates(candidates, highlighted: highlighted, prefs: prefs, expanded: expanded)
        let belowY = anchor.minY - panel.frame.height - 12
        let preferredY = panel.frame.height <= belowSpace ? belowY : anchor.maxY + 12
        let origin = NSPoint(
            x: min(max(anchor.minX, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - panel.frame.width)),
            y: min(max(preferredY, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - panel.frame.height))
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    func updateCandidates(_ candidates: [Candidate], highlighted: Int, prefs: EnginePrefs, expanded: Bool) {
        self.candidates = candidates
        self.highlighted = highlighted
        preferences = prefs
        self.expanded = expanded
        let font = NSFont.systemFont(ofSize: prefs.fontSize)
        let widths = candidates.map { candidate in
            max((candidate.word as NSString).size(withAttributes: [.font: font]).width + 44,
                prefs.showEnglishGloss ? ((candidate.displayGloss ?? "") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: max(11, prefs.fontSize - 5))]).width + 24 : 0)
        }
        verticalLayout = prefs.orientation == .vertical || (expanded ? widths.contains { $0 > 100 } : widths.reduce(40, +) > min(800, availableWidth * 1.5))
        let hosting = NSHostingView(rootView: CandidateListView(
            candidates: candidates,
            highlighted: highlighted,
            prefs: prefs,
            expanded: expanded,
            vertical: verticalLayout,
            availableWidth: availableWidth,
            availableHeight: availableHeight,
            onSelect: { [weak self] in self?.onSelect?($0) },
            onExpand: { [weak self] in self?.onExpand?() },
            onCollapse: { [weak self] in self?.onCollapse?() }
        ))
        let fittingSize = hosting.fittingSize
        let minimumHeight: CGFloat = expanded ? 70 : 50
        let contentSize = NSSize(width: max(320, fittingSize.width), height: max(minimumHeight, fittingSize.height))
        hosting.frame.size = contentSize
        panel.contentView = hosting
        panel.setContentSize(contentSize)
    }

    func updateHighlight(_ highlighted: Int) {
        updateCandidates(candidates, highlighted: highlighted, prefs: preferences, expanded: expanded)
    }

    func hide() { panel.orderOut(nil) }
}

@MainActor
final class InputModeIndicatorController {
    private let panel: NSPanel
    private var displayGeneration = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 132, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 132, height: 40))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        let badge = NSTextField(labelWithString: "中")
        badge.frame = NSRect(x: 8, y: 6, width: 28, height: 28)
        badge.font = .boldSystemFont(ofSize: 18)
        badge.alignment = .center
        badge.textColor = .white
        badge.backgroundColor = .controlAccentColor
        badge.drawsBackground = true
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.masksToBounds = true
        let title = NSTextField(labelWithString: "MyIME")
        title.frame = NSRect(x: 44, y: 10, width: 80, height: 22)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        background.addSubview(badge)
        background.addSubview(title)
        panel.contentView = background
    }

    func show(client: IMKTextInput) {
        displayGeneration += 1
        let generation = displayGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.displayGeneration == generation else { return }
            self.present(client: client, generation: generation)
        }
    }

    private func present(client: IMKTextInput, generation: Int) {
        guard displayGeneration == generation, SelfInstaller.isCurrentInputSource else {
            hide()
            return
        }
        var lineRect = NSRect.zero
        let selectedLocation = client.selectedRange().location
        let characterIndex = selectedLocation == NSNotFound ? 0 : selectedLocation
        _ = client.attributes(forCharacterIndex: characterIndex, lineHeightRectangle: &lineRect)
        let fallback = NSEvent.mouseLocation
        let hasCaret = lineRect.height > 0 && lineRect.origin.x.isFinite && lineRect.origin.y.isFinite
        let anchor = hasCaret ? lineRect : NSRect(origin: fallback, size: .zero)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
            ?? NSScreen.screens.first(where: { $0.frame.contains(fallback) })
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(origin: .zero, size: panel.frame.size)
        let origin = NSPoint(
            x: min(max(anchor.maxX + 6, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - panel.frame.width)),
            y: min(max(anchor.minY - panel.frame.height - 4, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - panel.frame.height))
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        // Keep the idle input-mode indicator visible until composition starts
        // or the input session is deactivated.
    }

    func hide() {
        displayGeneration += 1
        panel.orderOut(nil)
    }
}
