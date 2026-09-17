import SwiftUI
import UIKit
import XCTest
@testable import Planner

/// Review artifacts from the real SwiftUI presentation components and synthetic fixtures only.
/// These are not pixel baselines or proof of keyboard, scrolling, gestures, or VoiceOver on a device.
final class AssistantChatRenderTests: XCTestCase {
    // An async XCTest method avoids the synchronous actor-isolated test-discovery bridge.
    @MainActor
    func testChatReviewImages() async throws {
        try attach(AssistantChatPreview(kind: .empty), name: "01-empty-light")
        try attach(AssistantChatPreview(kind: .empty), name: "02-empty-dark", appearance: .dark)
        try attach(AssistantChatPreview(kind: .result), name: "03-result-light")
        try attach(AssistantChatPreview(kind: .result), name: "04-result-dark", appearance: .dark)
        try attach(AssistantChatPreview(kind: .proposal), name: "05-proposal-light")
        try attach(AssistantChatPreview(kind: .recovery), name: "06-recovery-dark", appearance: .dark)
        try attach(AssistantChatPreview(kind: .voice), name: "07-voice-light")
        try attach(
            AssistantChatPreview(kind: .result), name: "08-result-dark-accessibility3",
            appearance: .dark, typeSize: .accessibility3
        )
        try attach(
            AssistantChatPreview(kind: .proposal), name: "09-proposal-light-accessibility3",
            typeSize: .accessibility3
        )
        try attach(TaskSubtasksPreview(expanded: false), name: "10-subtasks-collapsed-light")
        try attach(TaskSubtasksPreview(expanded: true), name: "11-subtasks-expanded-dark", appearance: .dark)
        try attach(TaskSubtasksPreview(expanded: true), name: "12-subtasks-expanded-accessibility3", typeSize: .accessibility3)
    }

    @MainActor
    private func attach<Content: View>(
        _ content: Content, name: String, appearance: ColorScheme = .light,
        typeSize: DynamicTypeSize = .large
    ) throws {
        let width: CGFloat = 393
        // The live timeline scrolls; its pure preview uses a stack. Give large-text component
        // boards room to expand vertically instead of manufacturing truncation in that fixture.
        let height: CGFloat = typeSize.isAccessibilitySize ? 1_600 : 852
        let view = content
            .frame(width: width, height: height, alignment: .topLeading)
            .background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, appearance)
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.locale, Locale(identifier: "fr_CH"))
            .transaction { transaction in transaction.disablesAnimations = true }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.isOpaque = true
        // Read actor-isolated properties before entering XCTest's nonisolated autoclosures.
        let renderedImage = renderer.uiImage
        let image = try XCTUnwrap(renderedImage, "ImageRenderer did not produce \(name)")
        let encodedPNG = image.pngData()
        let png = try XCTUnwrap(encodedPNG, "PNG encoding failed for \(name)")
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
