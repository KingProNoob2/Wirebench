// Portable, hardware-agnostic MaraVM v1 bytecode interpreter implementation.

#include "mara_vm.h"
#include <math.h>
#include <string.h>

#define VM_INIT_ENTRY_BYTES   12U
#define VM_CRC32_POLY         0xEDB88320U
#define VM_CRC32_INIT         0xFFFFFFFFU
#define VM_LD_CONTACT_NO      0U
#define VM_LD_CONTACT_NC      1U
#define VM_LD_CONTACT_POS     2U
#define VM_LD_CONTACT_NEG     3U
#define VM_LD_COIL_NORMAL     0U
#define VM_LD_COIL_NEGATED    1U
#define VM_LD_COIL_SET        2U
#define VM_LD_COIL_RESET      3U
#define VM_LD_COIL_POS        4U
#define VM_LD_COIL_NEG        5U

static uint16_t read_u16_le(const uint8_t *p_buf)
{
    return (uint16_t)p_buf[0] | ((uint16_t)p_buf[1] << 8U);
}

static uint32_t read_u32_le(const uint8_t *p_buf)
{
    return (uint32_t)p_buf[0]
         | ((uint32_t)p_buf[1] << 8U)
         | ((uint32_t)p_buf[2] << 16U)
         | ((uint32_t)p_buf[3] << 24U);
}

static uint64_t read_u64_le(const uint8_t *p_buf)
{
    return (uint64_t)read_u32_le(p_buf) | ((uint64_t)read_u32_le(&p_buf[4]) << 32U);
}

static void parse_header(const uint8_t *p_buf, VmImageHeader_t *p_hdr)
{
    p_hdr->magic           = read_u32_le(&p_buf[0]);
    p_hdr->formatVersion   = read_u16_le(&p_buf[4]);
    p_hdr->targetModelId   = read_u16_le(&p_buf[6]);
    p_hdr->imageSizeBytes  = read_u32_le(&p_buf[8]);
    p_hdr->payloadCrc32    = read_u32_le(&p_buf[12]);
    p_hdr->projectHash     = read_u32_le(&p_buf[16]);
    p_hdr->numBoolSlots    = read_u16_le(&p_buf[20]);
    p_hdr->numIntSlots     = read_u16_le(&p_buf[22]);
    p_hdr->numLongSlots    = read_u16_le(&p_buf[24]);
    p_hdr->numFloatSlots   = read_u16_le(&p_buf[26]);
    p_hdr->numStateSlots   = read_u16_le(&p_buf[28]);
    p_hdr->numArrays       = read_u16_le(&p_buf[30]);
    p_hdr->estopConfig     = read_u32_le(&p_buf[32]);
    p_hdr->initTableOffset = read_u32_le(&p_buf[36]);
    p_hdr->initTableCount  = read_u32_le(&p_buf[40]);
    for (uint32_t i = 0U; i < VM_THREAD_COUNT; i++) {
        p_hdr->threadOffset[i] = read_u32_le(&p_buf[44U + (i * 4U)]);
    }
}

static bool slot_in_bounds(uint16_t slotId)
{
    uint16_t idx  = slotId & VM_SLOT_INDEX_MASK;
    uint8_t  type = (uint8_t)(slotId >> VM_SLOT_TYPE_SHIFT);
    switch (type) {
        case VM_TYPE_BOOL:  return idx < VM_MAX_BOOL_SLOTS;
        case VM_TYPE_INT:   return idx < VM_MAX_INT_SLOTS;
        case VM_TYPE_LONG:  return idx < VM_MAX_LONG_SLOTS;
        case VM_TYPE_FLOAT: return idx < VM_MAX_FLOAT_SLOTS;
        default:            return false;
    }
}

static uint8_t read_bool(const VmInstance_t *p_vm, uint16_t slotId)
{
    uint16_t idx  = slotId & VM_SLOT_INDEX_MASK;
    uint8_t  type = (uint8_t)(slotId >> VM_SLOT_TYPE_SHIFT);
    switch (type) {
        case VM_TYPE_BOOL:  return (idx < VM_MAX_BOOL_SLOTS) ? (p_vm->boolRam[idx] != 0U ? 1U : 0U) : 0U;
        case VM_TYPE_INT:   return (idx < VM_MAX_INT_SLOTS) ? (p_vm->intRam[idx] != 0 ? 1U : 0U) : 0U;
        case VM_TYPE_LONG:  return (idx < VM_MAX_LONG_SLOTS) ? (p_vm->longRam[idx] != 0 ? 1U : 0U) : 0U;
        case VM_TYPE_FLOAT: return (idx < VM_MAX_FLOAT_SLOTS) ? (p_vm->floatRam[idx] != 0.0f ? 1U : 0U) : 0U;
        default:            return 0U;
    }
}

static int32_t read_int(const VmInstance_t *p_vm, uint16_t slotId)
{
    uint16_t idx  = slotId & VM_SLOT_INDEX_MASK;
    uint8_t  type = (uint8_t)(slotId >> VM_SLOT_TYPE_SHIFT);
    switch (type) {
        case VM_TYPE_BOOL:  return (idx < VM_MAX_BOOL_SLOTS) ? (int32_t)(p_vm->boolRam[idx] != 0U ? 1 : 0) : 0;
        case VM_TYPE_INT:   return (idx < VM_MAX_INT_SLOTS) ? p_vm->intRam[idx] : 0;
        case VM_TYPE_LONG:  return (idx < VM_MAX_LONG_SLOTS) ? (int32_t)p_vm->longRam[idx] : 0;
        case VM_TYPE_FLOAT: return (idx < VM_MAX_FLOAT_SLOTS) ? (int32_t)p_vm->floatRam[idx] : 0;
        default:            return 0;
    }
}

static int64_t read_long(const VmInstance_t *p_vm, uint16_t slotId)
{
    uint16_t idx  = slotId & VM_SLOT_INDEX_MASK;
    uint8_t  type = (uint8_t)(slotId >> VM_SLOT_TYPE_SHIFT);
    switch (type) {
        case VM_TYPE_BOOL:  return (idx < VM_MAX_BOOL_SLOTS) ? (int64_t)(p_vm->boolRam[idx] != 0U ? 1 : 0) : 0;
        case VM_TYPE_INT:   return (idx < VM_MAX_INT_SLOTS) ? (int64_t)p_vm->intRam[idx] : 0;
        case VM_TYPE_LONG:  return (idx < VM_MAX_LONG_SLOTS) ? p_vm->longRam[idx] : 0;
        case VM_TYPE_FLOAT: return (idx < VM_MAX_FLOAT_SLOTS) ? (int64_t)p_vm->floatRam[idx] : 0;
        default:            return 0;
    }
}

static float read_float(const VmInstance_t *p_vm, uint16_t slotId)
{
    uint16_t idx  = slotId & VM_SLOT_INDEX_MASK;
    uint8_t  type = (uint8_t)(slotId >> VM_SLOT_TYPE_SHIFT);
    switch (type) {
        case VM_TYPE_BOOL:  return (idx < VM_MAX_BOOL_SLOTS) ? (p_vm->boolRam[idx] != 0U ? 1.0f : 0.0f) : 0.0f;
        case VM_TYPE_INT:   return (idx < VM_MAX_INT_SLOTS) ? (float)p_vm->intRam[idx] : 0.0f;
        case VM_TYPE_LONG:  return (idx < VM_MAX_LONG_SLOTS) ? (float)p_vm->longRam[idx] : 0.0f;
        case VM_TYPE_FLOAT: return (idx < VM_MAX_FLOAT_SLOTS) ? p_vm->floatRam[idx] : 0.0f;
        default:            return 0.0f;
    }
}

static uint8_t vm_encode_ch455g_seg(int32_t code, bool dp)
{
    static const uint8_t kSegLut[16] = {
        0x3FU, 0x06U, 0x5BU, 0x4FU, 0x66U, 0x6DU, 0x7DU, 0x07U,
        0x7FU, 0x6FU, 0x77U, 0x7CU, 0x39U, 0x5EU, 0x79U, 0x71U
    };
    uint8_t seg = 0x00U;
    if (code >= 0 && code <= 15) {
        seg = kSegLut[code];
    } else if (code == -2) {
        seg = 0x40U;
    } else if (code >= 0x100) {
        seg = (uint8_t)(code & 0xFF);
    }
    if (dp) {
        seg |= 0x80U;
    }
    return seg;
}

static void write_bool(VmInstance_t *p_vm, uint16_t slotId, uint8_t val)
{
    uint16_t idx  = slotId & VM_SLOT_INDEX_MASK;
    uint8_t  type = (uint8_t)(slotId >> VM_SLOT_TYPE_SHIFT);
    uint8_t  bVal = (val != 0U) ? 1U : 0U;
    switch (type) {
        case VM_TYPE_BOOL:  if (idx < VM_MAX_BOOL_SLOTS) { p_vm->boolRam[idx] = bVal; } break;
        case VM_TYPE_INT:   if (idx < VM_MAX_INT_SLOTS) { p_vm->intRam[idx] = (int32_t)bVal; } break;
        case VM_TYPE_LONG:  if (idx < VM_MAX_LONG_SLOTS) { p_vm->longRam[idx] = (int64_t)bVal; } break;
        case VM_TYPE_FLOAT: if (idx < VM_MAX_FLOAT_SLOTS) { p_vm->floatRam[idx] = (float)bVal; } break;
        default:            break;
    }
}

