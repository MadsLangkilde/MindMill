import Testing
@testable import KBCore

struct XcodeSchemesTests {
    let pbx = """
    \t\tA1 /* Contoso */ = {
    \t\t\tisa = PBXNativeTarget;
    \t\t\tname = Contoso;
    \t\t\tproductType = "com.apple.product-type.application";
    \t\t};
    \t\tA2 /* Contoso Staging */ = {
    \t\t\tisa = PBXNativeTarget;
    \t\t\tname = "Contoso Staging";
    \t\t\tproductType = "com.apple.product-type.application";
    \t\t};
    \t\tA3 /* ContosoTests */ = {
    \t\t\tisa = PBXNativeTarget;
    \t\t\tname = ContosoTests;
    \t\t\tproductType = "com.apple.product-type.bundle.unit-test";
    \t\t};
    """

    @Test func picksTheAppNotTheFirstPackage() {
        let apps = XcodeSchemes.appTargets(pbxproj: pbx)
        #expect(apps == ["Contoso", "Contoso Staging"])
        let schemes = ["AsyncBleManager", "DesignSystem", "Contoso", "Contoso Staging", "Networking"]
        #expect(XcodeSchemes.pick(schemes, appTargets: apps, project: "Contoso") == "Contoso")
        #expect(XcodeSchemes.pick(schemes, appTargets: apps, project: nil) == "Contoso")
        #expect(XcodeSchemes.pick(["Lib", "Shop"], appTargets: [], project: "Shop") == "Shop")
    }

    @Test func findsTheFirstError() {
        let xcode = "Build settings…\n/x/App.swift:12:5: error: cannot find 'Foo' in scope\n** BUILD FAILED **"
        #expect(XcodeSchemes.firstError(xcode) == "cannot find 'Foo' in scope")
        let gradle = "FAILURE: Build failed with an exception.\n\n* What went wrong:\nExecution failed for task ':app:compileDebugKotlin'.\n"
        #expect(XcodeSchemes.firstError(gradle) == "Execution failed for task ':app:compileDebugKotlin'.")
        #expect(XcodeSchemes.firstError("$ gradle assembleDebug\nzsh:1: command not found: gradle\n") == "command not found: gradle")
        #expect(XcodeSchemes.firstError("$ ./gradlew x\nzsh:1: no such file or directory: ./gradlew\n") == "no such file or directory: ./gradlew")
        #expect(XcodeSchemes.firstError("all good") == nil)
    }
}
