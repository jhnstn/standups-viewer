import SwiftUI

@main
struct StandupsApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        WindowGroup("Standups") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button(store.hasToday ? "Update Today's Standup" : "Generate Today's Standup") { store.generate() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(store.isGenerating)
                Button("Reload") { store.reload() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { store.revealInFinder() } label: { Label("Reveal in Finder", systemImage: "folder") }
                    .help("Reveal in Finder")
            }
            ToolbarItem(placement: .primaryAction) {
                generateButton
            }
        }
        .alert("Generation problem", isPresented: Binding(
            get: { store.errorText != nil }, set: { if !$0 { store.errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorText ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $store.selectedID) {
            if store.periods.isEmpty {
                Text("No standups yet").foregroundStyle(.secondary)
            }
            ForEach(store.periods) { period in
                Section(period.label) {
                    ForEach(period.items) { s in
                        HStack {
                            Text(s.dayLabel)
                            Spacer()
                            if s.id == store.todayID {
                                Text("today").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(s.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if store.isGenerating || !store.statusText.isEmpty {
                HStack(spacing: 8) {
                    if store.isGenerating { ProgressView().controlSize(.small) }
                    Text(store.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if store.isGenerating {
                        Button("Cancel") { store.cancelGeneration() }.controlSize(.small)
                    }
                }
                .padding(10)
                .background(.bar)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            if !store.frontmatter.isEmpty {
                HStack(spacing: 14) {
                    if let w = store.frontmatter["window"] {
                        Label(w, systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                    }
                    if let t = store.frontmatter["threads"] {
                        Label(t.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 32).padding(.vertical, 8)
                Divider()
            }
            MarkdownView(markdown: store.markdown) { index, checked in
                store.toggleTask(index: index, checked: checked)
            }
        }
        .navigationTitle(store.selectedID ?? "Standups")
    }

    private var generateButton: some View {
        Button {
            store.generate()
        } label: {
            Label(store.hasToday ? "Update today" : "Generate today",
                  systemImage: store.hasToday ? "arrow.triangle.2.circlepath" : "sparkles")
        }
        .labelStyle(.titleAndIcon)
        .disabled(store.isGenerating)
        .help(store.hasToday
              ? "Add today's progress to today's standup: ticks off finished items, leaves Yesterday alone (⌘G)"
              : "Generate today's standup via claude (⌘G)")
    }
}
