import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @EnvironmentObject private var viewModel: DictationViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var historyStore: TranscriptHistoryStore

    @State private var apiKeyInput = ""
    @State private var keySaved = false

    @State private var newFindTerm = ""
    @State private var newReplacementTerm = ""

    var body: some View {
        Form {
            Section("Privacy Mode") {
                Picker("Mode", selection: $settings.privacyMode) {
                    ForEach(PrivacyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Text(settings.privacyMode.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let cloudBlockMessage {
                    Text(cloudBlockMessage)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            Section("Transcript Retention") {
                Picker("History", selection: $settings.retentionPolicy) {
                    ForEach(TranscriptRetentionPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                Text(settings.retentionPolicy.details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Apply retention cleanup now") {
                    historyStore.updateRetentionPolicy(settings.retentionPolicy)
                }
                .font(.footnote)
            }

            Section("Output Style") {
                Picker("Mode", selection: $settings.outputStyleMode) {
                    ForEach(OutputStyleMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode)
                    }
                }

                Label(settings.outputStyleMode.details, systemImage: settings.outputStyleMode.symbolName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Personal Dictionary") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Find phrase (e.g. cloo ai)", text: $newFindTerm)
                    TextField("Replace with (e.g. ClooAI)", text: $newReplacementTerm)

                    Button("Add Rule") {
                        settings.addReplacementRule(find: newFindTerm, replaceWith: newReplacementTerm)
                        newFindTerm = ""
                        newReplacementTerm = ""
                    }
                    .disabled(newFindTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if settings.replacementRules.isEmpty {
                    Text("No custom replacements yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.replacementRules) { rule in
                        HStack {
                            TextField("Find", text: Binding(
                                get: { rule.find },
                                set: { settings.updateReplacementRule(id: rule.id, find: $0, replaceWith: rule.replaceWith) }
                            ))

                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)

                            TextField("Replace", text: Binding(
                                get: { rule.replaceWith },
                                set: { settings.updateReplacementRule(id: rule.id, find: rule.find, replaceWith: $0) }
                            ))
                        }
                    }
                    .onDelete(perform: settings.removeReplacementRules)
                }
            }

            Section("Cloud Transcription (OpenAI)") {
                Toggle("Enable Cloud Transcription", isOn: $settings.cloudTranscriptionEnabled)
                Toggle("I consent to send audio to OpenAI", isOn: $settings.cloudConsentGranted)

                SecureField("OpenAI API Key", text: $apiKeyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

                HStack {
                    Button("Save Key") {
                        keySaved = KeychainService.shared.save(apiKeyInput, for: SecureKeys.openAIAPIKey)
                        if keySaved { apiKeyInput = "" }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Remove Key", role: .destructive) {
                        _ = KeychainService.shared.delete(for: SecureKeys.openAIAPIKey)
                        keySaved = false
                    }
                    .buttonStyle(.bordered)
                }

                Text(keySaved || hasStoredAPIKey ? "API key is stored securely in Keychain." : "No API key found.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Provider Profiles") {
                if !settings.isFeatureAvailable(.providerProfiles) {
                    Text("Pro feature. Unlock to configure provider profiles.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Picker("Active Profile", selection: $settings.selectedProviderProfileID) {
                    ForEach(ProviderProfile.allProfiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .disabled(!settings.isFeatureAvailable(.providerProfiles))

                ForEach(ProviderProfile.allProfiles) { profile in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(profile.name)
                            if !profile.supportsCurrentBuild {
                                Text("Coming Soon")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.gray.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                        Text(profile.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Data flow: \(profile.dataFlowSummary)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Subscription") {
                Toggle("Unlock Pro (local dev)", isOn: $settings.proTierUnlocked)
                Text(settings.proTierUnlocked ? "Pro is active. Advanced features are available." : "Free tier active. Core dictation remains fully available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Reliability") {
                Toggle("Show Metrics View", isOn: $settings.showDebugMetrics)

                if settings.showDebugMetrics {
                    NavigationLink("Open Metrics Dashboard") {
                        DebugMetricsView()
                    }
                }
            }

            Section("Keyboard Companion") {
                Text("WhisperSmart Keyboard keeps the Apple-style base typing layout and adds two top actions: Insert Latest and Mic.")
                Text("Setup: iOS Settings → General → Keyboard → Keyboards → Add New Keyboard → WhisperSmart Keyboard.")
                Text("Use the system Globe key to switch keyboards. Use 123/ABC to switch key modes.")
                Text("Tap Mic in the top row to open WhisperSmart capture, then return and confirm when your transcript is ready.")
                Text("When the app writes a new transcript, the keyboard marks it ready for quick insert. iOS keyboard extensions still cannot record microphone audio directly.")

                Button("Open iOS Settings") {
                    openSystemSettings()
                }
                .buttonStyle(.bordered)

                Button("Clear Keyboard Companion Cache", role: .destructive) {
                    KeyboardCompanionStore.shared.clearCache()
                }
                .buttonStyle(.bordered)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Section("Trust & Transparency") {
                Text("Private Offline keeps audio local. Balanced and Cloud Fast may send audio to OpenAI when enabled and consented.")
                Text("History retention controls how long transcripts remain on this device.")
                Text("You can disable cloud, revoke consent, remove API keys, and delete history at any time.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Section("Current Runtime") {
                Text(viewModel.privacyIndicator)
                    .font(.footnote)
            }
        }
        .scrollContentBackground(.hidden)
        .background(WhisperTheme.background)
        .navigationTitle("Settings")
    }

    private var hasStoredAPIKey: Bool {
        KeychainService.shared.read(for: SecureKeys.openAIAPIKey)?.isEmpty == false
    }

    private var cloudBlockMessage: String? {
        guard settings.privacyMode != .privateOffline else { return nil }
        let policy = CloudTranscriptionPolicy.evaluate(
            cloudEnabled: settings.cloudTranscriptionEnabled,
            cloudConsentGranted: settings.cloudConsentGranted,
            hasAPIKey: hasStoredAPIKey,
            requireNetwork: settings.privacyMode == .balanced,
            networkReachable: NetworkMonitor.shared.isReachable
        )
        guard !policy.isAllowed else { return nil }
        return "Cloud route is currently blocked: \(policy.reason?.userMessage ?? "Unknown reason")"
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

struct DebugMetricsView: View {
    @EnvironmentObject private var metricsStore: ReliabilityMetricsStore

    var body: some View {
        List {
            Section("Session Counters") {
                metricRow("Start attempts", value: metricsStore.metrics.startAttempts)
                metricRow("Successful finalizations", value: metricsStore.metrics.successfulFinalizations)
                metricRow("Failures", value: metricsStore.metrics.failures)
                metricRow("Balanced local fallbacks", value: metricsStore.metrics.localFallbacks)
            }

            Section("Cloud vs Local Routing") {
                metricRow("Cloud sessions", value: metricsStore.metrics.cloudSessions)
                metricRow("Local sessions", value: metricsStore.metrics.localSessions)
                metricRow("Cloud usage ratio", value: "\(metricsStore.metrics.cloudUsageRatioPercent)%")
            }

            Section("Fallback / Block Reasons") {
                metricRow("Cloud disabled", value: metricsStore.metrics.fallbackCloudDisabled)
                metricRow("Consent missing", value: metricsStore.metrics.fallbackConsentMissing)
                metricRow("API key missing", value: metricsStore.metrics.fallbackAPIKeyMissing)
                metricRow("Network unavailable", value: metricsStore.metrics.fallbackNetworkUnavailable)
                metricRow("Consent-block events", value: metricsStore.metrics.consentBlockEvents)
            }

            Section("Retention Cleanup") {
                metricRow("Cleanup runs", value: metricsStore.metrics.retentionCleanupRuns)
                metricRow("Deleted history entries", value: metricsStore.metrics.retentionDeletedEntries)
            }

            Section("Latency") {
                metricRow("Average final latency", value: "\(metricsStore.metrics.averageLatencyMs) ms")
            }

            Section {
                Button("Reset Metrics", role: .destructive) {
                    metricsStore.reset()
                }
            }
        }
        .navigationTitle("Metrics")
    }

    @ViewBuilder
    private func metricRow(_ title: String, value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func metricRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}
