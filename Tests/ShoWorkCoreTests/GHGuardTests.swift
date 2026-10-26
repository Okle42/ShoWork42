import Foundation
import Testing
@testable import ShoWorkCore

@Suite("動作預告：GitHub 公開發言（gh）")
struct GHGuardTests {
    func names(_ c: String) -> [String] { CaptainLink.match(c, rules: CaptainLink.defaultRules).map { ($0.block ? "擋:" : "告:") + $0.name } }
    let gh = "擋:" + GHGuard.ruleName
    var rule: CaptainLink.Rule { CaptainLink.defaultRules.first { $0.name == GHGuard.ruleName }! }

    // 假 git：/w/own＝Okle42 私有、/w/pub＝Okle42 公開、/w/other＝別人的、/w/fork＝origin 是 Okle42、upstream 是別人
    let git: PushGuard.Git = { dir, _ in
        switch dir {
        case "/w/own": (0, "origin\tgit@github.com:Okle42/專案A.git (fetch)\norigin\tgit@github.com:Okle42/專案A.git (push)\n")
        case "/w/pub": (0, "origin\thttps://github.com/Okle42/公開工具.git (fetch)\n")
        case "/w/other": (0, "origin\thttps://github.com/acme/widget.git (fetch)\n")
        case "/w/fork": (0, "origin\thttps://github.com/Okle42/widget.git (fetch)\nupstream\thttps://github.com/acme/widget.git (fetch)\n")
        default: (128, "")
        }
    }
    func view(_ r: String) -> (owner: String, isPrivate: Bool)? {
        switch r.lowercased() {
        case "okle42/專案a", "okle42/私有b": ("Okle42", true)
        case "okle42/公開工具", "okle42/widget": ("Okle42", false)
        case "acme/widget": ("acme", false)
        default: nil
        }
    }
    func why(_ c: String, cwd: String = "/w/own") -> String? { GHGuard.blockReason(c, cwd: cwd, rule: rule, git: git, view: view) }

    @Test("正樣本：粗篩抓得到")
    func positives() {
        for c in ["gh issue comment 5 --body '謝謝'", "gh issue create -t 標題 -b 內容", "gh pr create --fill",
                  "gh pr comment 12 -b 'LGTM'", "gh pr review 12 --approve", "gh release create v1.0 dist/a.zip",
                  "/opt/homebrew/bin/gh pr create --title x", "gh -R acme/widget issue comment 3 -b hi",
                  "gh api repos/acme/widget/issues/3/comments -f body=hi", "gh api -X POST repos/acme/widget/issues",
                  "gh api --method=PATCH repos/acme/widget/issues/3", "gh api -XDELETE repos/acme/widget/issues/comments/9",
                  "cd ~/專案A && gh pr create --fill", "git push && gh pr create --fill"] {
            #expect(names(c) == [gh], "\(c)")
        }
    }

    @Test("負樣本：讀取、引號裡的字、別的指令不抓")
    func negatives() {
        for c in ["gh issue list", "gh pr view 12 --json title", "gh pr checks", "gh repo view --json isPrivate,owner",
                  "gh api repos/acme/widget/issues", "gh api user", "gh release list", "gh run watch",
                  "echo 'gh pr create --fill'", "git commit -m 'gh issue comment 修好了'", "grep -n \"gh pr create\" README.md"] {
            #expect(names(c).isEmpty, "\(c)")
        }
    }

    @Test("細判：Okle42 私有 repo 免擋；公開、別人的、判不出來照擋")
    func exempt() {
        #expect(why("gh pr create --fill") == nil)                                        // 資料夾是 Okle42 私有
        #expect(why("gh issue comment 5 -b hi -R Okle42/私有b", cwd: "/w/other") == nil)   // -R 指定
        #expect(why("gh api repos/Okle42/私有b/issues -f title=x", cwd: "/w/other") == nil)
        #expect(why("gh api repos/{owner}/{repo}/issues -f title=x") == nil)
        #expect(why("gh issue comment https://github.com/Okle42/私有b/issues/3 -b hi", cwd: "/w/other") == nil)
        #expect(why("cd /w/own && gh pr create --fill", cwd: "/w/other") == nil)          // 跟著 cd
        #expect(why("gh api graphql -f query=x") == nil)                                  // 不是 repos/（隊長範圍只算 repos/）

        #expect(why("gh pr create --fill", cwd: "/w/pub")?.contains("Okle42/公開工具") == true)   // 自己的但公開
        #expect(why("gh pr create --fill", cwd: "/w/other")?.contains("acme/widget") == true)
        #expect(why("gh pr create --fill", cwd: "/w/fork")?.contains("acme/widget") == true)     // fork：上游也要算
        #expect(why("gh issue comment 5 -b hi -R acme/widget") != nil)
        #expect(why("gh api -X POST repos/acme/widget/issues") != nil)
        #expect(why("gh pr create --fill", cwd: "/w/nogit") != nil)                        // 不是 git 資料夾
        #expect(why("gh issue comment 5 -b hi -R Okle42/不存在") != nil)                    // gh 查不到
        #expect(why("gh api repos/$O/$R/issues -f t=x") != nil)                            // 變數
        #expect(why("cd /w/other && gh pr create --fill") != nil)
        #expect(why("gh pr create --fill -R Okle42/私有b; gh pr create --fill -R acme/widget") != nil)   // 兩段有一段不行就擋
    }
}