static void write_int(VmInstance_t *p_vm, uint16_t slotId, int32_t val)
{
    uint16_t idx  = slotId & VM_SLOT_INDEX_MASK;
    uint8_t  type = (uint8_t)(slotId >> VM_SLOT_TYPE_SHIFT);
    switch (type) {
        case VM_TYPE_BOOL:  if (idx < VM_MAX_BOOL_SLOTS) { p_vm->boolRam[idx] = (val != 0) ? 1U : 0U; } break;
        case VM_TYPE_INT:   if (idx < VM_MAX_INT_SLOTS) { p_vm->intRam[idx] = val; } break;
        case VM_TYPE_LONG:  if (idx < VM_MAX_LONG_SLOTS) { p_vm->longRam[idx] = (int64_t)val; } break;
        case VM_TYPE_FLOAT: if (idx < VM_MAX_FLOAT_SLOTS) { p_vm->floatRam[idx] = (float)val; } break;
        default:            break;
    }
}

static void write_long(VmInstance_t *p_vm, uint16_t slotId, int64_t val)
{
    uint16_t idx  = slotId & VM_SLOT_INDEX_MASK;
    uint8_t  type = (uint8_t)(slotId >> VM_SLOT_TYPE_SHIFT);
    switch (type) {
        case VM_TYPE_BOOL:  if (idx < VM_MAX_BOOL_SLOTS) { p_vm->boolRam[idx] = (val != 0) ? 1U : 0U; } break;
        case VM_TYPE_INT:   if (idx < VM_MAX_INT_SLOTS) { p_vm->intRam[idx] = (int32_t)val; } break;
        case VM_TYPE_LONG:  if (idx < VM_MAX_LONG_SLOTS) { p_vm->longRam[idx] = val; } break;
        case VM_TYPE_FLOAT: if (idx < VM_MAX_FLOAT_SLOTS) { p_vm->floatRam[idx] = (float)val; } break;
        default:            break;
    }
}

static void write_float(VmInstance_t *p_vm, uint16_t slotId, float val)
{
    uint16_t idx  = slotId & VM_SLOT_INDEX_MASK;
    uint8_t  type = (uint8_t)(slotId >> VM_SLOT_TYPE_SHIFT);
    switch (type) {
        case VM_TYPE_BOOL:  if (idx < VM_MAX_BOOL_SLOTS) { p_vm->boolRam[idx] = (val != 0.0f) ? 1U : 0U; } break;
        case VM_TYPE_INT:   if (idx < VM_MAX_INT_SLOTS) { p_vm->intRam[idx] = (int32_t)val; } break;
        case VM_TYPE_LONG:  if (idx < VM_MAX_LONG_SLOTS) { p_vm->longRam[idx] = (int64_t)val; } break;
        case VM_TYPE_FLOAT: if (idx < VM_MAX_FLOAT_SLOTS) { p_vm->floatRam[idx] = val; } break;
        default:            break;
    }
}

static int64_t days_from_civil(int32_t y, uint32_t m, uint32_t d)
{
    y -= (m <= 2U) ? 1 : 0;
    int64_t era = (y >= 0 ? y : y - 399) / 400;
    uint32_t yoe = (uint32_t)(y - (int32_t)(era * 400));
    uint32_t doy = (153U * (m + (m > 2U ? (uint32_t)-3 : 9U)) + 2U) / 5U + d - 1U;
    uint32_t doe = yoe * 365U + yoe / 4U - yoe / 100U + doy;
    return era * 146097 + (int64_t)doe - 719468;
}

static void civil_from_days(int64_t z, int32_t *p_y, uint32_t *p_m, uint32_t *p_d)
{
    z += 719468;
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    uint32_t doe = (uint32_t)(z - era * 146097);
    uint32_t yoe = (doe - doe / 1460U + doe / 36524U - doe / 146096U) / 365U;
    int64_t y = (int64_t)yoe + era * 400;
    uint32_t doy = doe - (365U * yoe + yoe / 4U - yoe / 100U);
    uint32_t mp = (5U * doy + 2U) / 153U;
    *p_d = doy - (153U * mp + 2U) / 5U + 1U;
    *p_m = mp + (mp < 10U ? 3U : (uint32_t)-9);
    *p_y = (int32_t)(y + (*p_m <= 2U ? 1 : 0));
}

static uint8_t tz_days_in_month(int32_t yr, uint32_t m)
{
    if (m == 2U) {
        bool leap = ((yr % 4) == 0 && ((yr % 100) != 0 || (yr % 400) == 0));
        return leap ? 29U : 28U;
    }
    if (m == 4U || m == 6U || m == 9U || m == 11U) {
        return 30U;
    }
    return 31U;
}

static int64_t tz_transition_local_sec(int32_t yr, uint8_t month, int8_t week, uint8_t dow, uint8_t hour)
{
    uint32_t dim = tz_days_in_month(yr, month);
    int32_t day;
    if (week == 0) {
        day = (int32_t)dow;
        if (day < 1) { day = 1; }
        if (day > (int32_t)dim) { day = (int32_t)dim; }
    } else if (week > 0) {
        int64_t d1 = days_from_civil(yr, month, 1U);
        int32_t firstDow = (int32_t)(((d1 + 4) % 7 + 7) % 7);
        int32_t diff = ((int32_t)dow - firstDow + 7) % 7;
        day = 1 + diff + ((int32_t)week - 1) * 7;
        while (day > (int32_t)dim) { day -= 7; }
    } else {
        int64_t dLast = days_from_civil(yr, month, dim);
        int32_t lastDow = (int32_t)(((dLast + 4) % 7 + 7) % 7);
        int32_t diff = (lastDow - (int32_t)dow + 7) % 7;
        day = (int32_t)dim - diff;
    }
    return days_from_civil(yr, month, (uint32_t)day) * 86400 + (int64_t)hour * 3600;
}

typedef struct {
    int16_t stdOffsetMin;
    int16_t dstOffsetMin;
    uint8_t startMonth;
    int8_t  startWeek;
    uint8_t startDow;
    uint8_t startHour;
    uint8_t endMonth;
    int8_t  endWeek;
    uint8_t endDow;
    uint8_t endHour;
} VmTzRule_t;

static void read_tz_rule(const uint8_t *p_inst, VmTzRule_t *p_rule)
{
    p_rule->stdOffsetMin = (int16_t)read_u16_le(&p_inst[18U]);
    p_rule->dstOffsetMin = (int16_t)read_u16_le(&p_inst[20U]);
    p_rule->startMonth   = p_inst[22U];
    p_rule->startWeek    = (int8_t)p_inst[23U];
    p_rule->startDow     = p_inst[24U];
    p_rule->startHour    = p_inst[25U];
    p_rule->endMonth     = p_inst[26U];
    p_rule->endWeek      = (int8_t)p_inst[27U];
    p_rule->endDow       = p_inst[28U];
    p_rule->endHour      = p_inst[29U];
}

static int64_t tz_offset_sec_at_utc(int64_t utcSec, const VmTzRule_t *p_r)
{
    if (p_r->startMonth == 0U || p_r->endMonth == 0U || p_r->dstOffsetMin == 0) {
        return (int64_t)p_r->stdOffsetMin * 60;
    }
    int64_t stdLocal = utcSec + (int64_t)p_r->stdOffsetMin * 60;
    int64_t stdDays  = (stdLocal >= 0) ? (stdLocal / 86400) : ((stdLocal - 86399) / 86400);
    int32_t yr = 1970;
    uint32_t m = 1U, d = 1U;
    civil_from_days(stdDays, &yr, &m, &d);

    int64_t startUtc = tz_transition_local_sec(yr, p_r->startMonth, p_r->startWeek, p_r->startDow, p_r->startHour)
                       - (int64_t)p_r->stdOffsetMin * 60;
    int64_t endUtc   = tz_transition_local_sec(yr, p_r->endMonth, p_r->endWeek, p_r->endDow, p_r->endHour)
                       - (int64_t)(p_r->stdOffsetMin + p_r->dstOffsetMin) * 60;

    bool isDst = (p_r->startMonth < p_r->endMonth)
                 ? (utcSec >= startUtc && utcSec < endUtc)
                 : (utcSec >= startUtc || utcSec < endUtc);
    return (int64_t)(p_r->stdOffsetMin + (isDst ? p_r->dstOffsetMin : 0)) * 60;
}

static int64_t tz_local_to_utc(int32_t yr, uint32_t mon, uint32_t day, int32_t hr, int32_t min, int32_t sec, const VmTzRule_t *p_r)
{
    int64_t localSec = days_from_civil(yr, mon, day) * 86400 + (int64_t)hr * 3600 + (int64_t)min * 60 + (int64_t)sec;
    if (p_r->startMonth == 0U || p_r->endMonth == 0U || p_r->dstOffsetMin == 0) {
        return localSec - (int64_t)p_r->stdOffsetMin * 60;
    }
    int64_t startWall = tz_transition_local_sec(yr, p_r->startMonth, p_r->startWeek, p_r->startDow, p_r->startHour);
    int64_t endWall   = tz_transition_local_sec(yr, p_r->endMonth, p_r->endWeek, p_r->endDow, p_r->endHour);
    bool isDst = (p_r->startMonth < p_r->endMonth)
                 ? (localSec >= startWall && localSec < endWall)
                 : (localSec >= startWall || localSec < endWall);
    return localSec - (int64_t)(p_r->stdOffsetMin + (isDst ? p_r->dstOffsetMin : 0)) * 60;
}

