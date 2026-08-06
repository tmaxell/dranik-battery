// Read-only SMC capability probe. Performs ONLY kSMCGetKeyInfo (9) and
// kSMCReadKey (5). Never issues kSMCWriteKey. Used to discover which
// charge-control keys exist on this machine.
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <IOKit/IOKitLib.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfoData;
typedef struct {
    uint32_t       key;
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t        result, status, data8;
    uint32_t       data32;
    uint8_t        bytes[32];
} SMCParamStruct;

enum { kSMCReadKey = 5, kSMCGetKeyInfo = 9, kSMCHandleYPCEvent = 2 };

static io_connect_t conn = 0;

static uint32_t s2k(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}
static void k2s(uint32_t k, char *out) {
    out[0] = (k >> 24) & 0xff; out[1] = (k >> 16) & 0xff;
    out[2] = (k >> 8) & 0xff;  out[3] = k & 0xff; out[4] = 0;
}

static kern_return_t call(SMCParamStruct *in, SMCParamStruct *out) {
    size_t osz = sizeof(SMCParamStruct);
    return IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, in, sizeof(SMCParamStruct), out, &osz);
}

static void probe(const char *key, const char *note) {
    SMCParamStruct in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = s2k(key);
    in.data8 = kSMCGetKeyInfo;
    kern_return_t kr = call(&in, &out);
    if (kr != kIOReturnSuccess || out.result != 0) {
        printf("  %-6s ABSENT            (kr=0x%08x result=%u)   %s\n", key, kr, out.result, note);
        return;
    }
    uint32_t size = out.keyInfo.dataSize, type = out.keyInfo.dataType;
    uint8_t attrs = out.keyInfo.dataAttributes;
    char ts[5]; k2s(type, ts);

    SMCParamStruct rin, rout;
    memset(&rin, 0, sizeof rin); memset(&rout, 0, sizeof rout);
    rin.key = s2k(key);
    rin.keyInfo.dataSize = size;
    rin.data8 = kSMCReadKey;
    kr = call(&rin, &rout);

    printf("  %-6s PRESENT type=%-4s size=%u attr=0x%02x val=", key, ts, size, attrs);
    if (kr == kIOReturnSuccess && rout.result == 0) {
        for (uint32_t i = 0; i < size && i < 32; i++) printf("%02x ", rout.bytes[i]);
    } else {
        printf("<read failed kr=0x%08x result=%u>", kr, rout.result);
    }
    printf("  %s\n", note);
}

int main(void) {
    printf("sizeof(SMCParamStruct) = %zu (expect 80)\n\n", sizeof(SMCParamStruct));

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"));
    if (!svc) { fprintf(stderr, "AppleSMC service not found\n"); return 1; }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "IOServiceOpen failed: 0x%08x\n", kr);
        return 1;
    }

    printf("== charge gate (legacy, M1-M3) ==\n");
    probe("CH0B", "charging inhibit A (0x00 on / 0x02 off)");
    probe("CH0C", "charging inhibit B");
    printf("\n== charge gate (newer firmware) ==\n");
    probe("CHTE", "charging inhibit, ui32");
    printf("\n== firmware-enforced limits ==\n");
    probe("CHWA", "hardware 80%% limit flag (80/100 only)");
    probe("BCLM", "Intel-only charge level max");
    probe("bfF0", "fw limit activation (macOS 27-era)");
    probe("bfD0", "fw limit upper");
    probe("bfE0", "fw limit lower");
    printf("\n== adapter / power input ==\n");
    probe("CH0I", "disable power adapter (0 on / 1 off)");
    probe("CH0J", "disable power adapter alt");
    probe("CHIE", "adapter inhibit, newer fw");
    probe("AC-W", "adapter wattage / plugged-in");
    printf("\n== MagSafe LED ==\n");
    probe("ACLC", "MagSafe LED state");
    printf("\n== telemetry ==\n");
    probe("BUIC", "battery UI charge %%");
    probe("B0AC", "battery current (mA)");
    probe("B0AV", "battery voltage (mV)");
    probe("PPBR", "battery power (W)");
    probe("PDTR", "DC-in power (W)");
    probe("ID0R", "DC-in current");
    probe("VD0R", "DC-in voltage");
    probe("B0TE", "time to empty");
    probe("TB0T", "battery temperature");

    IOServiceClose(conn);
    return 0;
}
