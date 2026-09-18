import SwiftUI

/// A quiet, single-line summary in the task row. The full catalogue remains one tap away.
/// The hit area stays accessible without giving each tag a separate 44-point-high row.
struct TaskTagLinks: View {
    let taskId: String
    @Environment(AppServices.self) private var services
    @State private var showingTags = false

    var body: some View {
        let tags = services.tagDirectory.tags(for: taskId)
        Group {
            if services.tagDirectory.failed {
                Button {
                    services.tagDirectory.start(services.tasks)
                } label: {
                    Image(systemName: "tag.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Tags indisponibles")
                .accessibilityHint("Réessayer la lecture des tags")
                .disabled(services.isRecoverySuspended)
            } else if tags.count == 1, let tag = tags.first {
                NavigationLink {
                    TagTasksView(tag: tag)
                } label: {
                    TaskTagSummaryLabel(names: [tag.name])
                        .frame(minHeight: TouchTarget.comfort)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Tag \(tag.name)")
                .accessibilityHint("Afficher les tâches avec ce tag")
            } else if !tags.isEmpty {
                Button { showingTags = true } label: {
                    TaskTagSummaryLabel(names: tags.map(\.name))
                        .frame(minHeight: TouchTarget.comfort)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Tags : " + tags.map(\.name).joined(separator: ", "))
                .accessibilityHint("Afficher tous les tags de cette tâche")
            }
        }
        .sheet(isPresented: $showingTags) { TaskTagsSheet(taskId: taskId) }
    }
}

/// Width, not a character count, decides whether two names, one name or a count fits.
/// No wrapping, scrolling, coloured pills, or repeated hash signs. Full names remain accessible.
struct TaskTagSummaryLabel: View {
    let names: [String]

    var body: some View {
        if !names.isEmpty {
            ViewThatFits(in: .horizontal) {
                label(visibleCount: 2).fixedSize(horizontal: true, vertical: false)
                label(visibleCount: 1).fixedSize(horizontal: true, vertical: false)
                label(visibleCount: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(minWidth: TouchTarget.comfort, maxWidth: 120, alignment: .trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tags : " + names.joined(separator: ", "))
        }
    }

    private func label(visibleCount: Int) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "tag").accessibilityHidden(true)
            Text(TagPresentation.summary(names, visibleCount: visibleCount))
                .lineLimit(1)
        }
    }
}

/// Kept live while open: a rename/removal must not leave stale labels in an overflow menu.
private struct TaskTagsSheet: View {
    let taskId: String
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(services.tagDirectory.tags(for: taskId)) { tag in
                        NavigationLink { TagTasksView(tag: tag) } label: {
                            Label(tag.name, systemImage: "tag")
                                .foregroundStyle(.primary)
                        }
                    }
                    if services.tagDirectory.failed {
                        Button("Réessayer la lecture des tags", systemImage: "arrow.clockwise") {
                            services.tagDirectory.start(services.tasks)
                        }
                        .disabled(services.isRecoverySuspended)
                    } else if services.tagDirectory.tags(for: taskId).isEmpty {
                        Text("Aucun tag sur cette tâche.").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Choisissez un tag pour retrouver les tâches associées.")
                }
                Section {
                    NavigationLink { TagsView() } label: {
                        Label("Gérer les tags", systemImage: "tag")
                    }
                }
            }
            .navigationTitle("Tags de la tâche")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}

/// Anonymous component board for CI review, including constrained widths and long names.
struct TaskTagsPreview: View {
    private let examples: [(String, [String])] = [
        ("Préparer le cours", ["Études", "Projet"]),
        ("Appeler le garage", ["Personnel"]),
        ("Relire les notes de la semaine", ["Révisions du semestre de printemps", "Maison", "Études", "Projet"]),
        ("Sans tag", []),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Mes tâches").font(.title2.weight(.semibold))
            ForEach(examples.indices, id: \.self) { index in
                HStack(spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(examples[index].0).font(.body)
                        Text("Demain · 45 min").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    TaskTagSummaryLabel(names: examples[index].1)
                }
                .frame(minHeight: TouchTarget.comfort)
                Divider()
            }
            Text("Tags").font(.headline).padding(.top, Spacing.lg)
            TagCatalogueLabel(name: "Études", activeCount: 3)
            TagCatalogueLabel(name: "Maison", activeCount: 0)
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .background(Color(uiColor: .systemBackground))
    }
}

#Preview("Tags") { TaskTagsPreview() }
#Preview("Tags · grand texte") { TaskTagsPreview().dynamicTypeSize(.accessibility3) }
