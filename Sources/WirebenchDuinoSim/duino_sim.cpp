//  duino_sim.cpp
//  Wirebench
//
//  A software Duino-S: the portable MaraVM from the firmware, a MaraProt v1 server over TCP on the
//  Duino-S port, and a HAL backed by virtual I/O. The protocol follows Duino-S_FW/MARAPROT.md:
//  the frame is `4D 50 10 ST SEQlo SEQhi OP STATUS LENlo LENhi payload CRC16lo CRC16hi` with
//  CRC-16-CCITT (poly 0x1021, init 0xFFFF) over header+payload, point-to-point transports accept
//  any station id, and the upload commit answers the image header's payload CRC (from byte 12).

#include "WirebenchDuinoSim.h"
#include "mara_vm.h"

#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <map>
#include <mutex>
#include <netinet/in.h>
#include <random>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

// MARK: - The simulator

struct DuinoSimState {
    VmInstance_t *vm = nullptr;
    VmHalVtable_t hal{};
    int listenFd = -1;
    uint16_t port = 0;
    std::atomic<bool> stop{false};
    std::thread acceptThread;
    std::thread scanThread;
    mutable std::mutex vmMutex;       // every VM call and the watch state
    mutable std::mutex ioMutex;       // the virtual I/O maps and the retentive store
    std::string error;

    // Virtual I/O and HAL backing stores.
    std::map<uint32_t, uint8_t> di, doChannels;
    std::map<uint32_t, int32_t> ai, aoChannels;
    std::map<uint32_t, float> pwmChannels;
    std::map<uint16_t, uint64_t> retentive;
    bool rtcOverridden = false;
    int64_t rtcOverrideValue = 0;

    /// The shield's sensors: what TMP75 and the 1-Wire DS18B20 report, host-set like the real
    /// ambient. Defaults are the firmware's simulated values.
    float tmp75Celsius = 25.0f;
    float ds18b20Celsius = 22.5f;
    /// A DS18B20 on the 1-Wire bus (none attached by default, like a bare board).
    bool hasOnewireSensor = false;
    uint8_t onewireRom[8] = {0};

    /// The BL24C256A EEPROM backing the retentive store: a 32 KiB image, optionally persisted to
    /// a file so "power cycles" keep the values, as they would on the board.
    std::vector<uint8_t> eeprom;
    std::string eepromPath;

    /// The shield's CH455G display, decoded from the VM's last update (numeric or raw segments).
    struct {
        bool valid = false;
        bool enabled = false;
        bool raw = false;
        uint8_t digitMask = 0;
        int brightness = 0;
        float value = 0;
        int decimals = 0;
        uint8_t segments[4] = {0, 0, 0, 0};
    } display;

    // Upload session (VM_UPLOAD_BEGIN → CHUNK* → COMMIT).
    bool uploadOpen = false;
    uint32_t uploadExpectedBytes = 0;
    uint32_t uploadExpectedCrc = 0;
    std::vector<uint8_t> uploadBuffer;

    // Watch: a device-global subscription list and epoch, per-connection last-emitted state.
    std::vector<uint16_t> watchSlots;
    uint16_t watchEpoch = 0;
    std::map<uint16_t, std::vector<uint8_t>> watchSnapshot;

    std::chrono::steady_clock::time_point bootTime;
    std::atomic<bool> powered{true};
    bool resumeAfterPowerCycle = false;
    mutable std::mutex connectionsMutex;
    std::vector<int> connectionFds;
    /// Joined on destroy. Accept-loop threads are detached only after being recorded here, so the
    /// state cannot be deleted while a client is still using it.
    std::vector<std::thread> connectionThreads;
};


namespace {

constexpr uint8_t kFrameVersion = 0x10;
constexpr uint8_t kFlagResponse = 0x01;
constexpr uint8_t kFlagError    = 0x02;
constexpr uint16_t kMaxPayload  = 520;
constexpr uint16_t kMaxChunk    = kMaxPayload - 4;
constexpr uint32_t kFirmwareVersion = 0x00010000;
constexpr uint32_t kScanPeriodMs = 10;

// MARK: - Checksums (MARAPROT.md §1)

uint16_t crc16Ccitt(const uint8_t *data, size_t length) {
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < length; ++i) {
        crc ^= static_cast<uint16_t>(data[i]) << 8;
        for (int bit = 0; bit < 8; ++bit) {
            crc = (crc & 0x8000) ? static_cast<uint16_t>((crc << 1) ^ 0x1021)
                                 : static_cast<uint16_t>(crc << 1);
        }
    }
    return crc;
}

uint32_t crc32Ieee(const uint8_t *data, size_t length) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (int bit = 0; bit < 8; ++bit) {
            crc = (crc & 1) ? (crc >> 1) ^ 0xEDB88320u : crc >> 1;
        }
    }
    return ~crc;
}

// MARK: - Little-endian helpers

