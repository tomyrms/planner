import Testing
@testable import Planner

struct TagPresentationTests {
    @Test func anEmptySelectionHasNoVisibleLabel() {
        #expect(TagPresentation.summary([]) == "")
    }

    @Test func twoNamesShareOneLineWithoutRepeatedHashtags() {
        #expect(TagPresentation.summary(["Personnel", "Projet"]) == "Personnel · Projet")
    }

    @Test func overflowKeepsAnAccurateCount() {
        let tags = ["Personnel", "Projet", "Études", "Maison"]
        #expect(TagPresentation.summary(tags) == "Personnel · Projet +2")
        #expect(TagPresentation.summary(tags, visibleCount: 1) == "Personnel +3")
        #expect(TagPresentation.summary(tags, visibleCount: 0) == "4")
        #expect(TagPresentation.summary(tags, visibleCount: -1) == "4")
        #expect(TagPresentation.summary(tags, visibleCount: 20) == "Personnel · Projet · Études · Maison")
    }

    @Test func importedLineBreaksCannotExpandTheRow() {
        #expect(TagPresentation.summary([" Projet\n personnel  ", "Cours\tdu soir"]) == "Projet personnel · Cours du soir")
    }

    @Test func searchAcceptsAccentsCaseAndAnOptionalHash() {
        #expect(TagPresentation.matches("Études", query: " #ETU "))
        #expect(TagPresentation.matches("Personnel", query: "  "))
        #expect(!TagPresentation.matches("Personnel", query: "Travail"))
    }
}
