import SwiftUI

/// Reads the session's shared tag projection. Each label has its own navigation/accessibility target;
/// it is deliberately outside the task's edit button and its combined accessibility sentence.
struct TaskTagLinks: View {
    let taskId: String
    @Environment(AppServices.self) private var services

    var body: some View {
        let tags = services.tagDirectory.tags(for: taskId)
        if !tags.isEmpty {
            TagLabelFlow {
                ForEach(tags) { tag in
                    NavigationLink {
                        TagTasksView(tag: tag)
                    } label: {
                        TaskTagLabel(name: tag.name)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Tag \(tag.name)")
                    .accessibilityHint("Afficher les tâches avec ce tag")
                }
            }
        }
        if services.tagDirectory.failed {
            Button("Tags indisponibles · Réessayer", systemImage: "arrow.clockwise") {
                services.tagDirectory.start(services.tasks)
            }
            .font(.footnote)
            .buttonStyle(.borderless)
            .frame(minHeight: TouchTarget.comfort)
            .disabled(services.isRecoverySuspended)
        }
    }
}

/// Text carries the tag; colour is only a navigation affordance, never a category code.
struct TaskTagLabel: View {
    let name: String

    var body: some View {
        Text("#\(name)")
            .font(.subheadline)
            .foregroundStyle(Color.accentColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: TouchTarget.comfort, minHeight: TouchTarget.comfort, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// Natural-width labels wrap rather than truncate or disappear into a horizontal scroll area.
/// A label longer than the available width uses multiple lines, including at accessibility sizes.
struct TagLabelFlow: Layout {
    var horizontalSpacing: CGFloat = 12
    var verticalSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width proposed: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let width = max(0, proposed ?? .infinity)
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(width, ideal.width), height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + lineHeight), frames)
    }
}

/// Anonymous component board for CI review; no database, navigation or service is constructed.
struct TaskTagsPreview: View {
    private let names = ["Études", "À préparer", "Révisions du semestre de printemps", "Maison"]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Mes tâches").font(.title2.weight(.semibold))
            Text("Préparer le prochain cours").font(.body)
            Text("Demain · 45 min").font(.subheadline).foregroundStyle(.secondary)
            TagLabelFlow {
                ForEach(names, id: \.self) { name in
                    Button {} label: { TaskTagLabel(name: name) }.buttonStyle(.borderless)
                }
            }
            Divider()
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