static void apply_init_table(VmInstance_t *p_vm)
{
    uint32_t offset = p_vm->header.initTableOffset;
    uint32_t count  = p_vm->header.initTableCount;
    for (uint32_t i = 0U; i < count; i++) {
        uint32_t entryOff = offset + (i * VM_INIT_ENTRY_BYTES);
        if ((entryOff + VM_INIT_ENTRY_BYTES) > p_vm->imageSizeBytes) {
            break;
        }
        uint16_t slotId = read_u16_le(&p_vm->imageBuf[entryOff]);
        uint64_t rawVal = read_u64_le(&p_vm->imageBuf[entryOff + 4U]);
        uint8_t  rawBytes[VM_MAX_SLOT_BYTES];
        memcpy(rawBytes, &rawVal, sizeof(rawBytes));
        VM_WriteSlotRaw(p_vm, slotId, rawBytes);
    }
}

static void step_pid(VmInstance_t *p_vm, uint16_t dstSlot, uint16_t pvSlot, uint16_t spSlot,
                     uint16_t kpSlot, uint16_t kiSlot, uint16_t kdSlot, uint16_t rstSlot,
                     uint16_t stateIdx, uint32_t dt_us)
{
    if (stateIdx >= VM_MAX_STATE_SLOTS) {
        return;
    }
    VmStateSlot_t *p_st = &p_vm->stateRam[stateIdx];
    if (read_bool(p_vm, rstSlot) != 0U) {
        p_st->accFloat = 0.0f;
        p_st->auxFloat = 0.0f;
        write_float(p_vm, dstSlot, 0.0f);
        return;
    }

    float dt_s  = (dt_us > 0U) ? ((float)dt_us / 1000000.0f) : 0.01f;
    float error = read_float(p_vm, spSlot) - read_float(p_vm, pvSlot);
    float kp    = read_float(p_vm, kpSlot);
    float ki    = read_float(p_vm, kiSlot);
    float kd    = read_float(p_vm, kdSlot);

    p_st->accFloat += error * dt_s;
    float deriv = (error - p_st->auxFloat) / dt_s;
    p_st->auxFloat = error;

    float outVal = (kp * error) + (ki * p_st->accFloat) + (kd * deriv);
    write_float(p_vm, dstSlot, outVal);
}

uint32_t VM_CalcCrc32(const uint8_t *p_data, uint32_t lenBytes)
{
    if (p_data == NULL) {
        return 0U;
    }
    uint32_t crc = VM_CRC32_INIT;
    for (uint32_t i = 0U; i < lenBytes; i++) {
        crc ^= (uint32_t)p_data[i];
        for (uint8_t bit = 0U; bit < 8U; bit++) {
            if ((crc & 1U) != 0U) {
                crc = (crc >> 1U) ^ VM_CRC32_POLY;
            } else {
                crc >>= 1U;
            }
        }
    }
    return crc ^ VM_CRC32_INIT;
}

VmStatus_t VM_Init(VmInstance_t *p_vm, const VmHalVtable_t *p_hal)
{
    if (p_vm == NULL || p_hal == NULL) {
        return VM_ERR_PARAM;
    }
    memset(p_vm, 0, sizeof(*p_vm));
    p_vm->hal      = *p_hal;
    p_vm->runState = VM_STATE_STOPPED;
    return VM_OK;
}

VmStatus_t VM_LoadImage(VmInstance_t *p_vm, const uint8_t *p_image, uint32_t lenBytes)
{
    if (p_vm == NULL || p_image == NULL) {
        return VM_ERR_PARAM;
    }
    if (lenBytes < VM_HEADER_SIZE_BYTES || lenBytes > VM_MAX_IMAGE_BYTES) {
        return VM_ERR_TOO_LARGE;
    }

    VmImageHeader_t hdr;
    parse_header(p_image, &hdr);
    if (hdr.magic != VM_MAGIC_MFLW) {
        return VM_ERR_BAD_MAGIC;
    }
    if (hdr.formatVersion != VM_FORMAT_VERSION) {
        return VM_ERR_BAD_VERSION;
    }
    if (hdr.imageSizeBytes != lenBytes) {
        return VM_ERR_BAD_CRC;
    }

    uint32_t calcCrc = VM_CalcCrc32(&p_image[VM_HEADER_SIZE_BYTES], lenBytes - VM_HEADER_SIZE_BYTES);
    if (calcCrc != hdr.payloadCrc32) {
        return VM_ERR_BAD_CRC;
    }

    p_vm->runState = VM_STATE_STOPPED;
    if (p_image != p_vm->imageBuf) {
        memcpy(p_vm->imageBuf, p_image, lenBytes);
    }
    p_vm->imageSizeBytes = lenBytes;
    p_vm->header         = hdr;
    p_vm->hasValidImage  = true;

    return VM_Reset(p_vm);
}

VmStatus_t VM_Reset(VmInstance_t *p_vm)
{
    if (p_vm == NULL) {
        return VM_ERR_PARAM;
    }
    memset(p_vm->boolRam, 0, sizeof(p_vm->boolRam));
    memset(p_vm->intRam, 0, sizeof(p_vm->intRam));
    memset(p_vm->longRam, 0, sizeof(p_vm->longRam));
    memset(p_vm->floatRam, 0, sizeof(p_vm->floatRam));
    memset(p_vm->stateRam, 0, sizeof(p_vm->stateRam));
    memset(p_vm->movAvgBuf, 0, sizeof(p_vm->movAvgBuf));
    memset(p_vm->movAvgSum, 0, sizeof(p_vm->movAvgSum));
    memset(p_vm->movAvgHead, 0, sizeof(p_vm->movAvgHead));
    memset(p_vm->movAvgCount, 0, sizeof(p_vm->movAvgCount));
    memset(p_vm->arrayRam, 0, sizeof(p_vm->arrayRam));
    p_vm->rngState      = 0x12345678U;
    p_vm->lastFaultCode = VM_OK;
    p_vm->lastFaultPc   = 0U;
    p_vm->scanCount     = 0U;

    if (p_vm->hasValidImage) {
        apply_init_table(p_vm);
    }
    return VM_OK;
}

VmStatus_t VM_SetState(VmInstance_t *p_vm, VmRunState_t newState)
{
    if (p_vm == NULL) {
        return VM_ERR_PARAM;
    }
    if (newState == VM_STATE_RUNNING && !p_vm->hasValidImage) {
        return VM_ERR_FAULT_BOUNDS;
    }
    p_vm->runState = newState;
    return VM_OK;
}

VmRunState_t VM_GetState(const VmInstance_t *p_vm)
{
    return (p_vm != NULL) ? p_vm->runState : VM_STATE_FAULT;
}

uint8_t VM_GetSlotSize(uint16_t slotId)
{
    uint8_t type = (uint8_t)(slotId >> VM_SLOT_TYPE_SHIFT);
    switch (type) {
        case VM_TYPE_BOOL:  return 1U;
        case VM_TYPE_INT:   return 4U;
        case VM_TYPE_LONG:  return 8U;
        case VM_TYPE_FLOAT: return 4U;
        default:            return 0U;
    }
}

uint8_t VM_ReadSlotRaw(const VmInstance_t *p_vm, uint16_t slotId, uint8_t *p_outBuf)
{
    if (p_vm == NULL || p_outBuf == NULL || !slot_in_bounds(slotId)) {
        return 0U;
    }
    uint16_t idx  = slotId & VM_SLOT_INDEX_MASK;
    uint8_t  type = (uint8_t)(slotId >> VM_SLOT_TYPE_SHIFT);
    switch (type) {
        case VM_TYPE_BOOL:
            p_outBuf[0] = p_vm->boolRam[idx];
            return 1U;
        case VM_TYPE_INT:
            memcpy(p_outBuf, &p_vm->intRam[idx], sizeof(int32_t));
            return 4U;
        case VM_TYPE_LONG:
            memcpy(p_outBuf, &p_vm->longRam[idx], sizeof(int64_t));
            return 8U;
        case VM_TYPE_FLOAT:
            memcpy(p_outBuf, &p_vm->floatRam[idx], sizeof(float));
            return 4U;
        default:
            return 0U;
    }
}

uint8_t VM_WriteSlotRaw(VmInstance_t *p_vm, uint16_t slotId, const uint8_t *p_inBuf)
{
    if (p_vm == NULL || p_inBuf == NULL || !slot_in_bounds(slotId)) {
        return 0U;
    }
    uint16_t idx  = slotId & VM_SLOT_INDEX_MASK;
    uint8_t  type = (uint8_t)(slotId >> VM_SLOT_TYPE_SHIFT);
    switch (type) {
        case VM_TYPE_BOOL:
            p_vm->boolRam[idx] = (p_inBuf[0] != 0U) ? 1U : 0U;
            return 1U;
        case VM_TYPE_INT:
            memcpy(&p_vm->intRam[idx], p_inBuf, sizeof(int32_t));
            return 4U;
        case VM_TYPE_LONG:
            memcpy(&p_vm->longRam[idx], p_inBuf, sizeof(int64_t));
            return 8U;
        case VM_TYPE_FLOAT:
            memcpy(&p_vm->floatRam[idx], p_inBuf, sizeof(float));
            return 4U;
        default:
            return 0U;
    }
}

