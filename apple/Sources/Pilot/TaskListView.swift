import AppKit
import SwiftUI

struct TaskListView: View {
    @Bindable var workspace: Workspace
    let onDismiss: () -> Void
    @FocusState private var focusedTaskID: UUID?
    @State private var newTaskTitle: String = ""
    @FocusState private var isNewTaskFieldFocused: Bool
    @State private var keyMonitor: Any?
    @State private var showCopiedToast = false
    @State private var toastDismissWorkItem: DispatchWorkItem?

    private func dismiss() { onDismiss() }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                taskList
                Divider()
                footer
            }

            if showCopiedToast {
                CopiedTaskToast()
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 360, idealHeight: 520)
        .onAppear {
            isNewTaskFieldFocused = true
            installToggleKeyMonitor()
        }
        .onDisappear { removeToggleKeyMonitor() }
    }

    /// Catch ⇧⌘T at the NSEvent level so it fires even when a TextField
    /// has focus — a `.keyboardShortcut` button is unreliable in that
    /// case because the field editor swallows the keys.
    private func installToggleKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let requiredFlags: NSEvent.ModifierFlags = [.command, .shift]
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == requiredFlags,
                  event.charactersIgnoringModifiers?.lowercased() == "t" else {
                return event
            }
            dismiss()
            return nil
        }
    }

    private func removeToggleKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private var header: some View {
        HStack {
            Label("Tasks", systemImage: "checklist")
                .font(.headline)
            Spacer()
            Text(progressText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var taskList: some View {
        let tasks = workspace.sortedTasks
        return List {
            ForEach(tasks) { task in
                taskRow(task)
                    .listRowSeparator(.hidden)
            }
            .onMove { source, destination in
                workspace.moveTasks(from: source, to: destination)
            }
            .onDelete { indexSet in
                for index in indexSet {
                    workspace.removeTask(tasks[index])
                }
            }

            addTaskRow
                .listRowSeparator(.hidden)
        }
        .listStyle(.inset)
    }

    private func taskRow(_ task: WorkspaceTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                withAnimation(.snappy) {
                    workspace.toggleTaskCompletion(task)
                }
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? Color.accentColor : .secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)

            if focusedTaskID == task.id {
                TextField("Task", text: Bindable(task).title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...10)
                    .focused($focusedTaskID, equals: task.id)
                    .onSubmit { focusedTaskID = nil }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(task.title)
                    .strikethrough(task.isCompleted, color: .secondary)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { focusedTaskID = task.id }
                    .onTapGesture(count: 1) { copyTaskToClipboard(task) }
            }
        }
        .padding(.vertical, 4)
    }

    /// Inline row at the bottom of the list — tap to start typing a new
    /// task, paste a multi-line list to split it into individual tasks.
    private var addTaskRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.tertiary)
                .imageScale(.large)

            TextField("Add a task or paste a list…",
                      text: $newTaskTitle,
                      axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...20)
                .focused($isNewTaskFieldFocused)
                .onSubmit(commitNewTask)
                .onChange(of: newTaskTitle) { _, newValue in
                    if newValue.contains(where: \.isNewline) {
                        addTasksFromMultiline(newValue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { isNewTaskFieldFocused = true }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            Button("Clear Completed") {
                withAnimation(.snappy) {
                    workspace.clearCompletedTasks()
                }
            }
            .disabled(!hasCompletedTasks)

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var hasCompletedTasks: Bool {
        workspace.tasks.contains(where: \.isCompleted)
    }

    private var progressText: String {
        let total = workspace.tasks.count
        let done = workspace.tasks.filter(\.isCompleted).count
        return total == 0 ? "" : "\(done) of \(total) complete"
    }

    private func commitNewTask() {
        let trimmed = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.contains(where: \.isNewline) {
            addTasksFromMultiline(newTaskTitle)
        } else {
            workspace.addTask(title: trimmed)
            newTaskTitle = ""
            isNewTaskFieldFocused = true
        }
    }

    private func addTasksFromMultiline(_ text: String) {
        let titles = text
            .split(whereSeparator: \.isNewline)
            .map { TaskListView.stripListMarker(String($0)) }
            .filter { !$0.isEmpty }

        guard !titles.isEmpty else {
            newTaskTitle = ""
            return
        }

        for title in titles {
            workspace.addTask(title: title)
        }
        newTaskTitle = ""
        isNewTaskFieldFocused = true
    }

    private func copyTaskToClipboard(_ task: WorkspaceTask) {
        let trimmed = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        flashCopiedToast()
    }

    private func flashCopiedToast() {
        toastDismissWorkItem?.cancel()
        withAnimation(.snappy(duration: 0.18)) {
            showCopiedToast = true
        }
        let work = DispatchWorkItem {
            withAnimation(.snappy(duration: 0.3)) {
                showCopiedToast = false
            }
        }
        toastDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Strip common list-item prefixes (bullets, numbered markers, checkboxes)
    /// so a pasted line like "- Finish the pitch deck" becomes
    /// "Finish the pitch deck".
    static func stripListMarker(_ line: String) -> String {
        let pattern = #"^\s*(?:[-*•–—]|\[[ xX]\]|\d+[.)])\s+"#
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return trimmed }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let stripped = regex.stringByReplacingMatches(
            in: trimmed,
            range: range,
            withTemplate: ""
        )
        return stripped.trimmingCharacters(in: .whitespaces)
    }
}

private struct CopiedTaskToast: View {
    var body: some View {
        Label("Task Copied", systemImage: "checkmark.circle.fill")
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

/// Click-outside-to-dismiss wrapper around `TaskListView`. The macOS
/// system `.sheet` blocks outside clicks entirely, so we render the
/// panel as a custom overlay with a transparent backdrop that catches
/// taps and dismisses.
struct TaskListOverlay: View {
    @Bindable var workspace: Workspace
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            TaskListView(workspace: workspace, onDismiss: onDismiss)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
                .padding(40)
                .frame(maxWidth: 560, maxHeight: 640)
        }
    }
}
