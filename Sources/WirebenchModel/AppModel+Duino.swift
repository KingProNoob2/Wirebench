import Foundation
import WirebenchCore
import WirebenchHardware

/// The two PLC families Wirebench can target. Dirigo keeps the legacy D3Net/525-table path; the
/// Duino-S is the MaraProt/MFLW VM.
public enum HardwareFamily: String, CaseIterable, Identifiable, Sendable {
    case dirigo
    case duinoS

    public var id: String { rawValue }
    public var title: String { self == .dirigo ? "Dirigo PLC" : "Maramat Duino-S" }
    public var shortTitle: String { self == .dirigo ? "Dirigo" : "Duino-S" }
}

/// Where a Duino-S is reached. MaraProt speaks the same frames over both.
public enum DuinoTransport: String, CaseIterable, Identifiable, Sendable {
    case usbCDC
    case ethernet

    public var id: String { rawValue }
    public var title: String { self == .usbCDC ? "USB" : "Ethernet" }
}

/// A resolved Duino-S endpoint, Sendable so the watch task can carry it off the main actor.
public struct DuinoLink: Sendable, Equatable {
    public var transport: DuinoTransport
    public var serialPath: String
    public var host: String
    public var port: UInt16

    public func makeTransport() -> MaraProtTransport {
        switch transport {
        case .usbCDC:
            return MaraSerialTransport(path: serialPath)
        case .ethernet:
            return MaraTCPTransport(host: host, port: port)
        }
    }

    public var description: String {
        switch transport {
        case .usbCDC: return serialPath
        case .ethernet: return "\(host):\(port)"
        }
    }
}

public extension AppModel {
    /// The endpoint the next identify/upload/watch action should use, or nil when the fields are incomplete.
    func currentDuinoLink() -> DuinoLink? {
        switch duinoTransport {
        case .usbCDC:
            guard !selectedPortPath.isEmpty else { return nil }
            return DuinoLink(transport: .usbCDC, serialPath: selectedPortPath, host: "", port: 0)
        case .ethernet:
            let host = duinoHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, (1...65_535).contains(duinoTCPPort) else { return nil }
            return DuinoLink(transport: .ethernet, serialPath: "", host: host, port: UInt16(duinoTCPPort))
        }
    }

    var isDuinoLinkConfigured: Bool { currentDuinoLink() != nil }

    /// Opens the selected endpoint, identifies the Duino-S and reads its VM status.
    /// This is also the "test connection" action the communication window needs.
    /// This is also the "test connection" action the communication window needs.
    @discardableResult
    func refreshDuinoInfo() -> MaraProtClient.Info? {
        guard let link = currentDuinoLink() else {
            uploadStatus = duinoTransport == .usbCDC
                ? "No serial port. Plug in the Duino-S and rescan."
                : "Enter the Duino-S IP address and port."
            return nil
        }
        let client = MaraProtClient(transport: link.makeTransport(), stationId: MaraProtClient.pointToPointStation)
        do {
            try client.connect()
            defer { client.close() }
            _ = try client.ping()
            let info = try client.info()
            duinoInfo = info
            duinoVMStatus = try? client.vmStatus()
            uploadStatus = "\(info.modelName) · model 0x\(String(format: "%04X", info.modelId)) · "
                + "firmware \(info.firmwareVersion >> 16).\(info.firmwareVersion & 0xFFFF)"
            logUpload("Duino-S identified: \(info.modelName), model 0x\(String(format: "%04X", info.modelId)), "
                      + "firmware 0x\(String(format: "%08X", info.firmwareVersion)), MTU \(info.maxMtuBytes)",
                      kind: .info)
            return info
        } catch {
            duinoInfo = nil
            duinoVMStatus = nil
            uploadStatus = "Duino-S connection failed: \(error.localizedDescription)"
            logUpload("Duino-S connection failed: \(error)", kind: .error)
            return nil
        }
    }

