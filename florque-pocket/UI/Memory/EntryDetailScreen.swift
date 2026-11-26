import SwiftUI
import Observation

// Purpose: one memory entry. Shows its title, body, type and due time, then its links in sections by link type. An
// outgoing link uses the type's name ("Participates") and an incoming one its inverse name ("Has participant"), with
// each section's count. Each link shows who made it and when; proposed links can be accepted or dismissed. Tapping a
// linked item opens it.
//
// Testing: grouping and direction are in `EntryDetailModel`, tested by `EntryDetailModelTests`.

/// One related item, as the detail shows it.
struct EntryLink: Identifiable, Equatable {
    let id: UUID          // the edge id
    let node: NodeRecord  // the item on the other end
    let source: String    // "user" | "assistant"
    let createdAt: Date
    let status: String    // "accepted" | "proposed"
}

/// Links of one kind and direction, with the heading the detail shows for them.
struct EntryLinkGroup: Identifiable, Equatable {
    let id: String
    let heading: String
    let links: [EntryLink]
}

@MainActor
@Observable
final class EntryDetailModel {
    private let store: PocketStore
    let nodeId: UUID
    private(set) var node: NodeRecord?
    private(set) var groups: [EntryLinkGroup] = []
    private(set) var typeName = ""
    var errorMessage: String?

    init(store: PocketStore, nodeId: UUID) {
        self.store = store
        self.nodeId = nodeId
    }

    func load() async {
        do {
            guard let node = try await store.node(id: nodeId) else { return }
            self.node = node
            let nodeTypes = try await store.nodeTypes()
            typeName = nodeTypes.first { $0.key == node.typeKey }?.name ?? node.typeKey.capitalized
            let edgeTypes = Dictionary(uniqueKeysWithValues: try await store.edgeTypes().map { ($0.key, $0) })

            var buckets: [String: (heading: String, links: [EntryLink])] = [:]
            var order: [String] = []
            for edge in try await store.edges(touching: nodeId) {
                let outgoing = edge.fromId == nodeId
                let otherId = outgoing ? edge.toId : edge.fromId
                guard let other = try await store.node(id: otherId), let type = edgeTypes[edge.typeKey] else { continue }
                // Two-way links have no direction, so they share one group.
                let key = type.symmetric ? edge.typeKey : "\(edge.typeKey)|\(outgoing)"
                let heading = type.symmetric || outgoing ? type.name : type.inverseName
                if buckets[key] == nil { order.append(key) }
                buckets[key, default: (heading, [])].links.append(
                    EntryLink(id: edge.id, node: other, source: edge.source, createdAt: edge.createdAt, status: edge.status))
            }
            groups = order.compactMap { key in
                guard let bucket = buckets[key] else { return nil }
                return EntryLinkGroup(id: key, heading: bucket.heading, links: bucket.links)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Accepts a proposed link, or dismisses it (which removes it).
    func review(_ link: EntryLink, accept: Bool) async {
        do {
            try await store.reviewEdge(id: link.id, accept: accept)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func origin(_ source: String) -> String {
        source == "assistant" ? "Pocket" : "You"
    }
}

struct EntryDetailScreen: View {
    @State private var model: EntryDetailModel

    init(store: PocketStore, nodeId: UUID) {
        _model = State(initialValue: EntryDetailModel(store: store, nodeId: nodeId))
    }

    var body: some View {
        List {
            if let node = model.node {
                Section {
                    Text(node.title).font(.headline)
                    if !node.body.isEmpty {
                        Text(node.body)
                    }
                    LabeledContent("Type", value: model.typeName)
                    if let due = node.dueAt {
                        LabeledContent("When", value: due.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                ForEach(model.groups) { group in
                    Section("\(group.heading) (\(group.links.count))") {
                        ForEach(group.links) { link in
                            linkRow(link)
                        }
                    }
                }
            } else {
                ContentUnavailableView("This entry is gone", systemImage: "questionmark.circle")
            }
            if let message = model.errorMessage {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .navigationTitle(model.node?.title ?? "Entry")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    @ViewBuilder
    private func linkRow(_ link: EntryLink) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: link.node.id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.node.title)
                    Text("\(EntryDetailModel.origin(link.source)) · \(link.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if link.status == "proposed" {
                HStack {
                    Button("Dismiss", role: .destructive) { Task { await model.review(link, accept: false) } }
                        .buttonStyle(.bordered)
                    Button("Accept") { Task { await model.review(link, accept: true) } }
                        .buttonStyle(.borderedProminent)
                }
                .font(.footnote)
            }
        }
    }
}
