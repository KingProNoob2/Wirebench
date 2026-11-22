// Portable, hardware-agnostic MaraVM v1 PLC bytecode virtual machine.
// Zero MCU dependencies: all hardware I/O is routed through VmHalVtable_t.

#ifndef MARA_VM_H
#define MARA_VM_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define VM_MAGIC_MFLW            0x574C464DU
#define VM_FORMAT_VERSION        0x0001U
#define VM_HEADER_SIZE_BYTES     72U
#define VM_THREAD_COUNT          6U
#define VM_MAX_IMAGE_BYTES       28672U
#define VM_MAX_BOOL_SLOTS        2048U
#define VM_MAX_INT_SLOTS         1024U
#define VM_MAX_LONG_SLOTS        256U
#define VM_MAX_FLOAT_SLOTS       1024U
#define VM_MAX_STATE_SLOTS       512U
#define VM_MAX_MOVAVG_INSTANCES  8U
#define VM_MOVAVG_MAX_WIN        64U
#define VM_MAX_ARRAYS            8U
#define VM_ARRAY_LEN             64U
#define VM_MAX_LOOP_FUEL         4096U
#define VM_SLOT_ALWAYS_ENABLED   0xFFFFU
#define VM_SLOT_TYPE_SHIFT       14U
#define VM_SLOT_INDEX_MASK       0x3FFFU
#define VM_MAX_SLOT_BYTES        8U

typedef enum {
    VM_OK = 0,
    VM_ERR_PARAM,
    VM_ERR_BAD_MAGIC,
    VM_ERR_BAD_VERSION,
    VM_ERR_BAD_CRC,
    VM_ERR_TOO_LARGE,
    VM_ERR_FAULT_OPCODE,
    VM_ERR_FAULT_FUEL,
    VM_ERR_FAULT_BOUNDS
} VmStatus_t;

typedef enum {
    VM_STATE_STOPPED = 0,
    VM_STATE_RUNNING = 1,
    VM_STATE_PAUSED  = 2,
    VM_STATE_FAULT   = 3,
    VM_STATE_ESTOP   = 4
} VmRunState_t;

typedef enum {
    VM_TYPE_BOOL  = 0,
    VM_TYPE_INT   = 1,
    VM_TYPE_LONG  = 2,
    VM_TYPE_FLOAT = 3
} VmSlotType_t;

typedef enum {
    VM_OP_HALT        = 0x00,
    VM_OP_NOP         = 0x01,
    VM_OP_ESTOP_CHECK = 0x02,
    VM_OP_JMP         = 0x04,
    VM_OP_JMP_FALSE   = 0x05,
    VM_OP_MOV         = 0x08,
    VM_OP_CAST        = 0x09,
    VM_OP_PACK8       = 0x0A,
    VM_OP_UNPACK8     = 0x0B,
    VM_OP_AND         = 0x10,
    VM_OP_NAND        = 0x11,
    VM_OP_OR          = 0x12,
    VM_OP_NOR         = 0x13,
    VM_OP_XOR         = 0x14,
    VM_OP_XNOR        = 0x15,
    VM_OP_NOT         = 0x16,
    VM_OP_RS          = 0x17,
    VM_OP_SR          = 0x18,
    VM_OP_LD_CONTACT  = 0x1A,
    VM_OP_LD_COIL     = 0x1B,
    VM_OP_ADD         = 0x20,
    VM_OP_SUB         = 0x21,
    VM_OP_MUL         = 0x22,
    VM_OP_DIV         = 0x23,
    VM_OP_MOD         = 0x24,
    VM_OP_MIN         = 0x26,
    VM_OP_MAX         = 0x27,
    VM_OP_ABS         = 0x28,
    VM_OP_NEG         = 0x29,
    VM_OP_SQRT        = 0x2A,
    VM_OP_SIN         = 0x2B,
    VM_OP_COS         = 0x2C,
    VM_OP_CLAMP       = 0x2D,
    VM_OP_SCALE       = 0x2E,
    VM_OP_RANDOM      = 0x2F,
    VM_OP_PID         = 0x30,
    VM_OP_LOWPASS     = 0x31,
    VM_OP_MOVING_AVG  = 0x32,
    VM_OP_DEBOUNCE    = 0x33,
    VM_OP_RET_READ    = 0x36,
    VM_OP_RET_WRITE   = 0x37,
    VM_OP_ARRAY_READ  = 0x38,
    VM_OP_ARRAY_WRITE = 0x39,
    VM_OP_INT_CAPTURE = 0x3A,
    VM_OP_CMP_EQ      = 0x40,
    VM_OP_CMP_NE      = 0x41,
    VM_OP_CMP_GT      = 0x42,
    VM_OP_CMP_GE      = 0x43,
    VM_OP_CMP_LT      = 0x44,
    VM_OP_CMP_LE      = 0x45,
    VM_OP_IN_RANGE    = 0x46,
    VM_OP_HYSTERESIS  = 0x47,
    VM_OP_SEL         = 0x48,
    VM_OP_TON         = 0x50,
    VM_OP_PULSE_GEN   = 0x51,
    VM_OP_PULSE_LEN   = 0x52,
    VM_OP_ONE_SHOT    = 0x53,
    VM_OP_CTUD        = 0x54,
    VM_OP_RTC_GET     = 0x60,
    VM_OP_DECODE_DATE = 0x61,
    VM_OP_ENCODE_DATE = 0x62,
    VM_OP_IO_READ     = 0x70,
    VM_OP_IO_WRITE    = 0x71,
    VM_OP_IO_PWM      = 0x72,
    VM_OP_COMM_EXEC   = 0x75
} VmOpcode_t;