    /// Compiles the current project to MFLW and uploads it over USB CDC. The VM is started by the
    /// commit command, matching the way the Dirigo uploader starts the PLC after a table write.
    func uploadDuinoProgram(compiled ready: DuinoCompiler.Result? = nil) async {
        guard let project, !project.modules.isEmpty else {
            uploadStatus = "There is no project to compile for the Duino-S."
            uploadPhase = ""
            uploadProgress = nil
            return
        }
        guard let link = currentDuinoLink() else {
            uploadStatus = duinoTransport == .usbCDC
                ? "No serial port. Plug in the Duino-S and rescan."
                : "Enter the Duino-S IP address and port."
            uploadPhase = ""
            uploadProgress = nil
            return
        }

        await MainActor.run {
            self.isUploading = true
            self.uploadLog.removeAll()
            self.uploadPhase = "Compiling for Duino-S…"
            self.uploadProgress = 0
            self.uploadStatus = "Compiling…"
        }
        defer { Task { @MainActor [weak self] in self?.isUploading = false } }

        let compiled: DuinoCompiler.Result
        if let ready {
            compiled = ready
        } else {
            do {
                compiled = try DuinoCompiler.compile(project: project)
            } catch {
                await MainActor.run {
                    self.uploadPhase = "Compile failed"
                    self.uploadStatus = "Duino-S compile failed: \(error.localizedDescription)"
                }
                logUpload("Duino-S compile failed: \(error)", kind: .error)
                return
            }
        }
        await MainActor.run {
            self.uploadPhase = "Image ready · \(compiled.image.count) bytes"
            self.uploadProgress = 0.15
            self.uploadStatus = "Connecting to the Duino-S…"
        }
        logUpload("Duino-S image built: \(compiled.image.count) bytes, \(compiled.slots.count) slots, "
                  + "\(compiled.notes.count) note(s); link \(link.description).", kind: .info)
        for note in compiled.notes { logUpload(note, kind: .info) }

        let client = MaraProtClient(transport: link.makeTransport(), stationId: MaraProtClient.pointToPointStation)
        do {
            try client.connect()
            defer { client.close() }
            _ = try client.ping()
            let info = try client.info()
            guard info.modelId == 0x0407 else {
                throw MaraProtClient.ClientError.uploadRejected("model 0x\(String(format: "%04X", info.modelId)) "
                    + "is not a Maramat Duino-S (0x0407)")
            }
            await MainActor.run {
                self.duinoInfo = info
                self.uploadPhase = "Uploading \(compiled.image.count) bytes…"
                self.uploadProgress = 0.2
                self.uploadStatus = "Uploading to \(info.modelName)…"
            }
            let result = try client.uploadImage(compiled.image, autoStart: true) { fraction in
                Task { @MainActor in
                    self.uploadProgress = 0.2 + 0.8 * fraction
                }
            }
            let status = try? client.vmStatus()
            await MainActor.run {
                self.uploadPhase = "Upload complete · 100%"
                self.uploadProgress = 1
                self.uploadStatus = "Uploaded \(compiled.image.count) bytes in \(result.chunks) chunk(s); VM is running."
                self.duinoInfo = info
                self.duinoVMStatus = status
            }
            logUpload("Duino-S upload complete: \(result.chunks) chunk(s), image CRC 0x\(String(format: "%08X", result.payloadCrc32)).",
                      kind: .stage)
        } catch {
            await MainActor.run {
                self.uploadPhase = "Upload failed"
                self.uploadStatus = "Duino-S upload failed: \(error.localizedDescription)"
            }
            logUpload("Duino-S upload failed: \(error)", kind: .error)
        }
    }
}

