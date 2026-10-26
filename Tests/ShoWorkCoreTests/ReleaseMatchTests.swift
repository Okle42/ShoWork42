import Foundation
import Testing
@testable import ShoWorkCore

// T1025044431：放行後一字不差重跑又被擋（10-24 Tina BKDDE → B6Q44）。
// 根因不是 cwd：第一次那條前面多一行 showork card（開工卡），重跑時沒有 ⇒ 整條指令的指紋不同。假路徑、假專案（10-22 規矩）
@Suite("放行比對：只看命中擋下規則的那幾段")
struct ReleaseMatchTests {
    let rules = CaptainLink.defaultRules
    let first = #""/Users/demo/Library/Application Support/ShoWork42/bin/showork" card --kind start --doing "部署 函式A" --summary "部署" --how "firebase deploy --only functions:funcA" --touch "函式A" --outward "部署""#
        + "\ncd /Users/demo/專案A/cloud && firebase deploy --only functions:funcA 2>&1 | tail -6"
    let retry = "cd /Users/demo/專案A/cloud && firebase deploy --only functions:funcA 2>&1 | tail -6"

    @Test("Tina 的情況：前面多一行開工卡、後面接 tail 不同，都算同一個指令")
    func sameCommand() {
        #expect(CaptainLink.blockFingerprint(first, rules: rules) == CaptainLink.blockFingerprint(retry, rules: rules))
        #expect(CaptainLink.blockFingerprint(retry, rules: rules) == CaptainLink.blockFingerprint("cd /Users/demo/專案A/cloud && firebase deploy --only functions:funcA 2>&1 | tail -20", rules: rules))
        #expect(CaptainLink.blockFingerprint(retry, rules: rules) == CaptainLink.blockFingerprint("firebase deploy --only functions:funcA 2>&1", rules: rules))
    }

    @Test("真的不同的動作不能共用放行")
    func differentCommand() {
        let a = CaptainLink.blockFingerprint(retry, rules: rules)
        #expect(a != CaptainLink.blockFingerprint("cd /Users/demo/專案A/cloud && firebase deploy --only functions:funcB", rules: rules))
        #expect(a != CaptainLink.blockFingerprint("firebase deploy", rules: rules))
        #expect(a != CaptainLink.blockFingerprint(retry + " && rm -rf ~/專案A", rules: rules))      // 多擋一樣東西
        #expect(CaptainLink.blockFingerprint("rm -rf build", rules: rules) != CaptainLink.blockFingerprint("rm -rf src", rules: rules))
    }

}
