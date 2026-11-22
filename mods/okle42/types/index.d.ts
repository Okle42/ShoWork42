export type Okle42MarkdownArgs<Surface> = {
  surface: Surface
  text: string
  columns: number
}

export type Okle42<Surface, Drawing> = {
  markdown: (args: Okle42MarkdownArgs<Surface>) => Promise<Drawing | undefined>
}

declare module 'claude-code' {
  interface EngineInterface {
    okle42: Okle42<RenderSurface, RenderElement>
  }
  interface PluginState {
    okle42: {
      formulas: Record<string, unknown>
      dir: string
      unfolded: string[]
      sent: { text: string; at: number }[]
      turnEnds: { durationMs: number; at: number }[]
      setupAt: number
      setupFocus: string
      setupLand: string
      foundPaths: string[]
      awaiting: { key: string; at: number }[]
      blink: boolean
      drawn: StateFamily<number>
    }
  }
}
