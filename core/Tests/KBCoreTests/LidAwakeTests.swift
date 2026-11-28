import Foundation
import Testing
@testable import KBCore

@Suite struct LidAwakeTests {
    @Test func scriptNamesTheFlagAndItsVersionAndOnlyUndoesItsOwnChange() {
        let s = LidAwake.script(flag: "/Users/a b/Library/Application Support/KB/stay-awake")
        #expect(s.hasPrefix("#!/bin/sh\n"))
        #expect(s.contains("flag='/Users/a b/Library/Application Support/KB/stay-awake'"))
        #expect(LidAwake.installedVersion(scriptText: s) == LidAwake.version)
        #expect(s.contains("pgrep -xq Mindmill"))
        #expect(s.contains("AC Power"))
        // It turns sleep back on only when its own mark says it turned it off, and sleeps a closed Mac then.
        #expect(s.contains("elif [ -f \"$mark\" ]; then\n    /usr/bin/pmset -a disablesleep 0"))
        #expect(s.contains("pmset sleepnow"))
    }

    @Test func versionIsNilWithoutAScriptAndZeroForAnUnknownOne() {
        #expect(LidAwake.installedVersion(scriptText: nil) == nil)
        #expect(LidAwake.installedVersion(scriptText: "#!/bin/sh\necho hi\n") == 0)
    }

    @Test func quotingSurvivesQuotesAndBackslashes() {
        #expect(LidAwake.shellQuoted("it's") == "'it'\\''s'")
        #expect(LidAwake.appleScriptString(#"say "hi" \ there"#) == #""say \"hi\" \\ there""#)
        let a = LidAwake.privileged("echo 'x'", prompt: "Why")
        #expect(a == #"do shell script "echo 'x'" with prompt "Why" with administrator privileges"#)
    }

    @Test func daemonRunsTheScriptEveryFewSeconds() throws {
        let plist = try #require(try PropertyListSerialization.propertyList(from: LidAwake.plist(), format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == LidAwake.label)
        #expect(plist["ProgramArguments"] as? [String] == ["/bin/sh", LidAwake.scriptPath])
        #expect(plist["StartInterval"] as? Int == 10)
        #expect(plist["RunAtLoad"] as? Bool == true)
    }

    @Test func installAndRemoveTouchOnlyTheHelpersFiles() {
        let install = LidAwake.installCommand(script: "/tmp/x/stayawake.sh", plist: "/tmp/x/stayawake.plist")
        #expect(install.contains("-m 755 '/tmp/x/stayawake.sh' '\(LidAwake.scriptPath)'"))
        #expect(install.contains("-m 644 '/tmp/x/stayawake.plist' '\(LidAwake.plistPath)'"))
        #expect(install.contains("launchctl bootstrap system"))
        let remove = LidAwake.uninstallCommand
        #expect(remove.contains("launchctl bootout system/\(LidAwake.label)"))
        #expect(remove.contains("then /usr/bin/pmset -a disablesleep 0; fi"))
        #expect(remove.contains("'/Library/Application Support/\(LidAwake.label)'"))
    }

    #if os(macOS)
    @Test func generatedShellParses() throws {
        for text in [LidAwake.script(flag: "/tmp/it's here/stay-awake"), LidAwake.installCommand(script: "/a", plist: "/b"),
                     LidAwake.uninstallCommand] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-n"]
            let input = Pipe()
            p.standardInput = input
            try p.run()
            input.fileHandleForWriting.write(Data(text.utf8))
            try input.fileHandleForWriting.close()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "sh -n failed for:\n\(text)")
        }
    }
    #endif
}
