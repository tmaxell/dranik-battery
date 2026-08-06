// Full read-only SMC key enumeration.
// Uses kSMCGetKeyFromIndex (8), kSMCGetKeyInfo (9), kSMCReadKey (5).
// One optional no-op write test, guarded behind argv[1] == "--test-write-noop":
// it writes back the EXACT bytes it just read from CHTE, so state cannot change.
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
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

enum { kSMCReadKey = 5, kSMCWriteKey = 6, kSMCGetKeyFromIndex = 8, kSMCGetKeyInfo = 9 };
#define YPC 2

static io_connect_t conn = 0;

static uint32_t s2k(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8)  | (uint32_t)(uint8_t)s[3];
}
static void k2s(uint32_t k, char *o) {
    o[0]=(k>>24)&0xff; o[1]=(k>>16)&0xff; o[2]=(k>>8)&0xff; o[3]=k&0xff; o[4]=0;
    for (int i=0;i<4;i++) if (o[i] < 32 || o[i] > 126) o[i]='?';
}
static kern_return_t call(SMCParamStruct *in, SMCParamStruct *out) {
    size_t osz = sizeof(SMCParamStruct);
    return IOConnectCallStructMethod(conn, YPC, in, sizeof(SMCParamStruct), out, &osz);
}

static int keyInfo(uint32_t key, uint32_t *size, uint32_t *type, uint8_t *attr) {
    SMCParamStruct in, out;
    memset(&in,0,sizeof in); memset(&out,0,sizeof out);
    in.key = key; in.data8 = kSMCGetKeyInfo;
    if (call(&in,&out) != kIOReturnSuccess || out.result != 0) return 0;
    *size = out.keyInfo.dataSize; *type = out.keyInfo.dataType; *attr = out.keyInfo.dataAttributes;
    return 1;
}
static int readKey(uint32_t key, uint32_t size, uint8_t *buf) {
    SMCParamStruct in, out;
    memset(&in,0,sizeof in); memset(&out,0,sizeof out);
    in.key = key; in.keyInfo.dataSize = size; in.data8 = kSMCReadKey;
    if (call(&in,&out) != kIOReturnSuccess || out.result != 0) return 0;
    memcpy(buf, out.bytes, size > 32 ? 32 : size);
    return 1;
}

// Interpret raw bytes little-endian (validated against IOKit on Apple Silicon).
static void decode(uint32_t type, uint32_t size, const uint8_t *b, char *out, size_t n) {
    char ts[5]; k2s(type, ts);
    if (!strcmp(ts,"flt ") || !strcmp(ts,"flt")) {
        if (size==4){ float f; memcpy(&f,b,4); snprintf(out,n,"%.3f",f); return; }
    }
    if (!strncmp(ts,"ui8",3) && size==1) { snprintf(out,n,"%u",b[0]); return; }
    if (!strncmp(ts,"si8",3) && size==1) { snprintf(out,n,"%d",(int8_t)b[0]); return; }
    if (!strncmp(ts,"ui16",4)&& size==2) { uint16_t v; memcpy(&v,b,2); snprintf(out,n,"%u",v); return; }
    if (!strncmp(ts,"si16",4)&& size==2) { int16_t v;  memcpy(&v,b,2); snprintf(out,n,"%d",v); return; }
    if (!strncmp(ts,"ui32",4)&& size==4) { uint32_t v; memcpy(&v,b,4); snprintf(out,n,"%u",v); return; }
    if (!strncmp(ts,"si32",4)&& size==4) { int32_t v;  memcpy(&v,b,4); snprintf(out,n,"%d",v); return; }
    if (!strncmp(ts,"flag",4)&& size==1) { snprintf(out,n,"%s",b[0]?"true":"false"); return; }
    out[0]=0;
}

