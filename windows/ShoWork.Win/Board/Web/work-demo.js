// work.html?demo=1 的示範資料：形狀照 claude -p --output-format stream-json 的實際輸出（假專案、假內容）
window.WORK_DEMO = [
  { type: "session", sid: "demo-0001", cwd: "/Users/demo/github-repos/sample-app", name: "sample-app", model: "claude-sonnet-5-5", permissionMode: "default", state: "busy" },
  { type: "lines", replay: true, lines: [
    { type: "system", subtype: "init", cwd: "/Users/demo/github-repos/sample-app", session_id: "demo-0001", model: "claude-sonnet-5-5", permissionMode: "default", tools: ["Bash", "Read", "Edit", "Write"] },
    { type: "user", _sent: 1762560000, message: { role: "user", content: "登入頁的錯誤訊息改成中文，並且把密碼長度下限改成 8" } },
    { type: "assistant", message: { id: "m1", role: "assistant", content: [{ type: "thinking", thinking: "先找登入頁在哪，再看錯誤訊息跟驗證規則。" }], usage: { input_tokens: 8, cache_creation_input_tokens: 5200, cache_read_input_tokens: 12000 } } },
    { type: "assistant", message: { id: "m1", role: "assistant", content: [{ type: "text", text: "我先找登入頁跟密碼驗證的地方。" }] } },
    { type: "assistant", message: { id: "m1", role: "assistant", content: [{ type: "tool_use", id: "t1", name: "Grep", input: { pattern: "minLength|Invalid password", path: "/Users/demo/github-repos/sample-app/src" } }] } },
    { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "src/auth/login.ts:14:  if (pw.length < 6) return \"Invalid password\";\nsrc/auth/login.ts:21:  return \"Invalid email\";" }] } },
    { type: "assistant", message: { id: "m2", role: "assistant", content: [{ type: "tool_use", id: "t2", name: "Edit", input: {
      file_path: "/Users/demo/github-repos/sample-app/src/auth/login.ts",
      old_string: "export function check(email: string, pw: string) {\n  if (!email.includes(\"@\")) {\n    return \"Invalid email\";\n  }\n  if (pw.length < 6) return \"Invalid password\";\n  return null;\n}",
      new_string: "export function check(email: string, pw: string) {\n  if (!email.includes(\"@\")) {\n    return \"電子郵件格式不對\";\n  }\n  if (pw.length < 8) return \"密碼至少要 8 個字\";\n  return null;\n}" } }],
      usage: { input_tokens: 6, cache_creation_input_tokens: 900, cache_read_input_tokens: 17200 } } },
    { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t2", content: "The file src/auth/login.ts has been updated successfully." }] } },
    { type: "assistant", message: { id: "m3", role: "assistant", content: [{ type: "tool_use", id: "t3", name: "Bash", input: { command: "npm test -- auth", description: "跑登入相關測試" } }] } },
    { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t3", is_error: true, content: "FAIL src/auth/login.test.ts\n  ✕ rejects short password (expected \"Invalid password\", got \"密碼至少要 8 個字\")\nTests: 1 failed, 11 passed" }] } },
    { type: "assistant", message: { id: "m4", role: "assistant", content: [{ type: "text", text: "測試裡還寫著舊的英文訊息，**一起改掉**：`src/auth/login.test.ts`。" }] } },
    { type: "assistant", message: { id: "m4", role: "assistant", content: [{ type: "tool_use", id: "t4", name: "Write", input: { file_path: "/Users/demo/github-repos/sample-app/src/auth/messages.ts", content: "export const MSG = {\n  email: \"電子郵件格式不對\",\n  password: \"密碼至少要 8 個字\",\n};" } }] } },
  ] },
  { type: "permit", req: { id: "p-demo", tool: "Write", summary: "src/auth/messages.ts", detail: "把錯誤訊息集中到一個檔案", alwaysLabel: "Write" } },
];
