import Testing
@testable import EyesOnly

@Suite("Site rules")
struct SiteRuleTests {
    @Test func matchesTheHostAndItsSubdomains() {
        #expect(siteMatches("https://mail.google.com/mail/u/0", "mail.google.com"))
        #expect(siteMatches("https://example.com/", "example.com"))
        #expect(siteMatches("https://www.example.com/", "example.com"))
        #expect(siteMatches("https://a.b.example.com/x", "example.com"))
    }

    @Test func doesNotMatchOtherHosts() {
        #expect(!siteMatches("https://notexample.com/", "example.com"))
        #expect(!siteMatches("https://example.com.evil.io/", "example.com"))
        #expect(!siteMatches("https://google.com/", "mail.google.com"))
    }

    @Test func pathRulesMatchOnlyUnderThatPath() {
        #expect(siteMatches("https://bank.com/accounts", "bank.com/accounts"))
        #expect(siteMatches("https://bank.com/accounts/123?x=1", "bank.com/accounts"))
        #expect(!siteMatches("https://bank.com/", "bank.com/accounts"))
        #expect(!siteMatches("https://bank.com/help", "bank.com/accounts"))
    }

    @Test func ignoresSchemeWildcardCaseAndTrailingSlash() {
        #expect(siteMatches("https://mail.google.com/", "https://mail.google.com/"))
        #expect(siteMatches("https://mail.google.com/", "*.google.com"))
        #expect(siteMatches("https://Mail.Google.com/Inbox", "MAIL.google.com/inbox"))
        #expect(siteMatches("https://example.com/", "  example.com  "))
    }

    @Test func emptyRulesAndPagesWithoutAHostMatchNothing() {
        #expect(!siteMatches("https://example.com/", ""))
        #expect(!siteMatches("https://example.com/", "https://"))
        #expect(!siteMatches("chrome://newtab/", "example.com"))
        #expect(!siteMatches("not a url", "example.com"))
    }
}
