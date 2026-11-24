import Foundation
import Testing
@testable import KBCore

struct AzureSignInTests {
    static let expired = """
    ERROR: AADSTS700082: The refresh token has expired due to inactivity. The token was issued on 2026-03-26T13:59:36Z and was inactive for 90.00:00:00. Trace ID: ab14
    Run the command below to authenticate interactively; additional arguments may be added as needed:
    az logout
    """

    @Test func tellsAnExpiredSignInFromOtherReplies() {
        #expect(AzureSignIn.isProblem(Self.expired))
        #expect(AzureSignIn.isProblem("The Azure CLI still has the expired sign-in. In a terminal, run `az login`."))
        #expect(!AzureSignIn.isProblem("Posted all four comments on the pull request."))
    }

    @Test func afterSigningInOnlyAnActualErrorCounts() {
        #expect(!AzureSignIn.isProblem("Now that az login worked, I posted all four comments.", justSignedIn: true))
        #expect(AzureSignIn.isProblem(Self.expired, justSignedIn: true))
    }

    @Test func shortReasonIsTheCodeAndFirstSentence() {
        #expect(AzureSignIn.shortReason(Self.expired) == "AADSTS700082: The refresh token has expired due to inactivity.")
        #expect(AzureSignIn.shortReason("ERROR: Please run 'az login' to setup account.\nmore") == "ERROR: Please run 'az login' to setup account.")
        #expect(AzureSignIn.shortReason("") == nil)
    }

    @Test func findsTheSignInPage() {
        let out = "A web browser has been opened at https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize. Please continue the login in the web browser."
        #expect(AzureSignIn.signInURL(in: out)?.absoluteString == "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize")
        #expect(AzureSignIn.signInURL(in: "Retrieving tenants and subscriptions…") == nil)
    }

    @Test func readsTheExpiry() {
        #expect(AzureSignIn.expiry("2026-11-21 09:40:12.000000\n") == "2026-11-21 09:40")
        #expect(AzureSignIn.expiry("2026-11-21T09:40:12+00:00") == "2026-11-21 09:40")
        #expect(AzureSignIn.expiry(Self.expired) == nil)
    }

    @Test func findsAzOnThePathFirst() {
        let found = AzureSignIn.executable(path: "/usr/bin:/custom/bin") { $0 == "/custom/bin/az" || $0 == "/opt/homebrew/bin/az" }
        #expect(found?.path == "/custom/bin/az")
        #expect(AzureSignIn.executable(path: nil) { $0 == "/opt/homebrew/bin/az" }?.path == "/opt/homebrew/bin/az")
        #expect(AzureSignIn.executable(path: "/usr/bin") { _ in false } == nil)
    }
}
