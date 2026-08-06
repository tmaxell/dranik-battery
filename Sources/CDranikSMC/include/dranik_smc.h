// Layout of the parameter struct AppleSMC.kext expects on selector 2
// (kSMCHandleYPCEvent). Field order and padding are dictated by the kext —
// do not reorder. sizeof must be 80; DranikSMCTests asserts this.
//
// Command codes and kSMCKeyNotFound match Apple's SMCParamStruct.h.

#ifndef DRANIK_SMC_H
#define DRANIK_SMC_H

#include <stdint.h>

typedef struct {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint8_t  reserved;
    uint16_t release;
} DRSMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} DRSMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} DRSMCKeyInfoData;

typedef struct {
    uint32_t         key;
    DRSMCVersion     vers;
    DRSMCPLimitData  pLimitData;
    DRSMCKeyInfoData keyInfo;
    uint8_t          result;
    uint8_t          status;
    uint8_t          data8;
    uint32_t         data32;
    uint8_t          bytes[32];
} DRSMCParamStruct;

enum {
    kDRSMCUserClientOpen  = 0,
    kDRSMCUserClientClose = 1,
    kDRSMCHandleYPCEvent  = 2,
    kDRSMCReadKey         = 5,
    kDRSMCWriteKey        = 6,
    kDRSMCGetKeyCount     = 7,
    kDRSMCGetKeyFromIndex = 8,
    kDRSMCGetKeyInfo      = 9
};

enum {
    kDRSMCSuccess     = 0,
    kDRSMCKeyNotFound = 0x84
};

#define DRSMC_MAX_DATA_SIZE 32

// Accessors for the fixed-size `bytes` array. A C array imports into Swift as
// a 32-element tuple, which is unusable; these keep the Swift side readable.
// Both clamp `n` to DRSMC_MAX_DATA_SIZE.
void dr_smc_param_set_bytes(DRSMCParamStruct *p, const uint8_t *src, uint32_t n);
void dr_smc_param_get_bytes(const DRSMCParamStruct *p, uint8_t *dst, uint32_t n);

#endif /* DRANIK_SMC_H */
