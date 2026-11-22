#ifndef WIREBENCH_DUINO_SIM_H
#define WIREBENCH_DUINO_SIM_H

/*
 * WirebenchDuinoSim — a software Duino-S (Maramat, MaraProt v1 / MaraVM).
 *
 * The simulator runs the same portable mara_vm.c the firmware runs, serves MaraProt v1 over TCP
 * on the Duino-S port (5020 by default), and backs the HAL with virtual I/O maps the host can read
 * and write. Wirebench (or Maraflow) connects to it exactly as it would to a board on the LAN.
 *
 * One instance per process is the expected use (the HAL has no user-data pointer, so callbacks
 * resolve the instance per thread); creating a second instance while one is live fails.
 *
 * Threading: create starts a listen thread and a 10 ms scan thread; all entry points are safe to
 * call from any thread.
 */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// The handle type: opaque to callers. Sized so Swift (and C) can hold it by name; the
/// simulator's state is a private C++ struct behind the pointer.
typedef struct { uintptr_t opaque; } WirebenchDuinoSim;

enum {
    WIREBENCH_DUINO_SIM_DEFAULT_PORT = 5020,
    WIREBENCH_DUINO_SIM_MODEL_ID     = 0x0407
};

/// Creates a simulator listening on `port` (0 = the default 5020). Returns NULL on failure;
/// `wirebench_duinosim_error` of NULL then reports why. The sim runs until destroyed.
WirebenchDuinoSim *wirebench_duinosim_create(uint16_t port);

/// Stops the threads, closes the socket and releases everything.
void wirebench_duinosim_destroy(WirebenchDuinoSim *sim);

/// The port actually bound (useful with 0 / when the caller picked the port).
uint16_t wirebench_duinosim_port(const WirebenchDuinoSim *sim);

/// Host-side DC power. Off stops the scan, clears volatile outputs and drops protocol clients;
/// on reboots the VM and resumes a program that was running before the power cycle.
void wirebench_duinosim_set_power(WirebenchDuinoSim *sim, uint8_t powered);
uint8_t wirebench_duinosim_powered(const WirebenchDuinoSim *sim);

/// Host transport control, using the firmware's VM_CONTROL actions: 0 stop/reset, 1 run, 2 pause.
void wirebench_duinosim_control_vm(WirebenchDuinoSim *sim, uint8_t action);
uint8_t wirebench_duinosim_vm_state(const WirebenchDuinoSim *sim);

/// The error text for a failed create (NULL sim) or the last failure on a live one.
const char *wirebench_duinosim_error(const WirebenchDuinoSim *sim);

/// Virtual I/O: what a connected program writes (DO/AO/PWM) and reads (DI/AI) from the "pins".
void     wirebench_duinosim_set_di(WirebenchDuinoSim *sim, uint32_t channel, uint8_t value);
uint8_t  wirebench_duinosim_di(const WirebenchDuinoSim *sim, uint32_t channel);
uint8_t  wirebench_duinosim_get_do(const WirebenchDuinoSim *sim, uint32_t channel);
void     wirebench_duinosim_set_ai(WirebenchDuinoSim *sim, uint32_t channel, int32_t value);
int32_t  wirebench_duinosim_ai(const WirebenchDuinoSim *sim, uint32_t channel);
int32_t  wirebench_duinosim_get_ao(const WirebenchDuinoSim *sim, uint32_t channel);
float    wirebench_duinosim_get_pwm(const WirebenchDuinoSim *sim, uint32_t channel);

/// E-stop: trip sets the active flag and mask (and the VM state), clear releases them.
void wirebench_duinosim_trip_estop(WirebenchDuinoSim *sim, uint32_t mask);
uint8_t wirebench_duinosim_estop_active(const WirebenchDuinoSim *sim);
void wirebench_duinosim_clear_estop(WirebenchDuinoSim *sim);

/// The shield's sensors: what the simulated TMP75 and 1-Wire DS18B20 report (defaults 25 / 22.5).
void wirebench_duinosim_set_temperature_c(WirebenchDuinoSim *sim, float tmp75, float ds18b20);

/// Attaches a DS18B20 to the 1-Wire bus so ONEWIRE_SCAN finds it (NULL detaches all).
void wirebench_duinosim_set_onewire_rom(WirebenchDuinoSim *sim, const uint8_t rom[8]);

/// Backs the retentive store (BL24C256A EEPROM) with a 32 KiB image file, so values survive a
/// restart of the simulator. NULL returns to the in-memory store.
void wirebench_duinosim_set_eeprom_path(WirebenchDuinoSim *sim, const char *path);

/// The shield's CH455G 7-segment display, decoded from the VM's last update.
typedef struct {
    char text[8];          ///< "12.5" style rendering (numeric mode; masked digits are blank)
    uint8_t valid;         ///< a CH455G COMM_EXEC packet has been received
    uint8_t enabled;       ///< the block is enabled
    uint8_t raw;           ///< 1 = raw segment mode (`segments` valid, `text` empty)
    uint8_t digitMask;     ///< which of the three physical digits are lit
    uint8_t decimals;      ///< decimal places (numeric mode)
    int32_t brightness;    ///< 1...8
    float value;           ///< numeric mode value
    uint8_t segments[4];   ///< raw mode bytes; index 3 is not populated on the shield
} WirebenchDuinoSimDisplay;

void wirebench_duinosim_display(const WirebenchDuinoSim *sim, WirebenchDuinoSimDisplay *out);

#ifdef __cplusplus
}
#endif

#endif