public extension AppModel {
    /// Starts a live watch session: compile the current FBD project for its operand→slot table, open the
    /// selected USB CDC port, subscribe to the slots and poll the device. The port stays open only while
    /// watching, like an upload.
    func startDuinoWatch() {
        guard !isWatchingDuino else { return }
        guard !isUploading else {
            duinoWatchStatus = "Wait for the upload to finish before watching."
            return
        }
        guard let project, !project.modules.isEmpty else {
            duinoWatchStatus = "There is no project to watch."
            return
        }
        guard let link = currentDuinoLink() else {
            duinoWatchStatus = duinoTransport == .usbCDC
                ? "No serial port. Plug in the Duino-S and rescan."
                : "Enter the Duino-S IP address and port."
            return
        }
        duinoWatchStatus = "Starting watch…"
        isWatchingDuino = true
        duinoWatchTask?.cancel()
        duinoWatchTask = Task.detached { [weak self] in
            await self?.runDuinoWatch(project: project, link: link)
        }
    }

    func stopDuinoWatch() {
        duinoWatchTask?.cancel()
        duinoWatchTask = nil
        isWatchingDuino = false
        duinoWatchStatus = "Watch stopped."
        duinoWatchValues.removeAll()
        duinoWatchSlotNames.removeAll()
        duinoWatchSlotTypes.removeAll()
    }

    private func runDuinoWatch(project: PCCProject, link: DuinoLink) async {
        let compiled: DuinoCompiler.Result
        do {
            compiled = try DuinoCompiler.compile(project: project)
        } catch {
            await MainActor.run {
                self.isWatchingDuino = false
                self.duinoWatchStatus = "Watch compile failed: \(error.localizedDescription)"
            }
            return
        }

        let allSlots = compiled.slots.keys.sorted().compactMap { name -> (UInt16, String)? in
            guard let slot = compiled.slots[name] else { return nil }
            return (slot, name)
        }
        // The device subscribes at most 512 slots; keep the first 512 in stable name order.
        let selected = Array(allSlots.prefix(512))
        guard !selected.isEmpty else {
            await MainActor.run {
                self.isWatchingDuino = false
                self.duinoWatchStatus = "The compiled image has no watchable slots."
            }
            return
        }
        let slotIDs = selected.map(\.0)
        let client = MaraProtClient(transport: link.makeTransport(),
                                    stationId: MaraProtClient.pointToPointStation)
        do {
            try client.connect()
            defer { client.close() }
            _ = try client.ping()
            let info = try client.info()
            guard info.modelId == 0x0407 else {
                throw MaraProtClient.ClientError.uploadRejected("not a Duino-S")
            }
            let epoch = try client.watchSubscribe(slotIDs)
            // Read every selected slot once so the table starts complete; the watch poll then carries deltas.
            let initial = try client.readSlots(slotIDs)
            var update = try client.watchPoll(ackEpoch: epoch)
            let names = Dictionary(uniqueKeysWithValues: selected.map { ($0.0, $0.1) })
            let types = Dictionary(uniqueKeysWithValues: selected.map { ($0.0, compiled.slotTypes[$0.0] ?? .bool) })
            var values: [UInt16: Double] = [:]
            for (slot, raw) in initial {
                values[slot] = (types[slot] ?? .bool).value(from: raw)
            }
            await MainActor.run {
                self.duinoInfo = info
                self.duinoWatchSlotNames = names
                self.duinoWatchSlotTypes = types
                self.duinoWatchValues = values
                self.duinoWatchStatus = "Watching \(selected.count) slot(s) on \(info.modelName)."
            }
            var ackEpoch = update.epoch == 0 ? epoch : update.epoch
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { break }
                update = try client.watchPoll(ackEpoch: ackEpoch)
                ackEpoch = update.epoch
                var changes: [UInt16: Double] = [:]
                for (slot, raw) in update.changedSlots where types[slot] != nil {
                    changes[slot] = types[slot]!.value(from: raw)
                }
                if !changes.isEmpty {
                    await MainActor.run {
                        for (slot, value) in changes { self.duinoWatchValues[slot] = value }
                    }
                }
            }
            await MainActor.run { self.duinoWatchStatus = "Watch stopped." }
        } catch {
            if !Task.isCancelled {
                await MainActor.run {
                    self.duinoWatchStatus = "Watch failed: \(error.localizedDescription)"
                }
            }
        }
        await MainActor.run {
            self.isWatchingDuino = false
        }
    }
}
