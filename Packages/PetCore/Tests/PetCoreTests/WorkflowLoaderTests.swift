import Testing
@testable import PetCore

@Suite("WorkflowLoader")
struct WorkflowLoaderTests {
    @Test("decodes a small inline YAML workflow")
    func loadsSampleWorkflow() throws {
        let yaml = """
        name: "Morning Routine"
        steps:
          - id: notion-todo
            say: "打开 Notion"
            open_url: "notion://www.notion.so/x"
          - id: emnlp
            say: "看实验"
            open_app: "com.googlecode.iterm2"
          - id: get-out
            say: "去散步"
            kind: prompt
        """
        let wf = try WorkflowLoader().loadFromString(yaml)
        #expect(wf.name == "Morning Routine")
        #expect(wf.steps.count == 3)
        #expect(wf.steps[0].resolvedKind == .url)
        #expect(wf.steps[1].resolvedKind == .app)
        #expect(wf.steps[2].resolvedKind == .prompt)
    }

    @Test("decodes a step with multiple actions")
    func loadsMultiActionStep() throws {
        let yaml = """
        name: "Multi"
        steps:
          - id: morning-combo
            say: "开工组合拳"
            actions:
              - kind: app
                open_app: "com.microsoft.VSCode"
                open_path: "/Users/xixi/Code/pet"
              - kind: url
                open_url: "https://notion.so/x"
              - kind: path
                open_path: "/tmp"
        """
        let wf = try WorkflowLoader().loadFromString(yaml)
        #expect(wf.steps.count == 1)
        let step = wf.steps[0]
        #expect(step.resolvedActions.count == 3)
        #expect(step.resolvedActions[0].kind == .app)
        #expect(step.resolvedActions[0].openApp == "com.microsoft.VSCode")
        #expect(step.resolvedActions[0].openPath == "/Users/xixi/Code/pet")
        #expect(step.resolvedActions[1].kind == .url)
        #expect(step.resolvedActions[1].openURL == "https://notion.so/x")
        #expect(step.resolvedActions[2].kind == .path)
        #expect(step.resolvedActions[2].openPath == "/tmp")
    }

    @Test("legacy single-action step still maps to a single resolvedAction")
    func legacySingleActionFallback() throws {
        let yaml = """
        name: "Legacy"
        steps:
          - id: open-iterm
            say: "终端"
            open_app: "com.googlecode.iterm2"
            open_path: "/Users/xixi/Code"
          - id: notes
            say: "随便念"
            kind: prompt
        """
        let wf = try WorkflowLoader().loadFromString(yaml)
        #expect(wf.steps[0].resolvedActions.count == 1)
        #expect(wf.steps[0].resolvedActions[0].kind == .app)
        #expect(wf.steps[0].resolvedActions[0].openApp == "com.googlecode.iterm2")
        #expect(wf.steps[0].resolvedActions[0].openPath == "/Users/xixi/Code")
        // 纯提醒：没有动作
        #expect(wf.steps[1].resolvedActions.isEmpty)
    }

    @Test("today done key has YYYY-MM-DD shape")
    func todayDoneKeyShape() {
        let key = AppPaths.todayDoneKey()
        #expect(key.hasPrefix("workflow.done."))
        #expect(key.dropFirst("workflow.done.".count).count == 10)
    }
}
