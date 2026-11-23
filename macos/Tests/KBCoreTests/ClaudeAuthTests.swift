import Foundation
import Testing
@testable import KBCore

@Suite struct ClaudeAuthTests {
    @Test func recognisesSignInFailures() {
        #expect(ClaudeAuth.isSignInProblem("Failed to authenticate. API Error: 403 Attention Required! | Cloudflare"))
        #expect(ClaudeAuth.isSignInProblem("API Error: 401 Invalid API key · Please run /login"))
        #expect(ClaudeAuth.isSignInProblem("OAuth token has expired. Please obtain a new token or refresh your existing token."))
        #expect(ClaudeAuth.isSignInProblem("{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\"}}"))
        #expect(!ClaudeAuth.isSignInProblem("API Error: 529 Overloaded"))
        #expect(!ClaudeAuth.isSignInProblem("The build failed: 3 tests failing"))
    }

    @Test func readsTheSignInLinkThroughHyperlinkEscapes() {
        let link = "https://claude.com/cai/oauth/authorize?code=true&state=abc"
        let osc = "\u{1B}]8;;\(link)\u{07}\(link)\u{1B}]8;;\u{07}"
        let out = "Opening browser to sign in…\nIf the browser didn't open, visit: \(osc)\nPaste code here if prompted > "
        #expect(ClaudeAuth.signInURL(in: out)?.absoluteString == link)
        #expect(ClaudeAuth.signInURL(in: "Opening browser to sign in…\n") == nil)
        #expect(ClaudeAuth.plainText("\u{1B}[32mLogin successful.\u{1B}[0m") == "Login successful.")
        #expect(ClaudeAuth.succeeded("Paste code here if prompted > Login successful.\n"))
    }

    @Test func decodesStatus() {
        let s = ClaudeAuth.Status.decode("""
        {"loggedIn": true, "authMethod": "claude.ai", "email": "a@b.dk", "orgName": "Org", "loginExpiresAt": "2026-12-11T23:35:03.528Z"}
        """)
        #expect(s?.loggedIn == true)
        #expect(s?.account == "a@b.dk (Org)")
        #expect(ClaudeAuth.Status.decode("{\"loggedIn\": false}")?.loggedIn == false)
        #expect(ClaudeAuth.Status.decode("not json") == nil)
    }

    @Test func shortReasonIsTheFirstLine() {
        #expect(ClaudeAuth.shortReason("Failed to authenticate. API Error: 403\n<html>…") == "Failed to authenticate. API Error: 403")
    }
}
