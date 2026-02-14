import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct HistoryView: View {
    @EnvironmentObject private var historyStore: TranscriptHistoryStore
    @State private var selectedText = ""
    @State private var showShare = false

    var body: some View {
        List {
            ForEach(historyStore.entries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.transcript)
                        .font(.body)
                        .foregroundStyle(WhisperTheme.primaryText)
                        .lineLimit(3)

                    HStack {
                        Text(entry.createdAt, style: .date)
                        Text("•")
                        Text(entry.engine.title)
                        if entry.usedCloud {
                            Text("• Cloud")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(WhisperTheme.secondaryText)

                    HStack {
                        Button("Copy") {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = entry.transcript
                            #endif
                        }
                        Button("Share") {
                            selectedText = entry.transcript
                            showShare = true
                        }
                    }
                    .font(.caption)
                }
                .padding(.vertical, 6)
            }
            .onDelete { idx in
                idx.map { historyStore.entries[$0] }.forEach(historyStore.remove)
            }
        }
        .scrollContentBackground(.hidden)
        .background(WhisperTheme.background)
        .navigationTitle("History")
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [selectedText])
        }
    }
}