typedef enum {
    VM_IO_DI  = 0,
    VM_IO_DO  = 1,
    VM_IO_AI  = 2,
    VM_IO_AO  = 3,
    VM_IO_PWM = 4
} VmIoKind_t;

typedef enum {
    VM_COMM_TMP75   = 1,
    VM_COMM_DS18B20 = 2,
    VM_COMM_CH455G  = 3
} VmCommBus_t;

typedef struct {
    uint8_t  (*di_read)(uint16_t channel);
    void     (*do_write)(uint16_t channel, uint8_t val);
    int32_t  (*ai_read)(uint16_t channel);
    void     (*ao_write)(uint16_t channel, int32_t val);
    uint8_t  (*pwm_set)(uint16_t channel, int32_t freq_hz, float dutyPct);
    uint32_t (*time_micros)(void);
    int64_t  (*rtc_unix_sec)(void);
    uint32_t (*rng_next)(void);
    void     (*retentive_write)(uint16_t paramId, uint64_t rawBits);
    uint64_t (*retentive_read)(uint16_t paramId);
    int32_t  (*comm_exec)(uint8_t busType, uint16_t descId, int64_t txVal, int64_t *p_rxVal, int32_t *p_err);
} VmHalVtable_t;

typedef struct {
    float    accFloat;
    float    auxFloat;
    uint32_t timer_ms;
    uint8_t  prevBool;
    uint8_t  prevAuxBool;
    uint8_t  latchedBool;
    uint8_t  reserved;
} VmStateSlot_t;

typedef struct {
    uint32_t magic;
    uint16_t formatVersion;
    uint16_t targetModelId;
    uint32_t imageSizeBytes;
    uint32_t payloadCrc32;
    uint32_t projectHash;
    uint16_t numBoolSlots;
    uint16_t numIntSlots;
    uint16_t numLongSlots;
    uint16_t numFloatSlots;
    uint16_t numStateSlots;
    uint16_t numArrays;
    uint32_t estopConfig;
    uint32_t initTableOffset;
    uint32_t initTableCount;
    uint32_t threadOffset[VM_THREAD_COUNT];
} VmImageHeader_t;

typedef struct {
    VmRunState_t   runState;
    VmStatus_t     lastFaultCode;
    uint16_t       lastFaultPc;
    uint8_t        estopActive;
    uint16_t       estopMask;
    uint32_t       scanCount;
    uint32_t       threadActual_us[VM_THREAD_COUNT];
    uint32_t       imageSizeBytes;
    VmImageHeader_t header;
    VmHalVtable_t  hal;
    bool           hasValidImage;
    uint8_t        imageBuf[VM_MAX_IMAGE_BYTES];
    uint8_t        boolRam[VM_MAX_BOOL_SLOTS];
    int32_t        intRam[VM_MAX_INT_SLOTS];
    int64_t        longRam[VM_MAX_LONG_SLOTS];
    float          floatRam[VM_MAX_FLOAT_SLOTS];
    VmStateSlot_t  stateRam[VM_MAX_STATE_SLOTS];
    float          movAvgBuf[VM_MAX_MOVAVG_INSTANCES][VM_MOVAVG_MAX_WIN];
    float          movAvgSum[VM_MAX_MOVAVG_INSTANCES];
    uint8_t        movAvgHead[VM_MAX_MOVAVG_INSTANCES];
    uint8_t        movAvgCount[VM_MAX_MOVAVG_INSTANCES];
    float          arrayRam[VM_MAX_ARRAYS][VM_ARRAY_LEN];
    uint32_t       rngState;
} VmInstance_t;

// Initialize a caller-allocated VmInstance_t and attach the HAL driver vtable.
VmStatus_t VM_Init(VmInstance_t *p_vm, const VmHalVtable_t *p_hal);

// Validate and load an MFLW binary image into the VM workspace.
VmStatus_t VM_LoadImage(VmInstance_t *p_vm, const uint8_t *p_image, uint32_t lenBytes);

// Reset all slot tables to initial constants and clear stateful blocks.
VmStatus_t VM_Reset(VmInstance_t *p_vm);

// Transition VM run state (STOPPED, RUNNING, PAUSED).
VmStatus_t VM_SetState(VmInstance_t *p_vm, VmRunState_t newState);

// Query current VM run state.
VmRunState_t VM_GetState(const VmInstance_t *p_vm);

// Execute one scan cycle of threadId (1..5) with elapsed dt_us.
VmStatus_t VM_StepThread(VmInstance_t *p_vm, uint8_t threadId, uint32_t dt_us);

// Read raw little-endian bytes for any type-tagged 16-bit SlotID.
uint8_t VM_ReadSlotRaw(const VmInstance_t *p_vm, uint16_t slotId, uint8_t *p_outBuf);

// Write raw little-endian bytes for any type-tagged 16-bit SlotID.
uint8_t VM_WriteSlotRaw(VmInstance_t *p_vm, uint16_t slotId, const uint8_t *p_inBuf);

// Return byte width (1, 4, or 8) for a type-tagged 16-bit SlotID.
uint8_t VM_GetSlotSize(uint16_t slotId);

// Standard IEEE 802.3 CRC32 helper (software, portable across C and Java).
uint32_t VM_CalcCrc32(const uint8_t *p_data, uint32_t lenBytes);

#ifdef __cplusplus
}
#endif

#endif // MARA_VM_H