uint16_t readU16(const uint8_t *p) { return static_cast<uint16_t>(p[0] | (p[1] << 8)); }
uint32_t readU32(const uint8_t *p) {
    return static_cast<uint32_t>(p[0] | (p[1] << 8) | (p[2] << 16)) | (static_cast<uint32_t>(p[3]) << 24);
}
uint64_t readU64(const uint8_t *p) {
    uint64_t value = 0;
    for (int i = 0; i < 8; ++i) value |= static_cast<uint64_t>(p[i]) << (i * 8);
    return value;
}
void appendU16(std::vector<uint8_t> &out, uint16_t value) {
    out.push_back(static_cast<uint8_t>(value));
    out.push_back(static_cast<uint8_t>(value >> 8));
}
void appendU32(std::vector<uint8_t> &out, uint32_t value) {
    for (int i = 0; i < 4; ++i) out.push_back(static_cast<uint8_t>(value >> (i * 8)));
}
void appendU64(std::vector<uint8_t> &out, uint64_t value) {
    for (int i = 0; i < 8; ++i) out.push_back(static_cast<uint8_t>(value >> (i * 8)));
}

// The HAL carries no user-data pointer, so callbacks resolve the instance through thread-local
// storage: the scan thread sets it before stepping, and protocol threads set it around VM calls.
thread_local DuinoSimState *tlsSim = nullptr;

// MARK: - Retentive store (BL24C256A EEPROM)
/// Loads the EEPROM image from `path` when one is configured; a missing file starts blank,
/// as a fresh BL24C256A would.
void eepromLoad(DuinoSimState *state) {
    if (state->eepromPath.empty()) return;
    state->eeprom.assign(32768, 0xFF);
    FILE *file = std::fopen(state->eepromPath.c_str(), "rb");
    if (file != nullptr) {
        const size_t read = std::fread(state->eeprom.data(), 1, state->eeprom.size(), file);
        (void)read;
        std::fclose(file);
    }
}

void eepromSave(const DuinoSimState *state) {
    if (state->eepromPath.empty()) return;
    FILE *file = std::fopen(state->eepromPath.c_str(), "wb");
    if (file == nullptr) return;
    std::fwrite(state->eeprom.data(), 1, state->eeprom.size(), file);
    std::fclose(file);
}

uint64_t retentiveRead(DuinoSimState *state, uint16_t paramId) {
    std::lock_guard<std::mutex> lock(state->ioMutex);
    if (!state->eeprom.empty()) {
        const size_t address = static_cast<size_t>(paramId) * 8;
        if (address + 8 <= state->eeprom.size()) return readU64(&state->eeprom[address]);
        return 0;
    }
    const auto it = state->retentive.find(paramId);
    return it == state->retentive.end() ? 0 : it->second;
}

void retentiveWrite(DuinoSimState *state, uint16_t paramId, uint64_t rawBits) {
    std::lock_guard<std::mutex> lock(state->ioMutex);
    if (!state->eeprom.empty()) {
        const size_t address = static_cast<size_t>(paramId) * 8;
        if (address + 8 <= state->eeprom.size()) {
            for (int i = 0; i < 8; ++i) state->eeprom[address + i] = static_cast<uint8_t>(rawBits >> (i * 8));
            eepromSave(state);
        }
        return;
    }
    state->retentive[paramId] = rawBits;
}


// MARK: - HAL implementation

uint8_t halDiRead(uint16_t channel) {
    std::lock_guard<std::mutex> lock(tlsSim->ioMutex);
    const auto it = tlsSim->di.find(channel);
    return it == tlsSim->di.end() ? 0 : it->second;
}

void halDoWrite(uint16_t channel, uint8_t value) {
    std::lock_guard<std::mutex> lock(tlsSim->ioMutex);
    tlsSim->doChannels[channel] = value;
}

int32_t halAiRead(uint16_t channel) {
    std::lock_guard<std::mutex> lock(tlsSim->ioMutex);
    const auto it = tlsSim->ai.find(channel);
    return it == tlsSim->ai.end() ? 0 : it->second;
}

void halAoWrite(uint16_t channel, int32_t value) {
    std::lock_guard<std::mutex> lock(tlsSim->ioMutex);
    tlsSim->aoChannels[channel] = value;
}

uint8_t halPwmSet(uint16_t channel, int32_t, float dutyPct) {
    std::lock_guard<std::mutex> lock(tlsSim->ioMutex);
    tlsSim->pwmChannels[channel] = dutyPct;
    return 1;
}

uint32_t halTimeMicros() {
    const auto now = std::chrono::steady_clock::now().time_since_epoch();
    return static_cast<uint32_t>(std::chrono::duration_cast<std::chrono::microseconds>(now).count());
}

int64_t halRtcUnixSec() {
    std::lock_guard<std::mutex> lock(tlsSim->ioMutex);
    if (tlsSim->rtcOverridden) return tlsSim->rtcOverrideValue;
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    return std::chrono::duration_cast<std::chrono::seconds>(now).count();
}

uint32_t halRngNext() {
    static thread_local std::mt19937 generator{std::random_device{}()};
    return generator();
}

void halRetentiveWrite(uint16_t paramId, uint64_t rawBits) {
    retentiveWrite(tlsSim, paramId, rawBits);
}

uint64_t halRetentiveRead(uint16_t paramId) {
    return retentiveRead(tlsSim, paramId);
}

