import Foundation
import Testing

@testable import ito_runner

@Suite("HiAnime Scraper Tests")
struct HiAnimeScraperTests {

    let wasmPath = URL(
        fileURLWithPath: "/Users/cao/proj/apps/ito-runner/projects/hianime/hianime.ito")

    @Test("Load HiAnime Plugin and Fetch Home & Anime List")
    func testHiAnimeList() async throws {
        let runner = ItoRunner()
        await runner.setNetModule(DefaultNetModule())
        await runner.setStdModule(DefaultStdModule())
        await runner.setHtmlModule(DefaultHtmlModule())
        await runner.setJsModule(DefaultJsModule())

        _ = try await runner.loadBundle(from: wasmPath)

        let homeResult = try await runner.getHome()
        #expect(!homeResult.components.isEmpty, "Home should return some components")

        let recentlyUpdatedListing = Listing(
            id: "recently_updated", name: "Recently Updated", kind: 0)
        let pageResult = try await runner.getAnimeList(listing: recentlyUpdatedListing, page: 1)

        #expect(!pageResult.entries.isEmpty, "Anime list should return some entries")

        if let first = pageResult.entries.first {
            #expect(!first.key.isEmpty)
            #expect(!first.title.isEmpty)
            print("First anime fetched: \(first.title)")
        }
    }
}
