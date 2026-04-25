import SwiftUI

struct SimulatorDevicePicker: View {
    @Bindable var state: SimulatorState
    @Binding var isPresented: Bool

    @State private var deviceTypes: [SimulatorDeviceTypeInfo] = []
    @State private var runtimes: [SimulatorRuntimeInfo] = []
    @State private var selectedDeviceType: SimulatorDeviceTypeInfo?
    @State private var selectedRuntime: SimulatorRuntimeInfo?
    @State private var error: SimulatorError?
    @State private var isLoading: Bool = true
    @State private var isCreating: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack {
            Text("New Simulator Pane")
                .font(.title3.weight(.semibold))
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            loadingView
        } else if let error {
            errorView(error)
        } else if runtimes.isEmpty {
            emptyRuntimesView
        } else {
            pickerBody
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Reading installed iOS runtimes…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pickerBody: some View {
        HStack(spacing: 0) {
            deviceTypeColumn
                .frame(maxWidth: 280)
            Divider()
            runtimeColumn
        }
    }

    private var deviceTypeColumn: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(deviceTypes) { type in
                    pickerRow(
                        title: type.displayName,
                        trailing: nil,
                        isSelected: selectedDeviceType?.identifier == type.identifier,
                        isEnabled: true
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selectedDeviceType = type }
                }
            }
        }
    }

    private var runtimeColumn: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(runtimes) { runtime in
                    pickerRow(
                        title: runtime.displayName,
                        trailing: runtime.isAvailable ? nil : "not installed",
                        isSelected: selectedRuntime?.identifier == runtime.identifier,
                        isEnabled: runtime.isAvailable
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { if runtime.isAvailable { selectedRuntime = runtime } }
                }
            }
        }
    }

    private func pickerRow(
        title: String,
        trailing: String?,
        isSelected: Bool,
        isEnabled: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 6)
        )
        .foregroundStyle(isSelected ? Color.white : Color.primary)
    }

    private var emptyRuntimesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No iOS runtimes installed")
                .font(.headline)
            Text("Open Xcode → Settings → Platforms to install an iOS runtime, then try again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: SimulatorError) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Can't set up a simulator")
                .font(.headline)
            Text(error.localizedDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if isCreating {
                ProgressView().controlSize(.small)
                Text("Creating…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Create") {
                Task { await commit() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(
                isCreating ||
                selectedDeviceType == nil ||
                selectedRuntime == nil ||
                selectedRuntime?.isAvailable == false
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func load() {
        isLoading = true
        // Run simctl off the main thread — each call spawns a Process and waits.
        Task.detached(priority: .userInitiated) {
            let foundTypes = SimctlList.iPhoneAndIPadDeviceTypes()
            let foundRuntimes = SimctlList.iOSRuntimes()
            await MainActor.run {
                self.deviceTypes = foundTypes
                self.runtimes = foundRuntimes
                self.selectedDeviceType = foundTypes.first
                self.selectedRuntime = foundRuntimes.first(where: { $0.isAvailable })
                    ?? foundRuntimes.first
                self.isLoading = false
            }
        }
    }

    private func commit() async {
        guard let deviceType = selectedDeviceType,
              let runtime = selectedRuntime else { return }
        isCreating = true
        defer { isCreating = false }

        do {
            let udid = try await SimulatorRuntime.shared.createDeviceOffMainThread(
                typeIdentifier: deviceType.identifier,
                runtimeIdentifier: runtime.identifier,
                name: deviceType.displayName
            )
            state.deviceUDID = udid
            state.deviceTypeIdentifier = deviceType.identifier
            state.runtimeIdentifier = runtime.identifier
            state.displayName = deviceType.displayName
            isPresented = false
        } catch let simError as SimulatorError {
            error = simError
        } catch {
            self.error = .deviceCreateFailed(underlying: error.localizedDescription)
        }
    }
}