/// The same simulated peripherals the firmware's plc_hal.c reports: TMP75 reads 25 deg C,
/// DS18B20 reads 22.5 deg C, and the CH455G display always acknowledges.
int32_t halCommExec(uint8_t busType, uint16_t, int64_t txVal, int64_t *rxVal, int32_t *err) {
    DuinoSimState *state = tlsSim;
    if (busType == VM_COMM_TMP75 || busType == VM_COMM_DS18B20) {
        const float temperature = (busType == VM_COMM_TMP75) ? state->tmp75Celsius
                                                             : state->ds18b20Celsius;
        uint32_t bits = 0;
        std::memcpy(&bits, &temperature, sizeof(bits));
        *rxVal = bits;
        *err = 0;
    } else if (busType == VM_COMM_CH455G) {
        // The VM packs the display (mara_vm.c, VM_OP_COMM_EXEC): float bits or four segment
        // bytes, decimals at 32, brightness at 36, digit mask at 40, enable at 44, mode at 45.
        const uint64_t packed = static_cast<uint64_t>(txVal);
        std::lock_guard<std::mutex> lock(state->ioMutex);
        state->display.valid = true;
        state->display.enabled = (packed >> 44) & 1;
        state->display.raw = (packed >> 45) & 1;
        state->display.digitMask = static_cast<uint8_t>((packed >> 40) & 0x0F);
        state->display.brightness = static_cast<int>((packed >> 36) & 0x0F);
        state->display.decimals = static_cast<int>((packed >> 32) & 0x0F);
        if (state->display.raw) {
            for (int i = 0; i < 4; ++i) state->display.segments[i] = static_cast<uint8_t>(packed >> (i * 8));
        } else {
            const uint32_t bits = static_cast<uint32_t>(packed);
            std::memcpy(&state->display.value, &bits, sizeof(bits));
        }
        *rxVal = 0;
        *err = 0;
    } else {
        *rxVal = 0;
        *err = 0;
    }
    return 0;
}

// MARK: - Socket helpers

bool readFull(int fd, uint8_t *buffer, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        const ssize_t received = recv(fd, buffer + offset, count - offset, 0);
        if (received <= 0) return false;
        offset += static_cast<size_t>(received);
    }
    return true;
}

bool writeFull(int fd, const uint8_t *buffer, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        const ssize_t sent = send(fd, buffer + offset, count - offset, 0);
        if (sent <= 0) return false;
        offset += static_cast<size_t>(sent);
    }
    return true;
}

// MARK: - Protocol

enum ProtOpcode : uint8_t {
    OP_PING = 0x01, OP_GET_INFO = 0x02,
    OP_VM_STATUS = 0x10, OP_VM_CONTROL = 0x11,
    OP_UPLOAD_BEGIN = 0x20, OP_UPLOAD_CHUNK = 0x21, OP_UPLOAD_COMMIT = 0x22,
    OP_WATCH_SUBSCRIBE = 0x30, OP_WATCH_POLL = 0x31,
    OP_SLOT_READ = 0x32, OP_SLOT_WRITE = 0x33,
    OP_RTC_GET = 0x40, OP_RTC_SET = 0x41,
    OP_ONEWIRE_SCAN = 0x50,
    OP_ENTER_DFU = 0xF3
};

enum ProtStatus : uint8_t {
    ST_OK = 0x00, ST_ERR_CRC = 0x01, ST_ERR_OPCODE = 0x02, ST_ERR_PARAM = 0x03,
    ST_ERR_BUSY = 0x04, ST_ERR_STATE = 0x05, ST_ERR_STORAGE = 0x06
};

/// Reads one slot's raw bytes from the VM; returns the byte count (0 when the slot is invalid).
size_t slotRaw(DuinoSimState *sim, uint16_t slotId, uint8_t *buffer) {
    return VM_ReadSlotRaw(sim->vm, slotId, buffer);
}

size_t slotByteSize(DuinoSimState *sim, uint16_t slotId) {
    uint8_t probe[8];
    return slotRaw(sim, slotId, probe);
}

/// Re-seeds the watch snapshot so a freshly built subscription list reports no stale changes.
void watchReseed(DuinoSimState *sim) {
    sim->watchSnapshot.clear();
    for (uint16_t slot : sim->watchSlots) {
        uint8_t raw[8];
        const size_t size = slotRaw(sim, slot, raw);
        sim->watchSnapshot[slot] = std::vector<uint8_t>(raw, raw + size);
    }
}

/// Steps the VM once and bumps the watch epoch when any subscribed slot moved.
void scanOnce(DuinoSimState *sim, uint32_t dtMicros) {
    tlsSim = sim;
    std::lock_guard<std::mutex> lock(sim->vmMutex);
    if (!sim->powered.load() || VM_GetState(sim->vm) != VM_STATE_RUNNING) return;
    for (uint8_t thread = 1; thread < VM_THREAD_COUNT; ++thread) {
        const auto start = std::chrono::steady_clock::now();
        VM_StepThread(sim->vm, thread, dtMicros);
        const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - start).count();
        sim->vm->threadActual_us[thread] = static_cast<uint32_t>(elapsed);
    }
    bool changed = false;
    for (uint16_t slot : sim->watchSlots) {
        uint8_t raw[8];
        const size_t size = slotRaw(sim, slot, raw);
        std::vector<uint8_t> current(raw, raw + size);
        auto it = sim->watchSnapshot.find(slot);
        if (it == sim->watchSnapshot.end() || it->second != current) {
            sim->watchSnapshot[slot] = std::move(current);
            changed = true;
        }
    }
    if (changed) sim->watchEpoch = static_cast<uint16_t>(sim->watchEpoch + 1);
}

