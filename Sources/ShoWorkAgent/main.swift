import ShoWorkApp

// 11-23：本體在 ShoWorkApp/AgentMain.swift（拆成函式庫給 Orbit42 共用）
MainActor.assumeIsolated { ShoWorkAgentMain.run() }
