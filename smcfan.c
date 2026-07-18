// smcfan — controla o modo das ventoinhas via SMC.
//
// Uso: smcfan auto|silent|medium|max|status
//   auto    devolve o controle ao sistema
//   silent  força o RPM mínimo
//   medium  força o meio da faixa (min + 50% de (max - min))
//   max     força o RPM máximo
//   status  mostra as ventoinhas (não precisa de root)
//
// Escrever no SMC exige root, então este binário é instalado setuid root
// pelo app. Por segurança ele só aceita os modos fixos acima — nenhum
// argumento chega a virar chave ou valor arbitrário do SMC.

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_WRITE_BYTES   6
#define SMC_CMD_READ_KEYINFO  9

typedef struct { char major; char minor; char build; char reserved[1]; UInt16 release; } SMCKeyData_vers_t;
typedef struct { UInt16 version; UInt16 length; UInt32 cpuPLimit; UInt32 gpuPLimit; UInt32 memPLimit; } SMCKeyData_pLimitData_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyData_keyInfo_t;
typedef unsigned char SMCBytes_t[32];

typedef struct {
    UInt32 key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    SMCBytes_t bytes;
} SMCKeyData_t;

static io_connect_t g_conn;

static UInt32 fourcc(const char *s) {
    return ((UInt32)(unsigned char)s[0] << 24) | ((UInt32)(unsigned char)s[1] << 16) |
           ((UInt32)(unsigned char)s[2] << 8)  |  (UInt32)(unsigned char)s[3];
}

static int smc_open(void) {
    io_iterator_t iter;
    if (IOServiceGetMatchingServices(0, IOServiceMatching("AppleSMC"), &iter) != kIOReturnSuccess)
        return -1;
    io_object_t device = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!device) return -1;
    kern_return_t kr = IOServiceOpen(device, mach_task_self(), 0, &g_conn);
    IOObjectRelease(device);
    return kr == kIOReturnSuccess ? 0 : -1;
}

// Retorna 0 em sucesso, 132 (kSMCKeyNotFound) se a chave não existe,
// outro valor em erro (inclusive falta de privilégio na escrita).
static int smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t size = sizeof(SMCKeyData_t);
    if (IOConnectCallStructMethod(g_conn, KERNEL_INDEX_SMC,
                                  in, sizeof(SMCKeyData_t), out, &size) != kIOReturnSuccess)
        return -1;
    return (unsigned char)out->result;
}

static int key_info(const char *key, SMCKeyData_keyInfo_t *info) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    int r = smc_call(&in, &out);
    if (r) return r;
    *info = out.keyInfo;
    return 0;
}

static int read_key(const char *key, SMCKeyData_keyInfo_t *info, unsigned char *bytes) {
    int r = key_info(key, info);
    if (r) return r;
    SMCKeyData_t in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = info->dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    r = smc_call(&in, &out);
    if (r) return r;
    memcpy(bytes, out.bytes, sizeof(SMCBytes_t));
    return 0;
}

static int write_key(const char *key, const unsigned char *bytes) {
    SMCKeyData_keyInfo_t info;
    int r = key_info(key, &info);
    if (r) return r;
    SMCKeyData_t in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, sizeof(SMCBytes_t));
    return smc_call(&in, &out);
}

// Valores de RPM: Macs com T2 usam 'flt ' (float little-endian);
// os mais antigos usam 'fpe2' (fixo 14.2 big-endian).
static double fan_decode(const SMCKeyData_keyInfo_t *info, const unsigned char *b) {
    if (info->dataType == fourcc("flt ") && info->dataSize == 4) {
        float f;
        memcpy(&f, b, 4);
        return f;
    }
    if (info->dataType == fourcc("fpe2"))
        return ((b[0] << 8) | b[1]) / 4.0;
    return -1;
}

static void fan_encode(const SMCKeyData_keyInfo_t *info, double rpm, unsigned char *b) {
    memset(b, 0, sizeof(SMCBytes_t));
    if (info->dataType == fourcc("flt ")) {
        float f = (float)rpm;
        memcpy(b, &f, 4);
    } else {
        UInt16 v = (UInt16)((unsigned)rpm << 2);
        b[0] = v >> 8;
        b[1] = v & 0xff;
    }
}

static int read_fan_rpm(const char *key, double *rpm) {
    SMCKeyData_keyInfo_t info;
    unsigned char b[32];
    int r = read_key(key, &info, b);
    if (r) return r;
    *rpm = fan_decode(&info, b);
    return 0;
}

// Liga/desliga o modo forçado da ventoinha i: F%dMd nos Macs novos,
// bitmask "FS! " nos antigos.
static int set_forced(int i, int forced) {
    char key[5];
    snprintf(key, sizeof(key), "F%dMd", i);
    SMCKeyData_keyInfo_t info;
    if (key_info(key, &info) == 0) {
        unsigned char b[32] = {0};
        b[0] = forced ? 1 : 0;
        return write_key(key, b);
    }
    unsigned char b[32];
    int r = read_key("FS! ", &info, b);
    if (r) return r;
    UInt16 mask = (b[0] << 8) | b[1];
    if (forced) mask |= (1 << i);
    else        mask &= ~(1 << i);
    memset(b, 0, sizeof(b));
    b[0] = mask >> 8;
    b[1] = mask & 0xff;
    return write_key("FS! ", b);
}

static int fan_count(void) {
    SMCKeyData_keyInfo_t info;
    unsigned char b[32];
    if (read_key("FNum", &info, b)) return -1;
    return b[0];
}

