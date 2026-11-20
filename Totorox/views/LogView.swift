import SwiftUI

struct LogView: View {
    @ObservedObject var appLog = AppLog.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var language
    @State private var copied = false
    @State private var showShare = false
    @State private var shareFileURL: URL?

    /// Builds the full log text. Computed only inside actions (not in `body`)
    /// so a 100k-line log does not get re-joined on every SwiftUI render.
    private func buildLogText() -> String {
        var lines: [String] = []
        lines.append("Totorox Log")
        lines.append("iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) — \(AppInfo.machineName)")
        lines.append("Generated: \(Date())")
        lines.append("")
        lines.append(contentsOf: appLog.entries)
        return lines.joined(separator: "\n")
    }

    /// Writes the log to a real `log.txt` in the temp dir and returns its URL.
    /// Logs can contain container paths, so the temp copy is written with data
    /// protection enabled and removed again when the share sheet closes.
    private func prepareShareFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("log.txt")
        do {
            let data = Data(buildLogText().utf8)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }

    /// Deletes the temporary share copy; the log itself stays in memory.
    private func discardShareFile() {
        if let url = shareFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        shareFileURL = nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if appLog.entries.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "apple.terminal")
                            .font(.system(size: AppTheme.emptyIconSize, weight: .medium))
                            .foregroundStyle(TotoroxTheme.textSecondary)
                        Text(language.text("logs.empty_title"))
                            .font(.title3.bold())
                            .foregroundStyle(TotoroxTheme.textPrimary)
                        Text(language.text("logs.empty_message"))
                            .font(.subheadline)
                            .foregroundStyle(TotoroxTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(32)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(appLog.entries.enumerated()), id: \.offset) { index, entry in
                                    VStack(spacing: 0) {
                                        Text(entry)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(TotoroxTheme.textPrimary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 11)

                                        if index < appLog.entries.count - 1 {
                                            Divider()
                                        }
                                    }
                                    .id(index)
                                    .accessibilityLabel(language.text("accessibility.log_entry", Int64(index + 1), entry))
                                }
                            }
                            .padding(AppTheme.pageInset)
                            .background(TotoroxTheme.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(12)
                        }
                        .onChange(of: appLog.entries.count) { count in
                            guard count > 0 else { return }
                            if reduceMotion {
                                proxy.scrollTo(count - 1, anchor: .bottom)
                            } else {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(count - 1, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
            }
            .background(TotoroxTheme.pageBackground.ignoresSafeArea())
            .navigationTitle(language.text("logs.title"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showShare, onDismiss: discardShareFile) {
                if let url = shareFileURL {
                    ActivityViewControllerWrapper(activityItems: [url])
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(language.text("logs.clear"), role: .destructive) { appLog.entries.removeAll() }
                        .disabled(appLog.entries.isEmpty)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = buildLogText()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(appLog.entries.isEmpty)
                    .accessibilityLabel(language.text("logs.copy"))

                    Button {
                        if let url = prepareShareFile() {
                            shareFileURL = url
                            showShare = true
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(appLog.entries.isEmpty)
                    .accessibilityLabel(language.text("logs.share"))

                    Button(language.text("common.done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