void scanLoop(DuinoSimState *sim) {
    tlsSim = sim;
    auto last = std::chrono::steady_clock::now();
    while (!sim->stop.load()) {
        std::this_thread::sleep_until(last + std::chrono::milliseconds(kScanPeriodMs));
        const auto now = std::chrono::steady_clock::now();
        const uint32_t dtMicros = static_cast<uint32_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(now - last).count());
        last = now;
        scanOnce(sim, dtMicros == 0 ? 1 : dtMicros);
    }
}

/// Serves one connection until it closes. `lastEmitted` tracks what this client has seen, so a
/// poll answers only with deltas unless it asked for a snapshot.
void serveConnection(DuinoSimState *sim, int fd) {
    if (!sim->powered.load()) { close(fd); return; }
    {
        std::lock_guard<std::mutex> lock(sim->connectionsMutex);
        sim->connectionFds.push_back(fd);
    }
    tlsSim = sim;
    std::map<uint16_t, std::vector<uint8_t>> lastEmitted;
    std::vector<uint8_t> frame(10 + kMaxPayload + 2);
    while (!sim->stop.load()) {
        uint8_t *header = frame.data();
        if (!readFull(fd, header, 10)) break;
        if (header[0] != 0x4D || header[1] != 0x50 || (header[2] & 0xF0) != kFrameVersion) break;
        const uint16_t length = readU16(&header[8]);
        if (length > kMaxPayload) break;
        if (!readFull(fd, &frame[10], length + 2)) break;
        if (crc16Ccitt(header, 10 + length) != readU16(&frame[10 + length])) {
            // A corrupt frame gets no reply, exactly like a board on a noisy line.
            continue;
        }
        // TCP is point-to-point: any station id is accepted (MARAPROT.md §1).

        const uint8_t opcode = header[6];
        const uint8_t *payload = &frame[10];
        std::vector<uint8_t> reply;
        uint8_t status = ST_OK;

        if (!sim->powered.load()) break;
        {
            std::lock_guard<std::mutex> lock(sim->vmMutex);
            switch (opcode) {
                case OP_PING: {
                    uint32_t echo = length >= 4 ? readU32(payload) : 0;
                    const auto uptime = std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::steady_clock::now() - sim->bootTime).count();
                    appendU32(reply, echo);
                    appendU32(reply, static_cast<uint32_t>(uptime));
                    break;
                }
                case OP_GET_INFO: {
                    const VmInstance_t *vm = sim->vm;
                    appendU16(reply, 0x0001);                       // protoVersion
                    appendU16(reply, WIREBENCH_DUINO_SIM_MODEL_ID); // modelId
                    appendU32(reply, kFirmwareVersion);
                    reply.push_back(1);                             // transportKind: TCP/IP
                    appendU16(reply, kMaxPayload);                  // maxMtuBytes
                    reply.push_back(static_cast<uint8_t>(VM_GetState(vm)));
                    appendU32(reply, vm->hasValidImage ? readU32(&vm->imageBuf[12]) : 0);
                    appendU32(reply, vm->hasValidImage ? readU32(&vm->imageBuf[16]) : 0);
                    const char *name = "Duino - S";
                    reply.insert(reply.end(), name, name + std::strlen(name) + 1);
                    reply.resize(44, 0);
                    break;
                }
                case OP_VM_STATUS: {
                    const VmInstance_t *vm = sim->vm;
                    reply.push_back(static_cast<uint8_t>(VM_GetState(vm)));
                    reply.push_back(vm->estopActive);
                    appendU16(reply, vm->estopMask);
                    appendU32(reply, vm->scanCount);
                    for (int i = 0; i < VM_THREAD_COUNT; ++i) appendU32(reply, vm->threadActual_us[i]);
                    appendU16(reply, static_cast<uint16_t>(vm->lastFaultCode));
                    appendU16(reply, vm->lastFaultPc);
                    reply.resize(32, 0);
                    break;
                }
                case OP_VM_CONTROL: {
                    if (length < 1) { status = ST_ERR_PARAM; break; }
                    VmInstance_t *vm = sim->vm;
                    switch (payload[0]) {
                        case 0: VM_Reset(vm); VM_SetState(vm, VM_STATE_STOPPED); break;
                        case 1: VM_SetState(vm, VM_STATE_RUNNING); break;
                        case 2: VM_SetState(vm, VM_STATE_PAUSED); break;
                        case 5:
                            vm->estopActive = 0;
                            vm->estopMask = 0;
                            if (VM_GetState(vm) == VM_STATE_ESTOP) VM_SetState(vm, VM_STATE_RUNNING);
                            break;
                        case 6:
                            vm->lastFaultCode = VM_OK;
                            VM_SetState(vm, VM_STATE_STOPPED);
                            break;
                        default: status = ST_ERR_PARAM; break;
                    }
                    if (status == ST_OK) {
                        reply.push_back(static_cast<uint8_t>(VM_GetState(vm)));
                        reply.push_back(vm->estopActive);
                    }
                    break;
                }
                case OP_UPLOAD_BEGIN: {
                    if (length != 8) { status = ST_ERR_PARAM; break; }
                    sim->uploadExpectedBytes = readU32(payload);
                    sim->uploadExpectedCrc = readU32(payload + 4);
                    sim->uploadBuffer.clear();
                    sim->uploadOpen = true;
                    VM_SetState(sim->vm, VM_STATE_STOPPED);
                    sim->vm->hasValidImage = 0;
                    appendU16(reply, kMaxChunk);
                    break;
                }
                case OP_UPLOAD_CHUNK: {
                    if (!sim->uploadOpen || length < 4) { status = ST_ERR_STATE; break; }
                    const uint32_t offset = readU32(payload);
                    const size_t chunkLength = length - 4;
                    if (offset == sim->uploadBuffer.size()
                        && sim->uploadBuffer.size() + chunkLength <= VM_MAX_IMAGE_BYTES) {
                        sim->uploadBuffer.insert(sim->uploadBuffer.end(), payload + 4, payload + 4 + chunkLength);
                    }
                    // An offset behind the buffer is a retry: idempotent, like the firmware.
                    appendU32(reply, static_cast<uint32_t>(sim->uploadBuffer.size()));
                    break;
                }
                case OP_UPLOAD_COMMIT: {
                    if (!sim->uploadOpen) { status = ST_ERR_STATE; break; }
                    sim->uploadOpen = false;
                    if (sim->uploadBuffer.size() != sim->uploadExpectedBytes
                        || crc32Ieee(sim->uploadBuffer.data(), sim->uploadBuffer.size()) != sim->uploadExpectedCrc) {
                        sim->uploadBuffer.clear();
                        status = ST_ERR_CRC;
                        break;
                    }
                    if (VM_LoadImage(sim->vm, sim->uploadBuffer.data(),
                                     static_cast<uint32_t>(sim->uploadBuffer.size())) != VM_OK) {
                        sim->uploadBuffer.clear();
                        status = ST_ERR_PARAM;
                        break;
                    }
                    const bool autoStart = length >= 1 && payload[0] != 0;
                    if (autoStart) VM_SetState(sim->vm, VM_STATE_RUNNING);
                    appendU32(reply, readU32(&sim->vm->imageBuf[12]));
                    reply.push_back(static_cast<uint8_t>(VM_GetState(sim->vm)));
                    sim->uploadBuffer.clear();
                    break;
                }
                case OP_WATCH_SUBSCRIBE: {
                    if (length < 3) { status = ST_ERR_PARAM; break; }
                    const bool append = payload[0] == 1;
                    const uint16_t count = readU16(&payload[1]);
                    if (length < 3 + 2 * count) { status = ST_ERR_PARAM; break; }
                    if (!append) {
                        sim->watchSlots.clear();
                        lastEmitted.clear();
                    }
                    for (uint16_t i = 0; i < count; ++i) {
                        const uint16_t slot = readU16(&payload[3 + 2 * i]);
                        if (sim->watchSlots.size() < 512) sim->watchSlots.push_back(slot);
                    }
                    watchReseed(sim);
                    appendU16(reply, static_cast<uint16_t>(sim->watchSlots.size()));
                    appendU16(reply, sim->watchEpoch == 0 ? 1 : sim->watchEpoch);
                    break;
                }
                case OP_WATCH_POLL: {
                    const uint16_t ack = length >= 2 ? readU16(payload) : 0;
                    const bool snapshot = ack == 0 || ack != sim->watchEpoch;
                    std::vector<std::pair<uint16_t, std::vector<uint8_t>>> emitted;
                    for (uint16_t slot : sim->watchSlots) {
                        uint8_t raw[8];
                        const size_t size = slotRaw(sim, slot, raw);
                        std::vector<uint8_t> current(raw, raw + size);
                        const auto it = lastEmitted.find(slot);
                        if (snapshot || it == lastEmitted.end() || it->second != current) {
                            emitted.emplace_back(slot, current);
                            lastEmitted[slot] = current;
                        }
                    }
                    appendU16(reply, sim->watchEpoch == 0 ? 1 : sim->watchEpoch);
                    reply.push_back(static_cast<uint8_t>(VM_GetState(sim->vm)));
                    reply.push_back(sim->vm->estopActive);
                    // Emit as many as fit the MTU; the rest wait for the next poll.
                    size_t bytes = 6;
                    uint16_t emittedCount = 0;
                    for (const auto &entry : emitted) {
                        if (bytes + 2 + entry.second.size() > kMaxPayload) break;
                        appendU16(reply, entry.first);
                        reply.insert(reply.end(), entry.second.begin(), entry.second.end());
                        bytes += 2 + entry.second.size();
                        emittedCount += 1;
                    }
                    // Insert the count before the entries: rebuild with count in place.
                    std::vector<uint8_t> counted(reply.begin(), reply.begin() + 4);
                    appendU16(counted, emittedCount);
                    counted.insert(counted.end(), reply.begin() + 4, reply.end());
                    reply = std::move(counted);
                    break;
                }
                case OP_SLOT_READ: {
                    if (length < 2) { status = ST_ERR_PARAM; break; }
                    const uint16_t count = readU16(payload);
                    if (length < 2 + 2 * count) { status = ST_ERR_PARAM; break; }
                    std::vector<uint8_t> body;
                    appendU16(body, count);
                    for (uint16_t i = 0; i < count; ++i) {
                        const uint16_t slot = readU16(&payload[2 + 2 * i]);
                        uint8_t raw[8];
                        const size_t size = slotRaw(sim, slot, raw);
                        appendU16(body, slot);
                        body.insert(body.end(), raw, raw + size);
                    }
                    reply = std::move(body);
                    break;
                }
                case OP_SLOT_WRITE: {
                    if (length < 2) { status = ST_ERR_PARAM; break; }
                    const uint16_t count = readU16(payload);
                    size_t position = 2;
                    uint16_t applied = 0;
                    for (uint16_t i = 0; i < count; ++i) {
                        if (position + 2 > length) break;
                        const uint16_t slot = readU16(&payload[position]);
                        position += 2;
                        const size_t size = slotByteSize(sim, slot);
                        if (size == 0 || position + size > length) break;
                        if (VM_WriteSlotRaw(sim->vm, slot, &payload[position]) != 0) applied += 1;
                        position += size;
                        lastEmitted.erase(slot);   // force the next poll to report the write
                    }
                    appendU16(reply, applied);
                    break;
                }
                case OP_RTC_GET: {
                    appendU64(reply, static_cast<uint64_t>(halRtcUnixSec()));
                    break;
                }
                case OP_RTC_SET: {
                    if (length != 8) { status = ST_ERR_PARAM; break; }
                    std::lock_guard<std::mutex> ioLock(sim->ioMutex);
                    sim->rtcOverridden = true;
                    sim->rtcOverrideValue = static_cast<int64_t>(readU64(payload));
                    break;
                }
                case OP_ONEWIRE_SCAN: {
                    reply.push_back(sim->hasOnewireSensor ? 1 : 0);
                    if (sim->hasOnewireSensor) {
                        reply.insert(reply.end(), sim->onewireRom, sim->onewireRom + 8);
                    }
                    break;
                }
                case OP_ENTER_DFU: {
                    if (length != 4 || readU32(payload) != 0xDF00B007u) { status = ST_ERR_PARAM; break; }
                    reply.push_back(1);
                    break;
                }
                default:
                    status = ST_ERR_OPCODE;
                    break;
            }
        }

        std::vector<uint8_t> response;
        response.push_back(0x4D);
        response.push_back(0x50);
        response.push_back(static_cast<uint8_t>(kFrameVersion | kFlagResponse
                                               | (status == ST_OK ? 0 : kFlagError)));
        response.push_back(header[3]);              // stationId echoed
        response.push_back(header[4]);              // sequence echoed
        response.push_back(header[5]);
        response.push_back(opcode);
        response.push_back(status);
        appendU16(response, static_cast<uint16_t>(reply.size()));
        response.insert(response.end(), reply.begin(), reply.end());
        const uint16_t crc = crc16Ccitt(response.data(), response.size());
        appendU16(response, crc);
        if (!writeFull(fd, response.data(), response.size())) break;
    }
    close(fd);
    {
        std::lock_guard<std::mutex> lock(sim->connectionsMutex);
        for (auto it = sim->connectionFds.begin(); it != sim->connectionFds.end(); ++it) {
            if (*it == fd) { sim->connectionFds.erase(it); break; }
        }
    }
}

