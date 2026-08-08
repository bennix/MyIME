import AppKit
import IMEKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var preferences = PreferencesStore.load()
    @State private var message = ""

    var body: some View {
        TabView {
            general
                .tabItem { Label("通用", systemImage: "gearshape") }
            fuzzy
                .tabItem { Label("模糊音", systemImage: "waveform") }
            appearance
                .tabItem { Label("皮肤", systemImage: "paintpalette") }
            dictionaries
                .tabItem { Label("词库", systemImage: "books.vertical") }
        }
        .padding(16)
        .onChange(of: preferences) { _, value in PreferencesStore.save(value) }
    }

    private var general: some View {
        Form {
            Picker("每页候选数", selection: $preferences.pageSize) {
                ForEach(3...9, id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle("输出繁体（需要 OpenCC 数据，未安装时保持简体）", isOn: $preferences.outputTraditional)
            LabeledContent("默认上屏键", value: "空格")
            LabeledContent("默认翻页键", value: "- / = 或 , / .")
            LabeledContent("中英文切换", value: "单击 Shift")
        }
        .formStyle(.grouped)
    }

    private var fuzzy: some View {
        Form {
            fuzzyToggle("z = zh", keyPath: \.zZh)
            fuzzyToggle("c = ch", keyPath: \.cCh)
            fuzzyToggle("s = sh", keyPath: \.sSh)
            fuzzyToggle("n = l", keyPath: \.nL)
            fuzzyToggle("f = h", keyPath: \.fH)
            fuzzyToggle("r = l", keyPath: \.rL)
            fuzzyToggle("an = ang", keyPath: \.anAng)
            fuzzyToggle("en = eng", keyPath: \.enEng)
            fuzzyToggle("in = ing", keyPath: \.inIng)
            fuzzyToggle("ian = iang", keyPath: \.ianIang)
            fuzzyToggle("uan = uang", keyPath: \.uanUang)
        }
        .formStyle(.grouped)
    }

    private var appearance: some View {
        Form {
            Slider(value: $preferences.fontSize, in: 13...28, step: 1) { Text("候选字号") }
            LabeledContent("字号", value: "\(Int(preferences.fontSize)) pt")
            Toggle("跟随系统深浅色", isOn: $preferences.followsSystemAppearance)
            Picker("候选排列", selection: $preferences.orientation) {
                Text("横向").tag(CandidateOrientation.horizontal)
                Text("纵向").tag(CandidateOrientation.vertical)
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
    }

    private var dictionaries: some View {
        Form {
            Section("系统词库") {
                let metadata = IMEEnvironment.shared.systemStore?.metadata ?? [:]
                LabeledContent("Schema", value: metadata["schema_version"] ?? "不可用")
                LabeledContent("词条数", value: metadata["entry_count"] ?? "0")
                LabeledContent("Build hash", value: metadata["build_hash"] ?? "—")
                sourceToggle("雾凇拼音", bit: 0)
                unavailableSource("CustomPinyin（等待再分发授权）")
                sourceToggle("中文维基", bit: 2)
                sourceToggle("景行词库", bit: 3)
                unavailableSource("专业词库（等待再分发授权）")
                sourceToggle("搜狗分类整理", bit: 5)
                sourceToggle("清华开放中文词库（THUOCL）", bit: 10)
                unavailableSource("程序员术语（等待再分发授权）")
                Button("校验并替换 system.sqlite…", action: replaceDictionary)
            }
            Section("用户词组与学习") {
                Button("导入 TSV…", action: importUserWords)
                Button("导出 TSV…", action: exportUserWords)
                Button("清空使用频率", role: .destructive) { IMEEnvironment.shared.userStore?.clearLearning() }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }

    private func fuzzyToggle(_ title: String, keyPath: WritableKeyPath<FuzzyRules, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { preferences.fuzzy[keyPath: keyPath] },
            set: { preferences.fuzzy[keyPath: keyPath] = $0 }
        ))
    }

    private func sourceToggle(_ title: String, bit: Int) -> some View {
        let mask = 1 << bit
        return Toggle(title, isOn: Binding(
            get: { preferences.disabledSourceMask & mask == 0 },
            set: { enabled in
                if enabled { preferences.disabledSourceMask &= ~mask }
                else { preferences.disabledSourceMask |= mask }
            }
        ))
    }

    private func unavailableSource(_ title: String) -> some View {
        Toggle(title, isOn: .constant(false))
            .disabled(true)
    }

    private func importUserWords() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tsv") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let result = IMEEnvironment.shared.userStore?.importTSV(from: url) ?? (imported: 0, rejected: 0)
        message = "已导入 \(result.imported) 条，拒绝 \(result.rejected) 条。"
    }

    private func exportUserWords() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MyIME-user-phrases.tsv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try IMEEnvironment.shared.userStore?.exportTSV(to: url)
            message = "用户词组已导出。"
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }

    private func replaceDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .database, UTType(filenameExtension: "db") ?? .database]
        guard panel.runModal() == .OK, let source = panel.url,
              let store = SQLiteStore(path: source.path), store.integrityCheck() else {
            message = "词库未通过 schema 或完整性校验。"
            return
        }
        let target = URL(fileURLWithPath: RuntimePaths.replacementSystemDatabase)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = target.appendingPathExtension("new")
            try? FileManager.default.removeItem(at: temporary)
            try FileManager.default.copyItem(at: source, to: temporary)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            message = "词库已替换；重新切换输入源后生效。"
        } catch {
            do {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
                message = "词库已安装；重新切换输入源后生效。"
            } catch {
                message = "替换失败：\(error.localizedDescription)"
            }
        }
    }
}