// Decodifica um valor escalar do SMC (temperatura, watts) nos tipos comuns.
static int decode_scalar(const SMCKeyData_keyInfo_t *info, const unsigned char *b, double *out) {
    UInt32 t = info->dataType;
    if (t == fourcc("flt ") && info->dataSize == 4) { float f; memcpy(&f, b, 4); *out = f; return 0; }
    if (t == fourcc("sp78") && info->dataSize == 2) { short raw = (short)((b[0] << 8) | b[1]); *out = raw / 256.0; return 0; }
    if (t == fourcc("fpe2")) { *out = ((b[0] << 8) | b[1]) / 4.0; return 0; }
    if (t == fourcc("ui8 ")) { *out = b[0]; return 0; }
    if (t == fourcc("ui16")) { *out = (b[0] << 8) | b[1]; return 0; }
    return -1;
}

static int read_scalar(const char *key, double *out) {
    SMCKeyData_keyInfo_t info;
    unsigned char b[32];
    if (read_key(key, &info, b)) return -1;
    return decode_scalar(&info, b, out);
}

// Imprime temperatura da CPU e watts do pacote. As chaves variam por modelo,
// então testamos candidatas e usamos a primeira que ler um valor plausível.
static int cmd_sensors(void) {
    const char *temps[]  = {"TC0P", "TCXC", "TC0E", "TC0D", "Tp0C", NULL};
    const char *powers[] = {"PCPC", "PC0C", "PSTR", "PPBR", NULL};
    for (int i = 0; temps[i]; i++) {
        double v;
        if (read_scalar(temps[i], &v) == 0 && v > 0 && v < 125) { printf("temp %.1f\n", v); break; }
    }
    for (int i = 0; powers[i]; i++) {
        double v;
        if (read_scalar(powers[i], &v) == 0 && v >= 0 && v < 200) { printf("power %.1f\n", v); break; }
    }
    return 0;
}

static int cmd_status(int fans) {
    for (int i = 0; i < fans; i++) {
        char kmin[5], kmax[5], ktgt[5], kact[5], kmd[5];
        snprintf(kmin, 5, "F%dMn", i);
        snprintf(kmax, 5, "F%dMx", i);
        snprintf(ktgt, 5, "F%dTg", i);
        snprintf(kact, 5, "F%dAc", i);
        snprintf(kmd,  5, "F%dMd", i);

        double mn = -1, mx = -1, tg = -1, ac = -1;
        read_fan_rpm(kmin, &mn);
        read_fan_rpm(kmax, &mx);
        read_fan_rpm(ktgt, &tg);
        read_fan_rpm(kact, &ac);

        SMCKeyData_keyInfo_t info;
        unsigned char b[32] = {0};
        const char *mode = "?";
        if (read_key(kmd, &info, b) == 0)
            mode = b[0] ? "forçado" : "auto";

        printf("Ventoinha %d: atual=%.0f alvo=%.0f min=%.0f max=%.0f modo=%s\n",
               i, ac, tg, mn, mx, mode);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "uso: smcfan auto|silent|medium|max|status|sensors\n");
        return 2;
    }
    const char *mode = argv[1];
    int is_status = strcmp(mode, "status") == 0;
    int is_sensors = strcmp(mode, "sensors") == 0;
    int is_read = is_status || is_sensors;
    double factor = -1; // fração da faixa min..max; -1 = auto
    if      (strcmp(mode, "silent") == 0) factor = 0.0;
    else if (strcmp(mode, "medium") == 0) factor = 0.5;
    else if (strcmp(mode, "max") == 0)    factor = 1.0;
    else if (!is_read && strcmp(mode, "auto") != 0) {
        fprintf(stderr, "uso: smcfan auto|silent|medium|max|status|sensors\n");
        return 2;
    }

    // Consolida o privilégio do bit setuid (escritas no SMC exigem root).
    if (!is_read && geteuid() == 0)
        setuid(0);

    if (smc_open()) {
        fprintf(stderr, "smcfan: não consegui abrir o AppleSMC\n");
        return 1;
    }

    int fans = fan_count();
    if (fans <= 0) {
        fprintf(stderr, "smcfan: nenhuma ventoinha encontrada\n");
        return 1;
    }

    if (is_sensors)
        return cmd_sensors();

    if (is_status)
        return cmd_status(fans);

    for (int i = 0; i < fans; i++) {
        if (factor < 0) {
            if (set_forced(i, 0)) {
                fprintf(stderr, "smcfan: falha ao voltar a ventoinha %d pro automático\n", i);
                return 1;
            }
            continue;
        }

        char kmin[5], kmax[5], ktgt[5];
        snprintf(kmin, 5, "F%dMn", i);
        snprintf(kmax, 5, "F%dMx", i);
        snprintf(ktgt, 5, "F%dTg", i);

        double mn, mx;
        if (read_fan_rpm(kmin, &mn) || read_fan_rpm(kmax, &mx) || mn < 0 || mx <= mn) {
            fprintf(stderr, "smcfan: não consegui ler a faixa da ventoinha %d\n", i);
            return 1;
        }
        double target = mn + factor * (mx - mn);

        SMCKeyData_keyInfo_t info;
        if (key_info(ktgt, &info)) {
            fprintf(stderr, "smcfan: chave %s não encontrada\n", ktgt);
            return 1;
        }
        unsigned char b[32];
        fan_encode(&info, target, b);
        if (set_forced(i, 1) || write_key(ktgt, b)) {
            fprintf(stderr, "smcfan: falha ao ajustar a ventoinha %d (precisa de root)\n", i);
            return 1;
        }
    }
    return 0;
}
