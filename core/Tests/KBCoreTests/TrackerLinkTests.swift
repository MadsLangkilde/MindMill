import Testing
@testable import KBCore

struct TrackerLinkTests {
    @Test func namesFollowTheTracker() {
        #expect(TrackerLink.name("azure-devops") == "Azure DevOps")
        #expect(TrackerLink.name("jira") == "Jira")
        #expect(TrackerLink.name("local") == "Mindmill")
        #expect(TrackerLink.name(forURL: "https://acme.atlassian.net/browse/APP-1") == "Jira")
        #expect(TrackerLink.name(forURL: "https://dev.azure.com/x/y/_workitems/edit/1") == "Azure DevOps")
    }

    @Test func urlsPerTracker() {
        #expect(TrackerLink.url(kind: "azure-devops", organization: "Contoso", project: "Acme App", item: "#123")?.absoluteString
                == "https://dev.azure.com/Contoso/Acme%20App/_workitems/edit/123")
        #expect(TrackerLink.url(kind: "jira", organization: "acme.atlassian.net", project: "APP", item: "12")?.absoluteString
                == "https://acme.atlassian.net/browse/APP-12")
        #expect(TrackerLink.url(kind: "jira", organization: "https://acme.atlassian.net/", project: "", item: "WEB-3")?.absoluteString
                == "https://acme.atlassian.net/browse/WEB-3")
        #expect(TrackerLink.url(kind: "github", organization: "me", project: "repo", item: "7")?.absoluteString
                == "https://github.com/me/repo/issues/7")
        #expect(TrackerLink.url(kind: "local", organization: "", project: "", item: "7") == nil)
        #expect(TrackerLink.url(kind: "azure-devops", organization: "Contoso", project: "", item: "7") == nil)
    }

    @Test func sessionWorkItem() {
        #expect(TrackerLink.workItem(about: "wi:42") { _ in nil } == "42")
        #expect(TrackerLink.workItem(about: "app/backlog/2026-11-24-login") { _ in "77" } == "77")
        #expect(TrackerLink.workItem(about: "discussion:app/discussions/x") { _ in "1" } == nil)
        #expect(TrackerLink.workItem(about: nil) { _ in "1" } == nil)
    }
}