VmStatus_t VM_StepThread(VmInstance_t *p_vm, uint8_t threadId, uint32_t dt_us)
{
    if (p_vm == NULL || threadId >= VM_THREAD_COUNT) {
        return VM_ERR_PARAM;
    }
    if (!p_vm->hasValidImage || p_vm->runState != VM_STATE_RUNNING) {
        return VM_OK;
    }

    uint32_t pc = p_vm->header.threadOffset[threadId];
    if (pc == 0U || pc >= p_vm->imageSizeBytes) {
        return VM_OK;
    }

    uint32_t start_us = (p_vm->hal.time_micros != NULL) ? p_vm->hal.time_micros() : 0U;
    uint32_t fuel     = VM_MAX_LOOP_FUEL;
    uint32_t dt_ms    = dt_us / 1000U;
    if (dt_ms == 0U && dt_us > 0U) {
        dt_ms = 1U;
    }

    while ((pc + 8U) <= p_vm->imageSizeBytes) {
        uint8_t  opcode = p_vm->imageBuf[pc];
        uint8_t  flags  = p_vm->imageBuf[pc + 1U];
        uint16_t enSlot = read_u16_le(&p_vm->imageBuf[pc + 2U]);
        uint16_t dst    = read_u16_le(&p_vm->imageBuf[pc + 4U]);
        uint16_t srcA   = read_u16_le(&p_vm->imageBuf[pc + 6U]);

        if (opcode == VM_OP_HALT) {
            break;
        }
        if (opcode == VM_OP_NOP) {
            pc += 8U;
            continue;
        }

        // Fixed word counts per instruction format
        uint32_t nextPc = pc + 8U;
        bool     enabled = (enSlot == VM_SLOT_ALWAYS_ENABLED) || (read_bool(p_vm, enSlot) != 0U);

        switch (opcode) {
            case VM_OP_ESTOP_CHECK: {
                nextPc = pc + 16U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t tripSlot = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t srcSlot  = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 12U]);
                if (stateIdx < VM_MAX_STATE_SLOTS) {
                    uint8_t rst     = enabled ? read_bool(p_vm, srcA) : 0U;
                    uint8_t prevRst = p_vm->stateRam[stateIdx].prevBool;
                    p_vm->stateRam[stateIdx].prevBool = rst;
                    if (rst != 0U && prevRst == 0U && p_vm->estopActive != 0U) {
                        p_vm->estopActive = 0U;
                        p_vm->estopMask   = 0U;
                        if (p_vm->runState == VM_STATE_ESTOP) {
                            p_vm->runState = VM_STATE_RUNNING;
                        }
                    }
                }
                uint8_t tripped = (p_vm->estopActive != 0U) ? 1U : 0U;
                write_bool(p_vm, dst, tripped ? 0U : 1U);
                if (tripSlot != VM_SLOT_ALWAYS_ENABLED) {
                    write_bool(p_vm, tripSlot, tripped);
                }
                if (srcSlot != VM_SLOT_ALWAYS_ENABLED) {
                    write_int(p_vm, srcSlot, (int32_t)p_vm->estopMask);
                }
                break;
            }
            case VM_OP_JMP: {
                int16_t relBytes = (int16_t)srcA;
                if (relBytes <= 0) {
                    if (fuel == 0U) {
                        p_vm->lastFaultCode = VM_ERR_FAULT_FUEL;
                        p_vm->lastFaultPc   = (uint16_t)pc;
                        p_vm->runState      = VM_STATE_FAULT;
                        return VM_ERR_FAULT_FUEL;
                    }
                    fuel--;
                }
                nextPc = (uint32_t)((int32_t)pc + (int32_t)relBytes);
                break;
            }
            case VM_OP_JMP_FALSE: {
                int16_t relBytes = (int16_t)srcA;
                if (read_bool(p_vm, dst) == 0U) {
                    if (relBytes <= 0) {
                        if (fuel == 0U) {
                            p_vm->lastFaultCode = VM_ERR_FAULT_FUEL;
                            p_vm->lastFaultPc   = (uint16_t)pc;
                            p_vm->runState      = VM_STATE_FAULT;
                            return VM_ERR_FAULT_FUEL;
                        }
                        fuel--;
                    }
                    nextPc = (uint32_t)((int32_t)pc + (int32_t)relBytes);
                }
                break;
            }
            case VM_OP_MOV:
            case VM_OP_CAST: {
                if (enabled) {
                    uint8_t dstType = (uint8_t)(dst >> VM_SLOT_TYPE_SHIFT);
                    if (dstType == VM_TYPE_BOOL)       { write_bool(p_vm, dst, read_bool(p_vm, srcA)); }
                    else if (dstType == VM_TYPE_INT)   { write_int(p_vm, dst, read_int(p_vm, srcA)); }
                    else if (dstType == VM_TYPE_LONG)  { write_long(p_vm, dst, read_long(p_vm, srcA)); }
                    else                               { write_float(p_vm, dst, read_float(p_vm, srcA)); }
                }
                break;
            }
            case VM_OP_PACK8: {
                nextPc = pc + 24U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                if (enabled) {
                    uint8_t packed = 0U;
                    for (uint8_t i = 0U; i < 8U; i++) {
                        uint16_t bSlot = (i == 0U) ? srcA : read_u16_le(&p_vm->imageBuf[pc + 6U + ((uint32_t)i * 2U)]);
                        if (read_bool(p_vm, bSlot) != 0U) {
                            uint8_t bitIdx = (flags != 0U) ? (uint8_t)(7U - i) : i;
                            packed |= (uint8_t)(1U << bitIdx);
                        }
                    }
                    write_int(p_vm, dst, (int32_t)packed);
                }
                break;
            }
            case VM_OP_UNPACK8: {
                nextPc = pc + 24U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                if (enabled) {
                    uint32_t val = (uint32_t)read_int(p_vm, srcA);
                    for (uint8_t i = 0U; i < 8U; i++) {
                        uint16_t bSlot = (i == 0U) ? dst : read_u16_le(&p_vm->imageBuf[pc + 6U + ((uint32_t)i * 2U)]);
                        uint8_t bitIdx = (flags != 0U) ? (uint8_t)(7U - i) : i;
                        write_bool(p_vm, bSlot, ((val >> bitIdx) & 1U) ? 1U : 0U);
                    }
                }
                break;
            }
            case VM_OP_NOT: {
                if (enabled) {
                    write_bool(p_vm, dst, (read_bool(p_vm, srcA) == 0U) ? 1U : 0U);
                }
                break;
            }
            case VM_OP_AND:
            case VM_OP_NAND:
            case VM_OP_OR:
            case VM_OP_NOR:
            case VM_OP_XOR:
            case VM_OP_XNOR: {
                // Word 2 holds srcB + optional extra slots based on flags (input count)
                uint8_t argc = (flags >= 2U) ? flags : 2U;
                uint32_t extraWords = (uint32_t)((argc - 1U + 1U) / 2U);
                nextPc = pc + 8U + (extraWords * 4U);
                if (nextPc > p_vm->imageSizeBytes) { break; }
                if (enabled) {
                    uint8_t acc = read_bool(p_vm, srcA);
                    for (uint8_t k = 1U; k < argc; k++) {
                        uint16_t s = read_u16_le(&p_vm->imageBuf[pc + 8U + ((uint32_t)(k - 1U) * 2U)]);
                        uint8_t  v = read_bool(p_vm, s);
                        if (opcode == VM_OP_AND || opcode == VM_OP_NAND)      { acc &= v; }
                        else if (opcode == VM_OP_OR || opcode == VM_OP_NOR)   { acc |= v; }
                        else                                                  { acc ^= v; }
                    }
                    if (opcode == VM_OP_NAND || opcode == VM_OP_NOR || opcode == VM_OP_XNOR) {
                        acc = (acc == 0U) ? 1U : 0U;
                    }
                    write_bool(p_vm, dst, acc);
                }
                break;
            }
            case VM_OP_RS:
            case VM_OP_SR: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t rSlot    = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t nqSlot   = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                if (enabled) {
                    uint8_t sVal = read_bool(p_vm, srcA);
                    uint8_t rVal = read_bool(p_vm, rSlot);
                    uint8_t qVal = read_bool(p_vm, dst);
                    if (opcode == VM_OP_RS) {
                        if (rVal != 0U)      { qVal = 0U; }
                        else if (sVal != 0U) { qVal = 1U; }
                    } else {
                        if (sVal != 0U)      { qVal = 1U; }
                        else if (rVal != 0U) { qVal = 0U; }
                    }
                    write_bool(p_vm, dst, qVal);
                    if (nqSlot != VM_SLOT_ALWAYS_ENABLED) {
                        write_bool(p_vm, nqSlot, (qVal == 0U) ? 1U : 0U);
                    }
                }
                break;
            }
            case VM_OP_LD_CONTACT: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint8_t  opVal    = read_bool(p_vm, srcA);
                uint8_t  pass     = 0U;
                if (flags == VM_LD_CONTACT_NO) {
                    pass = opVal;
                } else if (flags == VM_LD_CONTACT_NC) {
                    pass = (opVal == 0U) ? 1U : 0U;
                } else if (stateIdx < VM_MAX_STATE_SLOTS) {
                    uint8_t prev = p_vm->stateRam[stateIdx].prevBool;
                    p_vm->stateRam[stateIdx].prevBool = opVal;
                    pass = (flags == VM_LD_CONTACT_POS) ? ((opVal != 0U && prev == 0U) ? 1U : 0U)
                                                        : ((opVal == 0U && prev != 0U) ? 1U : 0U);
                }
                write_bool(p_vm, dst, (enabled && pass != 0U) ? 1U : 0U);
                break;
            }
            case VM_OP_LD_COIL: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint8_t  pwr      = enabled ? 1U : 0U;
                if (flags == VM_LD_COIL_NORMAL) {
                    write_bool(p_vm, dst, pwr);
                } else if (flags == VM_LD_COIL_NEGATED) {
                    write_bool(p_vm, dst, (pwr == 0U) ? 1U : 0U);
                } else if (flags == VM_LD_COIL_SET && pwr != 0U) {
                    write_bool(p_vm, dst, 1U);
                } else if (flags == VM_LD_COIL_RESET && pwr != 0U) {
                    write_bool(p_vm, dst, 0U);
                } else if ((flags == VM_LD_COIL_POS || flags == VM_LD_COIL_NEG) && stateIdx < VM_MAX_STATE_SLOTS) {
                    uint8_t prev = p_vm->stateRam[stateIdx].prevBool;
                    p_vm->stateRam[stateIdx].prevBool = pwr;
                    uint8_t pulse = (flags == VM_LD_COIL_POS) ? ((pwr != 0U && prev == 0U) ? 1U : 0U)
                                                               : ((pwr == 0U && prev != 0U) ? 1U : 0U);
                    write_bool(p_vm, dst, pulse);
                }
                break;
            }
            case VM_OP_ADD:
            case VM_OP_SUB:
            case VM_OP_MUL:
            case VM_OP_MIN:
            case VM_OP_MAX: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t srcB = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                if (enabled) {
                    uint8_t dstType = (uint8_t)(dst >> VM_SLOT_TYPE_SHIFT);
                    if (dstType == VM_TYPE_FLOAT) {
                        float a = read_float(p_vm, srcA);
                        float b = read_float(p_vm, srcB);
                        float r = 0.0f;
                        if (opcode == VM_OP_ADD)      { r = a + b; }
                        else if (opcode == VM_OP_SUB) { r = a - b; }
                        else if (opcode == VM_OP_MUL) { r = a * b; }
                        else if (opcode == VM_OP_MIN) { r = (a < b) ? a : b; }
                        else                          { r = (a > b) ? a : b; }
                        write_float(p_vm, dst, r);
                    } else if (dstType == VM_TYPE_LONG) {
                        int64_t a = read_long(p_vm, srcA);
                        int64_t b = read_long(p_vm, srcB);
                        int64_t r = 0;
                        if (opcode == VM_OP_ADD)      { r = a + b; }
                        else if (opcode == VM_OP_SUB) { r = a - b; }
                        else if (opcode == VM_OP_MUL) { r = a * b; }
                        else if (opcode == VM_OP_MIN) { r = (a < b) ? a : b; }
                        else                          { r = (a > b) ? a : b; }
                        write_long(p_vm, dst, r);
                    } else {
                        int32_t a = read_int(p_vm, srcA);
                        int32_t b = read_int(p_vm, srcB);
                        int32_t r = 0;
                        if (opcode == VM_OP_ADD)      { r = a + b; }
                        else if (opcode == VM_OP_SUB) { r = a - b; }
                        else if (opcode == VM_OP_MUL) { r = a * b; }
                        else if (opcode == VM_OP_MIN) { r = (a < b) ? a : b; }
                        else                          { r = (a > b) ? a : b; }
                        write_int(p_vm, dst, r);
                    }
                }
                break;
            }
            case VM_OP_DIV:
            case VM_OP_MOD: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t srcB    = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t errSlot = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                if (enabled) {
                    uint8_t dstType = (uint8_t)(dst >> VM_SLOT_TYPE_SHIFT);
                    if (dstType == VM_TYPE_FLOAT) {
                        float a = read_float(p_vm, srcA);
                        float b = read_float(p_vm, srcB);
                        if (fabsf(b) < 1e-12f) {
                            write_float(p_vm, dst, 0.0f);
                            if (errSlot != VM_SLOT_ALWAYS_ENABLED) { write_bool(p_vm, errSlot, 1U); }
                        } else {
                            write_float(p_vm, dst, (opcode == VM_OP_DIV) ? (a / b) : fmodf(a, b));
                            if (errSlot != VM_SLOT_ALWAYS_ENABLED) { write_bool(p_vm, errSlot, 0U); }
                        }
                    } else if (dstType == VM_TYPE_LONG) {
                        int64_t b = read_long(p_vm, srcB);
                        if (b == 0) {
                            write_long(p_vm, dst, 0);
                            if (errSlot != VM_SLOT_ALWAYS_ENABLED) { write_bool(p_vm, errSlot, 1U); }
                        } else {
                            int64_t a = read_long(p_vm, srcA);
                            write_long(p_vm, dst, (opcode == VM_OP_DIV) ? (a / b) : (a % b));
                            if (errSlot != VM_SLOT_ALWAYS_ENABLED) { write_bool(p_vm, errSlot, 0U); }
                        }
                    } else {
                        int32_t b = read_int(p_vm, srcB);
                        if (b == 0) {
                            write_int(p_vm, dst, 0);
                            if (errSlot != VM_SLOT_ALWAYS_ENABLED) { write_bool(p_vm, errSlot, 1U); }
                        } else {
                            int32_t a = read_int(p_vm, srcA);
                            write_int(p_vm, dst, (opcode == VM_OP_DIV) ? (a / b) : (a % b));
                            if (errSlot != VM_SLOT_ALWAYS_ENABLED) { write_bool(p_vm, errSlot, 0U); }
                        }
                    }
                }
                break;
            }
            case VM_OP_ABS:
            case VM_OP_NEG:
            case VM_OP_SQRT:
            case VM_OP_SIN:
            case VM_OP_COS: {
                if (enabled) {
                    float a = read_float(p_vm, srcA);
                    float r = a;
                    if (opcode == VM_OP_ABS)       { r = fabsf(a); }
                    else if (opcode == VM_OP_NEG)  { r = -a; }
                    else if (opcode == VM_OP_SQRT) { r = (a >= 0.0f) ? sqrtf(a) : 0.0f; }
                    else if (opcode == VM_OP_SIN)  { r = sinf(a); }
                    else                           { r = cosf(a); }
                    write_float(p_vm, dst, r);
                }
                break;
            }
            case VM_OP_CLAMP: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t minSlot = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t maxSlot = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                if (enabled) {
                    float v  = read_float(p_vm, srcA);
                    float a  = read_float(p_vm, minSlot);
                    float b  = read_float(p_vm, maxSlot);
                    float lo = (a < b) ? a : b;
                    float hi = (a > b) ? a : b;
                    if (v < lo)      { v = lo; }
                    else if (v > hi) { v = hi; }
                    write_float(p_vm, dst, v);
                }
                break;
            }
            case VM_OP_SCALE: {
                nextPc = pc + 16U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t iLoSlot = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t iHiSlot = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                uint16_t oLoSlot = read_u16_le(&p_vm->imageBuf[pc + 12U]);
                uint16_t oHiSlot = read_u16_le(&p_vm->imageBuf[pc + 14U]);
                if (enabled) {
                    float inVal = read_float(p_vm, srcA);
                    float iLo   = read_float(p_vm, iLoSlot);
                    float iHi   = read_float(p_vm, iHiSlot);
                    float oLo   = read_float(p_vm, oLoSlot);
                    float oHi   = read_float(p_vm, oHiSlot);
                    float span  = iHi - iLo;
                    float res   = (fabsf(span) < 1e-12f) ? oLo : (oLo + ((inVal - iLo) / span) * (oHi - oLo));
                    write_float(p_vm, dst, res);
                }
                break;
            }
            case VM_OP_RANDOM: {
                nextPc = pc + 16U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t minSlot  = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t maxSlot  = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 12U]);
                if (enabled && stateIdx < VM_MAX_STATE_SLOTS) {
                    VmStateSlot_t *p_st = &p_vm->stateRam[stateIdx];
                    uint8_t trig     = read_bool(p_vm, srcA);
                    uint8_t prevTrig = p_st->prevBool;
                    p_st->prevBool   = trig;
                    if ((trig != 0U && prevTrig == 0U) || (p_st->prevAuxBool == 0U)) {
                        float lo     = read_float(p_vm, minSlot);
                        float hi     = read_float(p_vm, maxSlot);
                        float minVal = (lo < hi) ? lo : hi;
                        float maxVal = (lo > hi) ? lo : hi;
                        uint32_t rnd;
                        if (p_vm->hal.rng_next != NULL) {
                            rnd = p_vm->hal.rng_next();
                        } else {
                            uint32_t x = p_vm->rngState;
                            if (x == 0U) { x = 0x12345678U; }
                            x ^= x << 13;
                            x ^= x >> 17;
                            x ^= x << 5;
                            p_vm->rngState = x;
                            rnd = x;
                        }
                        uint8_t dstType = (uint8_t)(dst >> VM_SLOT_TYPE_SHIFT);
                        if (dstType == VM_TYPE_FLOAT) {
                            float unit = (float)rnd / 4294967295.0f;
                            p_st->accFloat = minVal + unit * (maxVal - minVal);
                        } else {
                            int64_t minI = (int64_t)floorf(minVal);
                            int64_t maxI = (int64_t)floorf(maxVal);
                            int64_t rVal = (maxI <= minI) ? minI : (minI + (int64_t)(rnd % (uint32_t)(maxI - minI + 1)));
                            p_st->accFloat = (float)rVal;
                        }
                        p_st->prevAuxBool = 1U;
                    }
                    write_float(p_vm, dst, p_st->accFloat);
                }
                break;
            }
            case VM_OP_PID: {
                nextPc = pc + 20U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                if (enabled) {
                    uint16_t spSlot   = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                    uint16_t kpSlot   = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                    uint16_t kiSlot   = read_u16_le(&p_vm->imageBuf[pc + 12U]);
                    uint16_t kdSlot   = read_u16_le(&p_vm->imageBuf[pc + 14U]);
                    uint16_t rstSlot  = read_u16_le(&p_vm->imageBuf[pc + 16U]);
                    uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 18U]);
                    step_pid(p_vm, dst, srcA, spSlot, kpSlot, kiSlot, kdSlot, rstSlot, stateIdx, dt_us);
                }
                break;
            }
            case VM_OP_LOWPASS: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t alpSlot  = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                if (enabled && stateIdx < VM_MAX_STATE_SLOTS) {
                    VmStateSlot_t *p_st = &p_vm->stateRam[stateIdx];
                    float inVal = read_float(p_vm, srcA);
                    float alpha = read_float(p_vm, alpSlot);
                    if (alpha < 0.0f) { alpha = 0.0f; } else if (alpha > 1.0f) { alpha = 1.0f; }
                    float y;
                    if (p_st->prevBool == 0U) {
                        y = inVal;
                        p_st->prevBool = 1U;
                    } else {
                        y = p_st->accFloat + alpha * (inVal - p_st->accFloat);
                    }
                    p_st->accFloat = y;
                    write_float(p_vm, dst, y);
                }
                break;
            }
            case VM_OP_MOVING_AVG: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t rstSlot = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t maIdx   = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                if (enabled && maIdx < VM_MAX_MOVAVG_INSTANCES) {
                    uint8_t winSize = flags;
                    if (winSize < 1U) { winSize = 1U; }
                    if (winSize > VM_MOVAVG_MAX_WIN) { winSize = VM_MOVAVG_MAX_WIN; }
                    float inVal = read_float(p_vm, srcA);
                    if (read_bool(p_vm, rstSlot) != 0U) {
                        p_vm->movAvgSum[maIdx]   = 0.0f;
                        p_vm->movAvgHead[maIdx]  = 0U;
                        p_vm->movAvgCount[maIdx] = 0U;
                    }
                    uint8_t head  = p_vm->movAvgHead[maIdx];
                    uint8_t count = p_vm->movAvgCount[maIdx];
                    if (count == winSize) {
                        p_vm->movAvgSum[maIdx] -= p_vm->movAvgBuf[maIdx][head];
                    } else {
                        count++;
                        p_vm->movAvgCount[maIdx] = count;
                    }
                    p_vm->movAvgBuf[maIdx][head] = inVal;
                    p_vm->movAvgSum[maIdx]      += inVal;
                    p_vm->movAvgHead[maIdx]      = (uint8_t)((head + 1U) % winSize);
                    write_float(p_vm, dst, (count > 0U) ? (p_vm->movAvgSum[maIdx] / (float)count) : inVal);
                }
                break;
            }
            case VM_OP_DEBOUNCE: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t tmsSlot  = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                if (enabled && stateIdx < VM_MAX_STATE_SLOTS) {
                    VmStateSlot_t *p_st = &p_vm->stateRam[stateIdx];
                    uint8_t inVal = read_bool(p_vm, srcA);
                    int32_t tMs   = read_int(p_vm, tmsSlot);
                    if (tMs < 0) { tMs = 0; }
                    if (inVal != p_st->latchedBool) {
                        p_st->timer_ms += dt_ms;
                        if (p_st->timer_ms >= (uint32_t)tMs) {
                            p_st->latchedBool = inVal;
                            p_st->timer_ms    = 0U;
                        }
                    } else {
                        p_st->timer_ms = 0U;
                    }
                    write_bool(p_vm, dst, p_st->latchedBool);
                }
                break;
            }
            case VM_OP_RET_READ: {
                if (enabled && p_vm->hal.retentive_read != NULL) {
                    uint64_t raw = p_vm->hal.retentive_read(srcA);
                    uint8_t dstType = (uint8_t)(dst >> VM_SLOT_TYPE_SHIFT);
                    if (dstType == VM_TYPE_BOOL)       { write_bool(p_vm, dst, (raw != 0ULL) ? 1U : 0U); }
                    else if (dstType == VM_TYPE_INT)   { write_int(p_vm, dst, (int32_t)(uint32_t)raw); }
                    else if (dstType == VM_TYPE_LONG)  { write_long(p_vm, dst, (int64_t)raw); }
                    else {
                        uint32_t fBits = (uint32_t)raw;
                        float fv = 0.0f;
                        memcpy(&fv, &fBits, sizeof(fv));
                        write_float(p_vm, dst, fv);
                    }
                }
                break;
            }
            case VM_OP_RET_WRITE: {
                if (enabled && p_vm->hal.retentive_write != NULL) {
                    uint64_t raw = 0ULL;
                    uint8_t srcType = (uint8_t)(dst >> VM_SLOT_TYPE_SHIFT);
                    if (srcType == VM_TYPE_BOOL)       { raw = (uint64_t)read_bool(p_vm, dst); }
                    else if (srcType == VM_TYPE_INT)   { raw = (uint64_t)(uint32_t)read_int(p_vm, dst); }
                    else if (srcType == VM_TYPE_LONG)  { raw = (uint64_t)read_long(p_vm, dst); }
                    else {
                        float fv = read_float(p_vm, dst);
                        uint32_t fBits = 0U;
                        memcpy(&fBits, &fv, sizeof(fBits));
                        raw = (uint64_t)fBits;
                    }
                    p_vm->hal.retentive_write(srcA, raw);
                }
                break;
            }
            case VM_OP_ARRAY_READ: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t oobSlot = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                if (enabled) {
                    uint8_t arrIdx = flags;
                    int32_t elemIdx = read_int(p_vm, srcA);
                    bool oob = (arrIdx >= VM_MAX_ARRAYS) || (elemIdx < 0) || ((uint32_t)elemIdx >= VM_ARRAY_LEN);
                    if (oob) {
                        write_float(p_vm, dst, 0.0f);
                    } else {
                        write_float(p_vm, dst, p_vm->arrayRam[arrIdx][elemIdx]);
                    }
                    if (oobSlot != VM_SLOT_ALWAYS_ENABLED) {
                        write_bool(p_vm, oobSlot, oob ? 1U : 0U);
                    }
                }
                break;
            }
            case VM_OP_ARRAY_WRITE: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t valSlot = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                if (enabled) {
                    uint8_t arrIdx = flags;
                    int32_t elemIdx = read_int(p_vm, srcA);
                    bool oob = (arrIdx >= VM_MAX_ARRAYS) || (elemIdx < 0) || ((uint32_t)elemIdx >= VM_ARRAY_LEN);
                    if (!oob) {
                        p_vm->arrayRam[arrIdx][elemIdx] = read_float(p_vm, valSlot);
                    }
                    if (dst != VM_SLOT_ALWAYS_ENABLED) {
                        write_bool(p_vm, dst, oob ? 1U : 0U);
                    }
                }
                break;
            }
            case VM_OP_INT_CAPTURE: {
                nextPc = pc + 16U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t flgSlot  = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t diChan   = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 12U]);
                if (enabled && stateIdx < VM_MAX_STATE_SLOTS) {
                    VmStateSlot_t *p_st = &p_vm->stateRam[stateIdx];
                    uint8_t capMode   = (uint8_t)(flags & 0x03U);       // 0=PULSE_WIDTH_US, 1=EDGE_COUNT, 2=GPIO_STATE
                    uint8_t edgeMode  = (uint8_t)((flags >> 2U) & 0x03U); // 0=RISING, 1=FALLING, 2=BOTH
                    uint8_t overwrite = (uint8_t)((flags >> 4U) & 0x01U); // 1=OVERWRITE_LATEST

                    bool triggered = false;
                    float captured = 0.0f;
                    if (diChan != 0xFFFFU && p_vm->hal.di_read != NULL) {
                        uint8_t cur  = p_vm->hal.di_read(diChan);
                        uint8_t prev = p_st->prevBool;
                        p_st->prevBool = cur;
                        bool rising  = (cur != 0U && prev == 0U);
                        bool falling = (cur == 0U && prev != 0U);
                        if ((edgeMode == 0U && rising) || (edgeMode == 1U && falling) || (edgeMode == 2U && (rising || falling))) {
                            triggered = true;
                            if (capMode == 2U) { captured = (float)cur; }
                        }
                    }
                    if (triggered) {
                        if (capMode == 1U) {
                            p_st->accFloat += 1.0f;
                            p_st->latchedBool = 1U;
                        } else if (p_st->latchedBool == 0U || overwrite != 0U) {
                            p_st->accFloat = captured;
                            p_st->latchedBool = 1U;
                        }
                    }
                    write_float(p_vm, dst, p_st->accFloat);
                    if (flgSlot != VM_SLOT_ALWAYS_ENABLED) {
                        write_bool(p_vm, flgSlot, p_st->latchedBool);
                    }
                    if (read_bool(p_vm, srcA) != 0U && p_st->latchedBool != 0U) {
                        p_st->latchedBool = 0U;
                        if (capMode == 1U) { p_st->accFloat = 0.0f; }
                    }
                }
                break;
            }
            case VM_OP_CMP_EQ:
            case VM_OP_CMP_NE:
            case VM_OP_CMP_GT:
            case VM_OP_CMP_GE:
            case VM_OP_CMP_LT:
            case VM_OP_CMP_LE: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t srcB = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                if (enabled) {
                    float a = read_float(p_vm, srcA);
                    float b = read_float(p_vm, srcB);
                    bool  res = false;
                    if (opcode == VM_OP_CMP_EQ)      { res = (a == b); }
                    else if (opcode == VM_OP_CMP_NE) { res = (a != b); }
                    else if (opcode == VM_OP_CMP_GT) { res = (a > b); }
                    else if (opcode == VM_OP_CMP_GE) { res = (a >= b); }
                    else if (opcode == VM_OP_CMP_LT) { res = (a < b); }
                    else                             { res = (a <= b); }
                    write_bool(p_vm, dst, res ? 1U : 0U);
                }
                break;
            }
            case VM_OP_IN_RANGE: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t minSlot = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t maxSlot = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                if (enabled) {
                    float v  = read_float(p_vm, srcA);
                    float a  = read_float(p_vm, minSlot);
                    float b  = read_float(p_vm, maxSlot);
                    float lo = (a < b) ? a : b;
                    float hi = (a > b) ? a : b;
                    write_bool(p_vm, dst, (v >= lo && v <= hi) ? 1U : 0U);
                }
                break;
            }
            case VM_OP_HYSTERESIS: {
                nextPc = pc + 16U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t loSlot   = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t hiSlot   = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 12U]);
                if (enabled && stateIdx < VM_MAX_STATE_SLOTS) {
                    VmStateSlot_t *p_st = &p_vm->stateRam[stateIdx];
                    float v  = read_float(p_vm, srcA);
                    float lo = read_float(p_vm, loSlot);
                    float hi = read_float(p_vm, hiSlot);
                    if (v >= hi)      { p_st->latchedBool = 1U; }
                    else if (v <= lo) { p_st->latchedBool = 0U; }
                    write_bool(p_vm, dst, p_st->latchedBool);
                }
                break;
            }
            case VM_OP_SEL: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t x0Slot = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t x1Slot = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                if (enabled) {
                    uint16_t chosen = (read_bool(p_vm, srcA) != 0U) ? x1Slot : x0Slot;
                    write_float(p_vm, dst, read_float(p_vm, chosen));
                }
                break;
            }
            case VM_OP_TON: {
                nextPc = pc + 16U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t ptSlot   = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t etSlot   = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 12U]);
                if (stateIdx < VM_MAX_STATE_SLOTS) {
                    VmStateSlot_t *p_st = &p_vm->stateRam[stateIdx];
                    int32_t pt_ms = read_int(p_vm, ptSlot);
                    if (pt_ms < 0) { pt_ms = 0; }
                    uint8_t inVal = (enabled && read_bool(p_vm, srcA) != 0U) ? 1U : 0U;
                    uint8_t qOut  = 0U;

                    if (flags == 1U) {
                        // TOF (Off-Delay)
                        if (enabled) {
                            if (inVal != 0U) {
                                p_st->timer_ms = 0U;
                            } else if (p_st->timer_ms < (uint32_t)pt_ms) {
                                p_st->timer_ms += dt_ms;
                                if (p_st->timer_ms > (uint32_t)pt_ms) {
                                    p_st->timer_ms = (uint32_t)pt_ms;
                                }
                            }
                            qOut = (inVal != 0U || p_st->timer_ms < (uint32_t)pt_ms) ? 1U : 0U;
                        } else {
                            p_st->timer_ms = (uint32_t)pt_ms;
                            qOut = 0U;
                        }
                    } else if (flags == 2U) {
                        // TP (Pulse)
                        uint8_t prevIn = p_st->prevBool;
                        p_st->prevBool = inVal;
                        if (enabled) {
                            if (p_st->latchedBool == 0U && inVal != 0U && prevIn == 0U) {
                                p_st->latchedBool = 1U;
                                p_st->timer_ms    = 0U;
                            }
                            if (p_st->latchedBool != 0U) {
                                p_st->timer_ms += dt_ms;
                                if (p_st->timer_ms >= (uint32_t)pt_ms) {
                                    p_st->latchedBool = 0U;
                                    p_st->timer_ms    = (uint32_t)pt_ms;
                                }
                            }
                            qOut = p_st->latchedBool;
                        } else {
                            p_st->latchedBool = 0U;
                            p_st->timer_ms    = 0U;
                            qOut = 0U;
                        }
                    } else {
                        // TON (On-Delay)
                        if (inVal != 0U) {
                            p_st->timer_ms += dt_ms;
                            if (p_st->timer_ms >= (uint32_t)pt_ms) {
                                p_st->timer_ms = (uint32_t)pt_ms;
                                qOut = 1U;
                            }
                        } else {
                            p_st->timer_ms = 0U;
                        }
                    }
                    write_bool(p_vm, dst, qOut);
                    if (etSlot != VM_SLOT_ALWAYS_ENABLED) {
                        write_int(p_vm, etSlot, (int32_t)p_st->timer_ms);
                    }
                }
                break;
            }
            case VM_OP_PULSE_GEN: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t tLoSlot  = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                if (stateIdx < VM_MAX_STATE_SLOTS) {
                    VmStateSlot_t *p_st = &p_vm->stateRam[stateIdx];
                    if (enabled) {
                        int32_t tHi = read_int(p_vm, srcA);
                        int32_t tLo = read_int(p_vm, tLoSlot);
                        if (tHi < 1) { tHi = 1; }
                        if (tLo < 1) { tLo = 1; }
                        uint64_t cycle = (uint64_t)(uint32_t)tHi + (uint64_t)(uint32_t)tLo;
                        uint32_t pos = (uint32_t)(((uint64_t)p_st->timer_ms + (uint64_t)dt_ms) % cycle);
                        p_st->timer_ms = pos;
                        write_bool(p_vm, dst, (pos < (uint32_t)tHi) ? 1U : 0U);
                    } else {
                        p_st->timer_ms = 0U;
                        write_bool(p_vm, dst, 0U);
                    }
                }
                break;
            }
            case VM_OP_PULSE_LEN: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t lenSlot  = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                if (stateIdx < VM_MAX_STATE_SLOTS) {
                    VmStateSlot_t *p_st = &p_vm->stateRam[stateIdx];
                    uint8_t inVal  = (enabled && read_bool(p_vm, srcA) != 0U) ? 1U : 0U;
                    uint8_t prevIn = p_st->prevBool;
                    p_st->prevBool = inVal;
                    if (enabled) {
                        int32_t lenMs = read_int(p_vm, lenSlot);
                        if (lenMs < 0) { lenMs = 0; }
                        if (p_st->latchedBool == 0U && inVal != 0U && prevIn == 0U) {
                            p_st->latchedBool = 1U;
                            p_st->timer_ms    = 0U;
                        }
                        if (p_st->latchedBool != 0U) {
                            p_st->timer_ms += dt_ms;
                            if (p_st->timer_ms >= (uint32_t)lenMs) {
                                p_st->latchedBool = 0U;
                                p_st->timer_ms    = (uint32_t)lenMs;
                            }
                        }
                        write_bool(p_vm, dst, p_st->latchedBool);
                    } else {
                        p_st->latchedBool = 0U;
                        p_st->timer_ms    = 0U;
                        write_bool(p_vm, dst, 0U);
                    }
                }
                break;
            }
            case VM_OP_ONE_SHOT: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                if (stateIdx < VM_MAX_STATE_SLOTS) {
                    uint8_t cur  = enabled ? read_bool(p_vm, srcA) : 0U;
                    uint8_t prev = p_vm->stateRam[stateIdx].prevBool;
                    p_vm->stateRam[stateIdx].prevBool = cur;
                    write_bool(p_vm, dst, (cur != 0U && prev == 0U) ? 1U : 0U);
                }
                break;
            }
            case VM_OP_CTUD: {
                nextPc = pc + 20U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t cdSlot   = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t rSlot    = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                uint16_t pvSlot   = read_u16_le(&p_vm->imageBuf[pc + 12U]);
                uint16_t cvSlot   = read_u16_le(&p_vm->imageBuf[pc + 14U]);
                uint16_t stateIdx = read_u16_le(&p_vm->imageBuf[pc + 16U]);
                if (enabled && stateIdx < VM_MAX_STATE_SLOTS) {
                    VmStateSlot_t *p_st = &p_vm->stateRam[stateIdx];
                    uint8_t cu = read_bool(p_vm, srcA);
                    uint8_t cd = read_bool(p_vm, cdSlot);
                    bool cuEdge = (cu != 0U && p_st->prevBool == 0U);
                    bool cdEdge = (cd != 0U && p_st->prevAuxBool == 0U);
                    p_st->prevBool    = cu;
                    p_st->prevAuxBool = cd;

                    int32_t cv = read_int(p_vm, cvSlot);
                    int32_t pv = read_int(p_vm, pvSlot);
                    if (read_bool(p_vm, rSlot) != 0U) {
                        cv = 0;
                    } else {
                        if (cuEdge) { cv++; }
                        if (cdEdge && cv > 0) { cv--; }
                    }
                    write_int(p_vm, cvSlot, cv);
                    write_bool(p_vm, dst, (cv >= pv) ? 1U : 0U);
                }
                break;
            }
            case VM_OP_RTC_GET: {
                if (enabled) {
                    int64_t ts = (p_vm->hal.rtc_unix_sec != NULL) ? p_vm->hal.rtc_unix_sec() : 0;
                    write_long(p_vm, dst, ts);
                }
                break;
            }
            case VM_OP_DECODE_DATE: {
                nextPc = pc + 32U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                if (enabled) {
                    uint16_t monSlot = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                    uint16_t daySlot = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                    uint16_t hrSlot  = read_u16_le(&p_vm->imageBuf[pc + 12U]);
                    uint16_t minSlot = read_u16_le(&p_vm->imageBuf[pc + 14U]);
                    uint16_t secSlot = read_u16_le(&p_vm->imageBuf[pc + 16U]);
                    VmTzRule_t tz;
                    read_tz_rule(&p_vm->imageBuf[pc], &tz);
                    int64_t  utcTs   = read_long(p_vm, srcA);
                    int64_t  localTs = utcTs + tz_offset_sec_at_utc(utcTs, &tz);
                    int64_t  days    = (localTs >= 0) ? (localTs / 86400) : ((localTs - 86399) / 86400);
                    int64_t  rem     = localTs - (days * 86400);
                    int32_t  yr      = 1970;
                    uint32_t mon     = 1U;
                    uint32_t day     = 1U;
                    civil_from_days(days, &yr, &mon, &day);
                    write_int(p_vm, dst, yr);
                    write_int(p_vm, monSlot, (int32_t)mon);
                    write_int(p_vm, daySlot, (int32_t)day);
                    write_int(p_vm, hrSlot,  (int32_t)(rem / 3600));
                    write_int(p_vm, minSlot, (int32_t)((rem % 3600) / 60));
                    write_int(p_vm, secSlot, (int32_t)(rem % 60));
                }
                break;
            }
            case VM_OP_ENCODE_DATE: {
                nextPc = pc + 32U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                if (enabled) {
                    uint16_t monSlot = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                    uint16_t daySlot = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                    uint16_t hrSlot  = read_u16_le(&p_vm->imageBuf[pc + 12U]);
                    uint16_t minSlot = read_u16_le(&p_vm->imageBuf[pc + 14U]);
                    uint16_t secSlot = read_u16_le(&p_vm->imageBuf[pc + 16U]);
                    VmTzRule_t tz;
                    read_tz_rule(&p_vm->imageBuf[pc], &tz);
                    int32_t  yr      = read_int(p_vm, srcA);
                    int32_t  mon     = read_int(p_vm, monSlot);
                    int32_t  day     = read_int(p_vm, daySlot);
                    int32_t  hr      = read_int(p_vm, hrSlot);
                    int32_t  min     = read_int(p_vm, minSlot);
                    int32_t  sec     = read_int(p_vm, secSlot);
                    if (mon < 1) { mon = 1; } else if (mon > 12) { mon = 12; }
                    if (day < 1) { day = 1; } else if (day > 31) { day = 31; }
                    int64_t ts = tz_local_to_utc(yr, (uint32_t)mon, (uint32_t)day, hr, min, sec, &tz);
                    write_long(p_vm, dst, ts);
                }
                break;
            }
            case VM_OP_IO_READ: {
                if (enabled) {
                    if (flags == VM_IO_DI && p_vm->hal.di_read != NULL) {
                        write_bool(p_vm, dst, p_vm->hal.di_read(srcA));
                    } else if (flags == VM_IO_AI && p_vm->hal.ai_read != NULL) {
                        write_int(p_vm, dst, p_vm->hal.ai_read(srcA));
                    }
                }
                break;
            }
            case VM_OP_IO_WRITE: {
                if (enabled) {
                    if (flags == VM_IO_DO && p_vm->hal.do_write != NULL) {
                        p_vm->hal.do_write(dst, read_bool(p_vm, srcA));
                    } else if (flags == VM_IO_AO && p_vm->hal.ao_write != NULL) {
                        p_vm->hal.ao_write(dst, read_int(p_vm, srcA));
                    }
                }
                break;
            }
            case VM_OP_IO_PWM: {
                nextPc = pc + 12U;
                if (nextPc > p_vm->imageSizeBytes) { break; }
                uint16_t frqSlot = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                uint16_t dtySlot = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                if (p_vm->hal.pwm_set != NULL) {
                    float dty = enabled ? read_float(p_vm, dtySlot) : 0.0f;
                    uint8_t act = p_vm->hal.pwm_set(srcA, read_int(p_vm, frqSlot), dty);
                    write_bool(p_vm, dst, act);
                }
                break;
            }
            case VM_OP_COMM_EXEC: {
                if (flags == VM_COMM_TMP75) {
                    nextPc = pc + 12U;
                    if (nextPc > p_vm->imageSizeBytes) { break; }
                    uint16_t okSlot = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                    if (enabled && p_vm->hal.comm_exec != NULL) {
                        int64_t rxVal = 0;
                        int32_t err   = 1;
                        p_vm->hal.comm_exec(VM_COMM_TMP75, srcA, 0, &rxVal, &err);
                        uint32_t fBits = (uint32_t)(uint64_t)rxVal;
                        float tempC = 0.0f;
                        memcpy(&tempC, &fBits, sizeof(tempC));
                        write_float(p_vm, dst, tempC);
                        if (okSlot != VM_SLOT_ALWAYS_ENABLED) {
                            write_bool(p_vm, okSlot, (err == 0) ? 1U : 0U);
                        }
                    } else if (!enabled && okSlot != VM_SLOT_ALWAYS_ENABLED) {
                        write_bool(p_vm, okSlot, 0U);
                    }
                } else if (flags == VM_COMM_DS18B20) {
                    nextPc = pc + 20U;
                    if (nextPc > p_vm->imageSizeBytes) { break; }
                    uint16_t okSlot = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                    uint64_t rom64  = read_u64_le(&p_vm->imageBuf[pc + 12U]);
                    if (enabled && p_vm->hal.comm_exec != NULL) {
                        int64_t rxVal = 0;
                        int32_t err   = 1;
                        p_vm->hal.comm_exec(VM_COMM_DS18B20, srcA, (int64_t)rom64, &rxVal, &err);
                        uint32_t fBits = (uint32_t)(uint64_t)rxVal;
                        float tempC = 0.0f;
                        memcpy(&tempC, &fBits, sizeof(tempC));
                        write_float(p_vm, dst, tempC);
                        if (okSlot != VM_SLOT_ALWAYS_ENABLED) {
                            write_bool(p_vm, okSlot, (err == 0) ? 1U : 0U);
                        }
                    } else if (!enabled && okSlot != VM_SLOT_ALWAYS_ENABLED) {
                        write_bool(p_vm, okSlot, 0U);
                    }
                } else if (flags == VM_COMM_CH455G) {
                    nextPc = pc + 24U;
                    if (nextPc > p_vm->imageSizeBytes) { break; }
                    uint16_t modeAndMask = read_u16_le(&p_vm->imageBuf[pc + 8U]);
                    uint16_t slot0       = read_u16_le(&p_vm->imageBuf[pc + 10U]);
                    uint16_t slot1       = read_u16_le(&p_vm->imageBuf[pc + 12U]);
                    uint16_t slot2       = read_u16_le(&p_vm->imageBuf[pc + 14U]);
                    uint16_t slot3       = read_u16_le(&p_vm->imageBuf[pc + 16U]);
                    uint16_t slot4       = read_u16_le(&p_vm->imageBuf[pc + 18U]);
                    uint16_t slot5       = read_u16_le(&p_vm->imageBuf[pc + 20U]);

                    uint8_t  mode      = (uint8_t)(modeAndMask & 0x01U);
                    uint8_t  digitMask = (uint8_t)((modeAndMask >> 4U) & 0x0FU);
                    uint64_t txPacked  = 0ULL;

                    if (mode == 0U) {
                        float    val = read_float(p_vm, slot0);
                        uint32_t fBits = 0U;
                        memcpy(&fBits, &val, sizeof(fBits));
                        int32_t dec = read_int(p_vm, slot1);
                        int32_t brt = read_int(p_vm, slot2);
                        if (dec < 0) { dec = 0; } else if (dec > 3) { dec = 3; }
                        if (brt < 1) { brt = 1; } else if (brt > 8) { brt = 8; }
                        txPacked = (uint64_t)fBits
                                 | (((uint64_t)(uint32_t)dec) << 32U)
                                 | (((uint64_t)(uint32_t)brt) << 36U);
                    } else {
                        int32_t d[4] = {
                            read_int(p_vm, slot0),
                            read_int(p_vm, slot1),
                            read_int(p_vm, slot2),
                            read_int(p_vm, slot3)
                        };
                        int32_t dpMask = read_int(p_vm, slot4);
                        int32_t brt    = read_int(p_vm, slot5);
                        if (brt < 1) { brt = 1; } else if (brt > 8) { brt = 8; }
                        uint32_t segPacked = 0U;
                        for (uint8_t i = 0U; i < 4U; i++) {
                            uint8_t seg = ((digitMask & (1U << i)) != 0U)
                                        ? vm_encode_ch455g_seg(d[i], ((dpMask >> i) & 1) != 0)
                                        : 0x00U;
                            segPacked |= ((uint32_t)seg) << (i * 8U);
                        }
                        txPacked = (uint64_t)segPacked
                                 | (((uint64_t)(uint32_t)brt) << 36U);
                    }

                    txPacked |= (((uint64_t)digitMask) << 40U)
                             |  (((uint64_t)(enabled ? 1U : 0U)) << 44U)
                             |  (((uint64_t)mode) << 45U);

                    if (p_vm->hal.comm_exec != NULL) {
                        int64_t rxVal = 0;
                        int32_t err   = 0;
                        p_vm->hal.comm_exec(VM_COMM_CH455G, srcA, (int64_t)txPacked, &rxVal, &err);
                        write_bool(p_vm, dst, (enabled && err == 0) ? 1U : 0U);
                    } else {
                        write_bool(p_vm, dst, 0U);
                    }
                }
                break;
            }
            default: {
                p_vm->lastFaultCode = VM_ERR_FAULT_OPCODE;
                p_vm->lastFaultPc   = (uint16_t)pc;
                p_vm->runState      = VM_STATE_FAULT;
                return VM_ERR_FAULT_OPCODE;
            }
        }

        pc = nextPc;
    }

    p_vm->scanCount++;
    if (p_vm->hal.time_micros != NULL) {
        p_vm->threadActual_us[threadId] = p_vm->hal.time_micros() - start_us;
    }
    return VM_OK;
}
