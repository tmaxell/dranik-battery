#include "include/dranik_smc.h"

#include <string.h>

void dr_smc_param_set_bytes(DRSMCParamStruct *p, const uint8_t *src, uint32_t n) {
    if (p == NULL || src == NULL) {
        return;
    }
    if (n > DRSMC_MAX_DATA_SIZE) {
        n = DRSMC_MAX_DATA_SIZE;
    }
    memcpy(p->bytes, src, n);
}

void dr_smc_param_get_bytes(const DRSMCParamStruct *p, uint8_t *dst, uint32_t n) {
    if (p == NULL || dst == NULL) {
        return;
    }
    if (n > DRSMC_MAX_DATA_SIZE) {
        n = DRSMC_MAX_DATA_SIZE;
    }
    memcpy(dst, p->bytes, n);
}
