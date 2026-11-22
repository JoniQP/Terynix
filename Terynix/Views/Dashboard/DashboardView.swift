import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var library: VMLibraryStore
    @EnvironmentObject private var isoLibrary: ISOLibrary
    @Environment(\.colorScheme) private var scheme

    @State private var showingWizard = false
    @State private var vmPendingDeletion: VirtualMachine?

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let error = library.loadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if library.virtualMachines.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(library.virtualMachines) { vm in
                            NavigationLink(value: vm.id) {
                                VMCardView(vm: vm)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    vmPendingDeletion = vm
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .background(VPCTheme.background(scheme).ignoresSafeArea())
            .navigationTitle("Virtual PC")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    NavigationLink {
                        MediaLibraryView()
                            .environmentObject(isoLibrary)
                    } label: {
                        Label("Media Library", systemImage: "opticaldiscdrive")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingWizard = true
                    } label: {
                        Label("New Virtual Machine", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingWizard) {
                CreateVMWizardView { newVM in
                    withAnimation { library.add(newVM) }
                }
            }
            .navigationDestination(for: UUID.self) { vmID in
                VMSettingsView(vmID: vmID)
                    .environmentObject(library)
                    .environmentObject(isoLibrary)
            }
            .alert(
                "Delete “\(vmPendingDeletion?.name ?? "")”?",
                isPresented: Binding(
                    get: { vmPendingDeletion != nil },
                    set: { if !$0 { vmPendingDeletion = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { vmPendingDeletion = nil }
                Button("Delete", role: .destructive) {
                    if let vm = vmPendingDeletion {
                        withAnimation { library.delete(vm) }
                    }
                    vmPendingDeletion = nil
                }
            } message: {
                Text("This removes its configuration and virtual hard disk. This can't be undone.")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 52))
                .foregroundStyle(VPCTheme.secondaryText(scheme))
            Text("No Virtual Machines Yet")
                .font(.title2.bold())
                .foregroundStyle(VPCTheme.primaryText(scheme))
            Text("Create your first virtual machine to get started.")
                .foregroundStyle(VPCTheme.secondaryText(scheme))
            Button {
                showingWizard = true
            } label: {
                Label("New Virtual Machine", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

private struct VMCardView: View {
    let vm: VirtualMachine
    @Environment(\.colorScheme) private var scheme

    private var osProfile: GuestOSProfile { GuestOSCatalog.profile(for: vm.osProfileID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(VPCTheme.accent)
                Spacer()
                statusBadge
            }

            Text(vm.name)
                .font(.headline)
                .foregroundStyle(VPCTheme.primaryText(scheme))
                .lineLimit(1)

            Text(osProfile.displayName)
                .font(.subheadline)
                .foregroundStyle(VPCTheme.secondaryText(scheme))

            Divider().opacity(0.5)

            HStack(spacing: 14) {
                Label("\(vm.ramMB) MB", systemImage: "memorychip")
                Label("\(vm.cpuCoreCount) vCPU", systemImage: "cpu")
                Label("\(vm.diskMaxSizeGB) GB", systemImage: "internaldrive")
            }
            .font(.caption)
            .foregroundStyle(VPCTheme.secondaryText(scheme))

            supportTag
        }
        .padding(16)
        .vpcCard()
    }

    private var statusBadge: some View {
        Text(vm.runtimeState.rawValue.capitalized)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(VPCTheme.stateColor(vm.runtimeState).opacity(0.18))
            .foregroundStyle(VPCTheme.stateColor(vm.runtimeState))
            .clipShape(Capsule())
    }

    private var supportTag: some View {
        Text(osProfile.supportLevel.rawValue)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(VPCTheme.supportBadge(osProfile.supportLevel).opacity(0.15))
            .foregroundStyle(VPCTheme.supportBadge(osProfile.supportLevel))
            .clipShape(Capsule())
    }
}
