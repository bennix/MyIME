import AppKit
import InputMethodKit
import SwiftUI
import IMEKit

private struct CandidateListView: View {
    let candidates: [Candidate]
    let highlighted: Int
    let prefs: EnginePrefs
    let expanded: Bool
    let onSelect: (Int) -> Void
    let onExpand: () -> Void
    let onCollapse: () -> Void

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
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
                Text(candidateTitle(candidate.word, at: index))
                    .lineLimit(1)
                    .frame(maxWidth: expanded ? .infinity : nil, minHeight: expanded ? 28 : 34, alignment: .leading)
                    .padding(.horizontal, expanded ? 7 : 9)
                    .padding(.vertical, 2)
                    .foregroundStyle(index == highlighted ? Color.white : Color.primary)
                    .background(index == highlighted ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        if expanded, index / 6 < (candidates.count - 1) / 6 {
                            Divider()
                        }
                    }
            }
            .buttonStyle(.plain)
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
        updateCandidates(candidates, highlighted: highlighted, prefs: prefs, expanded: expanded)
        guard !candidates.isEmpty else { hide(); return }
        var lineRect = NSRect.zero
        let selectedLocation = client.selectedRange().location
        let characterIndex = selectedLocation == NSNotFound ? 0 : selectedLocation
        _ = client.attributes(forCharacterIndex: characterIndex, lineHeightRectangle: &lineRect)
        let fallback = NSEvent.mouseLocation
        let anchor = lineRect.isEmpty ? NSRect(origin: fallback, size: .zero) : lineRect
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
            ?? NSScreen.screens.first(where: { $0.frame.contains(fallback) })
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(origin: .zero, size: panel.frame.size)
        let belowY = anchor.minY - panel.frame.height - 4
        let preferredY = belowY >= visibleFrame.minY ? belowY : anchor.maxY + 4
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
        let hosting = NSHostingView(rootView: CandidateListView(
            candidates: candidates,
            highlighted: highlighted,
            prefs: prefs,
            expanded: expanded,
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
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView:
            HStack(spacing: 7) {
                Text("中")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
                Text("MyIME")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 1)
            }
        )
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
        var lineRect = NSRect.zero
        let selectedLocation = client.selectedRange().location
        let characterIndex = selectedLocation == NSNotFound ? 0 : selectedLocation
        _ = client.attributes(forCharacterIndex: characterIndex, lineHeightRectangle: &lineRect)
        let fallback = NSEvent.mouseLocation
        let anchor = lineRect.isEmpty ? NSRect(origin: fallback, size: .zero) : lineRect
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.displayGeneration == generation else { return }
            self.panel.orderOut(nil)
        }
    }

    func hide() {
        displayGeneration += 1
        panel.orderOut(nil)
    }
}
