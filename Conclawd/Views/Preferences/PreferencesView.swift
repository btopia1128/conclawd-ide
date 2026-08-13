import SwiftUI

/// App preferences window (Cmd+,).
struct PreferencesView: View {
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.dark.rawValue
    @AppStorage(ClaudePathResolver.manualPathKey) private var claudeBinaryPath: String = ""
    @AppStorage("terminalFontSize") private var terminalFontSize: Double = 13
    @State private var detectedClaudePath: String?

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            terminalTab
                .tabItem {
                    Label("Terminal", systemImage: "terminal")
                }
        }
        .frame(width: 480, height: 320)
        .onAppear {
            detectedClaudePath = ClaudePathResolver().resolve()
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Claude CLI") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Path to claude binary (auto-detect if empty)", text: $claudeBinaryPath)
                            .textFieldStyle(.roundedBorder)

                        Button("Browse...") {
                            browseClaude()
                        }
                    }

                    if claudeBinaryPath.isEmpty {
                        if let detected = detectedClaudePath {
                            Label("Auto-detected: \(detected)", systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("claude binary not found", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else if FileManager.default.isExecutableFile(atPath: claudeBinaryPath) {
                        Label("Valid executable", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("File not found or not executable", systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Terminal

    private var terminalTab: some View {
        Form {
            Section("Font") {
                HStack {
                    Text("Font Size")
                    Slider(value: $terminalFontSize, in: 9...24, step: 1) {
                        Text("Font Size")
                    }
                    Text("\(Int(terminalFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Helpers

    private func browseClaude() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the claude CLI binary"
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")

        if panel.runModal() == .OK, let url = panel.url {
            claudeBinaryPath = url.path(percentEncoded: false)
        }
    }
}