void acceptLoop(DuinoSimState *sim) {
    while (!sim->stop.load()) {
        const int fd = accept(sim->listenFd, nullptr, nullptr);
        if (fd < 0) break;
        if (!sim->powered.load()) { close(fd); continue; }
        std::thread client(serveConnection, sim, fd);
        {
            std::lock_guard<std::mutex> lock(sim->connectionsMutex);
            sim->connectionThreads.push_back(std::move(client));
        }
    }
}

} // namespace

extern "C" {

static DuinoSimState *impl(WirebenchDuinoSim *handle) {
    return reinterpret_cast<DuinoSimState *>(handle);
}
static const DuinoSimState *impl(const WirebenchDuinoSim *handle) {
    return reinterpret_cast<const DuinoSimState *>(handle);
}

/// One live simulator per process (the HAL resolves through thread-local storage, not a user
/// pointer), shared between create and destroy.
static DuinoSimState *&liveInstanceSlot() {
    static DuinoSimState *slot = nullptr;
    return slot;
}

WirebenchDuinoSim *wirebench_duinosim_create(uint16_t port) {
    static std::mutex instanceMutex;
    std::lock_guard<std::mutex> guard(instanceMutex);
    DuinoSimState *&liveInstance = liveInstanceSlot();
    if (liveInstance != nullptr) {
        liveInstance->error = "a Duino-S simulator is already running in this process";
        return nullptr;
    }

    auto *state = new DuinoSimState();
    state->vm = new VmInstance_t();
    state->hal.di_read = halDiRead;
    state->hal.do_write = halDoWrite;
    state->hal.ai_read = halAiRead;
    state->hal.ao_write = halAoWrite;
    state->hal.pwm_set = halPwmSet;
    state->hal.time_micros = halTimeMicros;
    state->hal.rtc_unix_sec = halRtcUnixSec;
    state->hal.rng_next = halRngNext;
    state->hal.retentive_write = halRetentiveWrite;
    state->hal.retentive_read = halRetentiveRead;
    state->hal.comm_exec = halCommExec;
    tlsSim = state;
    if (VM_Init(state->vm, &state->hal) != VM_OK) {
        state->error = "the MaraVM failed to initialise";
        delete state->vm;
        delete state;
        return nullptr;
    }

    const uint16_t requested = port == 0 ? WIREBENCH_DUINO_SIM_DEFAULT_PORT : port;
    state->listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (state->listenFd < 0) {
        state->error = "could not create the TCP socket";
        delete state->vm;
        delete state;
        return nullptr;
    }
    int reuse = 1;
    setsockopt(state->listenFd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   // localhost, as the feature promises
    address.sin_port = htons(requested);
    if (bind(state->listenFd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0
        || listen(state->listenFd, 4) != 0) {
        state->error = "could not bind port " + std::to_string(requested) + " (already in use?)";
        close(state->listenFd);
        delete state->vm;
        delete state;
        return nullptr;
    }
    state->port = requested;
    state->bootTime = std::chrono::steady_clock::now();
    state->acceptThread = std::thread(acceptLoop, state);
    state->scanThread = std::thread(scanLoop, state);
    liveInstance = state;
    return reinterpret_cast<WirebenchDuinoSim *>(state);
}

void wirebench_duinosim_destroy(WirebenchDuinoSim *handle) {
    DuinoSimState *state = impl(handle);
    if (state == nullptr) return;
    {
        static std::mutex instanceMutex;
        std::lock_guard<std::mutex> guard(instanceMutex);
        if (liveInstanceSlot() == state) liveInstanceSlot() = nullptr;
    }
    state->stop.store(true);
    if (state->listenFd >= 0) {
        shutdown(state->listenFd, SHUT_RDWR);
        close(state->listenFd);
    }
    // Stop accepting first, then close the clients. Joining the accept thread before taking the
    // connection list catches a connection accepted just before `stop` was set.
    if (state->acceptThread.joinable()) state->acceptThread.join();
    std::vector<std::thread> clients;
    {
        std::lock_guard<std::mutex> lock(state->connectionsMutex);
        for (int fd : state->connectionFds) shutdown(fd, SHUT_RDWR);
        clients.swap(state->connectionThreads);
    }
    for (auto &client : clients) {
        if (client.joinable()) client.join();
    }
    if (state->scanThread.joinable()) state->scanThread.join();
    delete state->vm;
    delete state;
}

uint16_t wirebench_duinosim_port(const WirebenchDuinoSim *handle) {
    const DuinoSimState *state = impl(handle);
    return state == nullptr ? 0 : state->port;
}

void wirebench_duinosim_set_power(WirebenchDuinoSim *handle, uint8_t value) {
    DuinoSimState *state = impl(handle);
    if (state == nullptr) return;
    tlsSim = state;
    const bool requested = value != 0;
    if (!requested) {
        std::lock_guard<std::mutex> lock(state->vmMutex);
        if (!state->powered.exchange(false)) return;
        state->resumeAfterPowerCycle = VM_GetState(state->vm) == VM_STATE_RUNNING;
        VM_SetState(state->vm, VM_STATE_STOPPED);
        state->vm->estopActive = 0;
        state->vm->estopMask = 0;
        {
            std::lock_guard<std::mutex> ioLock(state->ioMutex);
            state->doChannels.clear();
            state->aoChannels.clear();
            state->pwmChannels.clear();
            state->display = {};
        }
        state->watchEpoch = static_cast<uint16_t>(state->watchEpoch + 1);
        std::lock_guard<std::mutex> connectionsLock(state->connectionsMutex);
        for (int fd : state->connectionFds) shutdown(fd, SHUT_RDWR);
        return;
    }

    std::lock_guard<std::mutex> lock(state->vmMutex);
    if (state->powered.exchange(true)) return;
    VM_Reset(state->vm);
    state->bootTime = std::chrono::steady_clock::now();
    if (state->resumeAfterPowerCycle && state->vm->hasValidImage) {
        VM_SetState(state->vm, VM_STATE_RUNNING);
    }
    state->resumeAfterPowerCycle = false;
    state->watchEpoch = static_cast<uint16_t>(state->watchEpoch + 1);
}

uint8_t wirebench_duinosim_powered(const WirebenchDuinoSim *handle) {
    const DuinoSimState *state = impl(handle);
    return state != nullptr && state->powered.load() ? 1 : 0;
}

void wirebench_duinosim_control_vm(WirebenchDuinoSim *handle, uint8_t action) {
    DuinoSimState *state = impl(handle);
    if (state == nullptr) return;
    tlsSim = state;
    std::lock_guard<std::mutex> lock(state->vmMutex);
    if (!state->powered.load()) return;
    switch (action) {
        case 0:
            VM_Reset(state->vm);
            VM_SetState(state->vm, VM_STATE_STOPPED);
            break;
        case 1:
            if (state->vm->hasValidImage) VM_SetState(state->vm, VM_STATE_RUNNING);
            break;
        case 2:
            if (state->vm->hasValidImage) VM_SetState(state->vm, VM_STATE_PAUSED);
            break;
        default:
            break;
    }
}

uint8_t wirebench_duinosim_vm_state(const WirebenchDuinoSim *handle) {
    const DuinoSimState *state = impl(handle);
    if (state == nullptr || !state->powered.load()) return VM_STATE_STOPPED;
    std::lock_guard<std::mutex> lock(state->vmMutex);
    return static_cast<uint8_t>(VM_GetState(state->vm));
}

const char *wirebench_duinosim_error(const WirebenchDuinoSim *handle) {
    if (handle == nullptr) return "out of memory creating the simulator";
    const DuinoSimState *state = impl(handle);
    std::lock_guard<std::mutex> lock(state->ioMutex);
    return state->error.empty() ? "" : state->error.c_str();
}

void wirebench_duinosim_set_di(WirebenchDuinoSim *handle, uint32_t channel, uint8_t value) {
    DuinoSimState *state = impl(handle);
    std::lock_guard<std::mutex> lock(state->ioMutex);
    state->di[channel] = value;
}

uint8_t wirebench_duinosim_di(const WirebenchDuinoSim *handle, uint32_t channel) {
    const DuinoSimState *state = impl(handle);
    std::lock_guard<std::mutex> lock(state->ioMutex);
    const auto it = state->di.find(channel);
    return it == state->di.end() ? 0 : it->second;
}

uint8_t wirebench_duinosim_get_do(const WirebenchDuinoSim *handle, uint32_t channel) {
    const DuinoSimState *state = impl(handle);
    std::lock_guard<std::mutex> lock(state->ioMutex);
    const auto it = state->doChannels.find(channel);
    return it == state->doChannels.end() ? 0 : it->second;
}

void wirebench_duinosim_set_ai(WirebenchDuinoSim *handle, uint32_t channel, int32_t value) {
    DuinoSimState *state = impl(handle);
    std::lock_guard<std::mutex> lock(state->ioMutex);
    state->ai[channel] = value;
}

int32_t wirebench_duinosim_ai(const WirebenchDuinoSim *handle, uint32_t channel) {
    const DuinoSimState *state = impl(handle);
    std::lock_guard<std::mutex> lock(state->ioMutex);
    const auto it = state->ai.find(channel);
    return it == state->ai.end() ? 0 : it->second;
}

int32_t wirebench_duinosim_get_ao(const WirebenchDuinoSim *handle, uint32_t channel) {
    const DuinoSimState *state = impl(handle);
    std::lock_guard<std::mutex> lock(state->ioMutex);
    const auto it = state->aoChannels.find(channel);
    return it == state->aoChannels.end() ? 0 : it->second;
}

float wirebench_duinosim_get_pwm(const WirebenchDuinoSim *handle, uint32_t channel) {
    const DuinoSimState *state = impl(handle);
    std::lock_guard<std::mutex> lock(state->ioMutex);
    const auto it = state->pwmChannels.find(channel);
    return it == state->pwmChannels.end() ? 0.0f : it->second;
}

void wirebench_duinosim_set_temperature_c(WirebenchDuinoSim *handle, float tmp75, float ds18b20) {
    DuinoSimState *state = impl(handle);
    std::lock_guard<std::mutex> lock(state->ioMutex);
    state->tmp75Celsius = tmp75;
    state->ds18b20Celsius = ds18b20;
}

void wirebench_duinosim_set_onewire_rom(WirebenchDuinoSim *handle, const uint8_t rom[8]) {
    DuinoSimState *state = impl(handle);
    std::lock_guard<std::mutex> lock(state->ioMutex);
    state->hasOnewireSensor = rom != nullptr;
    if (rom != nullptr) std::memcpy(state->onewireRom, rom, 8);
}

void wirebench_duinosim_set_eeprom_path(WirebenchDuinoSim *handle, const char *path) {
    DuinoSimState *state = impl(handle);
    std::lock_guard<std::mutex> lock(state->ioMutex);
    state->eepromPath = path == nullptr ? "" : path;
    eepromLoad(state);
}

void wirebench_duinosim_display(const WirebenchDuinoSim *handle, WirebenchDuinoSimDisplay *out) {
    const DuinoSimState *state = impl(handle);
    std::lock_guard<std::mutex> lock(state->ioMutex);
    std::memset(out, 0, sizeof(*out));
    if (!state->powered.load()) return;
    out->valid = state->display.valid ? 1 : 0;
    out->enabled = state->display.enabled ? 1 : 0;
    out->raw = state->display.raw ? 1 : 0;
    out->digitMask = state->display.digitMask;
    out->brightness = state->display.brightness;
    out->decimals = state->display.decimals;
    if (state->display.raw) {
        std::memcpy(out->segments, state->display.segments, 4);
    } else {
        out->value = state->display.value;
        char formatted[32];
        std::snprintf(formatted, sizeof(formatted), "%.*f",
                      state->display.decimals, static_cast<double>(state->display.value));
        std::string text(formatted);
        if (text.size() > 7) text = text.substr(text.size() - 7);
        // Text is an intermediate representation; the renderer right-aligns three digits and treats
        // decimal points as part of the preceding digit rather than as a fourth digit.
        std::memcpy(out->text, text.c_str(), text.size() + 1);
    }
}

void wirebench_duinosim_trip_estop(WirebenchDuinoSim *handle, uint32_t mask) {
    DuinoSimState *state = impl(handle);
    tlsSim = state;
    std::lock_guard<std::mutex> lock(state->vmMutex);
    if (!state->powered.load()) return;
    state->vm->estopActive = 1;
    state->vm->estopMask = static_cast<uint16_t>(mask);
    VM_SetState(state->vm, VM_STATE_ESTOP);
}

uint8_t wirebench_duinosim_estop_active(const WirebenchDuinoSim *handle) {
    const DuinoSimState *state = impl(handle);
    tlsSim = const_cast<DuinoSimState *>(state);
    std::lock_guard<std::mutex> lock(state->vmMutex);
    return state->vm->estopActive;
}

void wirebench_duinosim_clear_estop(WirebenchDuinoSim *handle) {
    DuinoSimState *state = impl(handle);
    tlsSim = state;
    std::lock_guard<std::mutex> lock(state->vmMutex);
    if (!state->powered.load()) return;
    state->vm->estopActive = 0;
    state->vm->estopMask = 0;
    if (VM_GetState(state->vm) == VM_STATE_ESTOP) VM_SetState(state->vm, VM_STATE_RUNNING);
}

} // extern "C"