int main(int argc, char **argv) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) { fprintf(stderr,"AppleSMC not found\n"); return 1; }
    if (IOServiceOpen(svc, mach_task_self(), 0, &conn) != kIOReturnSuccess) {
        fprintf(stderr,"IOServiceOpen failed\n"); return 1;
    }
    IOObjectRelease(svc);

    if (argc > 1 && !strcmp(argv[1], "--test-write-noop")) {
        // Read CHTE, then write back the identical bytes. Cannot change state.
        uint32_t size, type; uint8_t attr, buf[32];
        if (!keyInfo(s2k("CHTE"), &size, &type, &attr)) { printf("CHTE absent\n"); return 1; }
        if (!readKey(s2k("CHTE"), size, buf)) { printf("CHTE read failed\n"); return 1; }
        printf("CHTE current bytes:");
        for (uint32_t i=0;i<size;i++) printf(" %02x", buf[i]);
        printf("\nwriting back identical bytes (no-op) as uid=%d ...\n", getuid());
        SMCParamStruct in, out;
        memset(&in,0,sizeof in); memset(&out,0,sizeof out);
        in.key = s2k("CHTE"); in.keyInfo.dataSize = size; in.data8 = kSMCWriteKey;
        memcpy(in.bytes, buf, size);
        kern_return_t kr = call(&in, &out);
        printf("kr=0x%08x (kIOReturnNotPrivileged=0x%08x) result=%u\n",
               kr, kIOReturnNotPrivileged, out.result);
        // verify unchanged
        uint8_t after[32];
        readKey(s2k("CHTE"), size, after);
        printf("CHTE after:        ");
        for (uint32_t i=0;i<size;i++) printf(" %02x", after[i]);
        printf("  -> %s\n", memcmp(buf,after,size)==0 ? "UNCHANGED (ok)" : "*** CHANGED ***");
        IOServiceClose(conn);
        return 0;
    }

    uint32_t nsize, ntype; uint8_t nattr, nbuf[32];
    if (!keyInfo(s2k("#KEY"), &nsize, &ntype, &nattr) || !readKey(s2k("#KEY"), nsize, nbuf)) {
        fprintf(stderr,"cannot read #KEY\n"); return 1;
    }
    uint32_t total_be = ((uint32_t)nbuf[0]<<24)|((uint32_t)nbuf[1]<<16)|((uint32_t)nbuf[2]<<8)|nbuf[3];
    uint32_t total_le; memcpy(&total_le, nbuf, 4);
    uint32_t total = total_le < total_be ? total_le : total_be;
    fprintf(stderr,"#KEY raw=%02x%02x%02x%02x be=%u le=%u -> using %u\n",
            nbuf[0],nbuf[1],nbuf[2],nbuf[3], total_be, total_le, total);

    printf("key\ttype\tsize\tattr\twritable\tvalue\traw\n");
    for (uint32_t i = 0; i < total; i++) {
        SMCParamStruct in, out;
        memset(&in,0,sizeof in); memset(&out,0,sizeof out);
        in.data8 = kSMCGetKeyFromIndex; in.data32 = i;
        if (call(&in,&out) != kIOReturnSuccess || out.result != 0) continue;
        uint32_t key = out.key;
        if (!key) continue;

        uint32_t size, type; uint8_t attr;
        if (!keyInfo(key, &size, &type, &attr)) continue;

        char ks[5], ts[5]; k2s(key, ks); k2s(type, ts);
        uint8_t buf[32]; memset(buf,0,sizeof buf);
        int ok = size <= 32 ? readKey(key, size, buf) : 0;

        char dec[64] = ""; char raw[100] = "";
        if (ok) {
            decode(type, size, buf, dec, sizeof dec);
            char *p = raw;
            for (uint32_t j=0;j<size && j<24;j++) p += sprintf(p, "%02x", buf[j]);
        } else {
            snprintf(raw,sizeof raw,"<unreadable>");
        }
        printf("%s\t%s\t%u\t0x%02x\t%s\t%s\t%s\n",
               ks, ts, size, attr, (attr & 0x40) ? "W" : "-", dec, raw);
    }
    IOServiceClose(conn);
    return 0;
}
