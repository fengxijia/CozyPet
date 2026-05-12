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

    @Test("today done key has YYYY-MM-DD shape")
    func todayDoneKeyShape() {
        let key = AppPaths.todayDoneKey()
        #expect(key.hasPrefix("workflow.done."))
        #expect(key.dropFirst("workflow.done.".count).count == 10)
    }
}
