import Foundation
import Testing
@testable import foofoil

struct WebAddressSearchTextTests {
    @Test func keepsOnlyHostAndPath() {
        #expect(WebAddressSearchText.make(from: "https://example.com/docs/page?ref=1#section") == "example.com/docs/page")
        #expect(WebAddressSearchText.make(from: "http://example.com") == "example.com/")
        #expect(WebAddressSearchText.make(from: "https://user:pass@example.com:8443/a") == "example.com/a")
        #expect(WebAddressSearchText.make(from: "file:///tmp/page.html") == "/tmp/page.html")
        #expect(WebAddressSearchText.make(from: "about:blank") == nil)
    }

    @Test func matchingIgnoresSchemePortQueryAndFragment() {
        let address = "https://example.com:8443/guide/start?token=secret#intro"
        #expect(WebAddressSearchText.matches(address, query: "example.com/guide"))
        #expect(WebAddressSearchText.matches(address, query: "GUIDE/START"))
        #expect(!WebAddressSearchText.matches(address, query: "https"))
        #expect(!WebAddressSearchText.matches(address, query: "8443"))
        #expect(!WebAddressSearchText.matches(address, query: "token=secret"))
        #expect(!WebAddressSearchText.matches(address, query: "intro"))
    }
}
