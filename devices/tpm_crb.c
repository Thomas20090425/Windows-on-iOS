/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * TPM 2.0 CRB and FIFO/TIS transports over one libtpms instance.
 * Register layout follows the TCG PC Client Platform TPM Profile and QEMU's
 * documented TPM devices. TPM commands, PCRs, keys and authorization are
 * implemented by libtpms, not synthesized by these transport registers.
 */
#include "tpm_crb.h"
#include "machine.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(HV_HAVE_LIBTPMS) && HV_HAVE_LIBTPMS
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#include <libtpms/tpm_error.h>
#include <libtpms/tpm_library.h>
#include <libtpms/tpm_nvfilename.h>
#include <libtpms/tpm_tis.h>

enum {
    CRB_BUFFER_OFFSET = 0x80,
    BUFFER_CAPACITY = 16 * 1024,
    STATE_LIMIT = 4 * 1024 * 1024,
    NO_LOCALITY = 0xff,
    TIS_VALID = 0x80,
    TIS_READY = 0x40,
    TIS_DATA = 0x10,
    TIS_EXPECT = 0x08,
};

static const char identity_contents[] = "WindowsiOS TPM2 state v1\n";

struct HvTpmCrb {
    uint64_t base;
    int directory_fd, lock_fd, library_started, identity_exists;
    _Atomic int failed;
    char error[256];
    uint32_t buffer_size, control_status, start;
    uint8_t locality, pending, seized;
    uint8_t crb_buffer[BUFFER_CAPACITY];
    uint8_t fifo_command[BUFFER_CAPACITY], fifo_response[BUFFER_CAPACITY];
    uint32_t fifo_in, fifo_out, fifo_response_size;
    uint8_t fifo_status;
    unsigned temporary_sequence;
};

/* libtpms is intentionally single-instance. Callbacks do not carry opaque
 * context, so every library call is serialized under this process-wide lock. */
static pthread_mutex_t backend_lock = PTHREAD_MUTEX_INITIALIZER;
static HvTpmCrb *backend;

static void fail(HvTpmCrb *s, const char *format, ...) {
    if (atomic_load_explicit(&s->failed, memory_order_relaxed)) return;
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(s->error, sizeof s->error, format, arguments);
    va_end(arguments);
    s->control_status |= 1; /* CRB fatal-error bit */
    s->start = 0;
    atomic_store_explicit(&s->failed, 1, memory_order_release);
}

static uint32_t be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 |
           (uint32_t)p[2] << 8 | p[3];
}

static uint64_t little_read(const uint8_t *p, unsigned size) {
    uint64_t value = 0;
    for (unsigned i = 0; i < size; ++i) value |= (uint64_t)p[i] << (i * 8);
    return value;
}

static void little_write(uint8_t *p, uint64_t value, unsigned size) {
    for (unsigned i = 0; i < size; ++i) p[i] = (uint8_t)(value >> (i * 8));
}

static int state_name_valid(const char *name) {
    return name && (!strcmp(name, TPM_PERMANENT_ALL_NAME) ||
                    !strcmp(name, TPM_VOLATILESTATE_NAME) ||
                    !strcmp(name, TPM_SAVESTATE_NAME));
}

static int write_all(int fd, const uint8_t *bytes, size_t length) {
    while (length) {
        ssize_t n = write(fd, bytes, length);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        bytes += n;
        length -= (size_t)n;
    }
    return 0;
}

static int store_file_atomically(HvTpmCrb *s, const char *name, const void *bytes, size_t length) {
    char temporary[80];
    int fd = -1;
    for (int i = 0; i < 32 && fd < 0; ++i) {
        snprintf(temporary, sizeof temporary, ".state-%ld-%u.tmp",
                 (long)getpid(), ++s->temporary_sequence);
        fd = openat(s->directory_fd, temporary,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0 && errno != EEXIST) break;
    }
    if (fd < 0) {
        fail(s, "Cannot create TPM state update: %s", strerror(errno));
        return -1;
    }
    int saved = 0;
    if (write_all(fd, bytes, length) || fsync(fd)) saved = errno ? errno : EIO;
    if (close(fd) && !saved) saved = errno;
    if (!saved && renameat(s->directory_fd, temporary, s->directory_fd, name)) saved = errno;
    if (!saved && fsync(s->directory_fd)) saved = errno;
    if (saved) {
        unlinkat(s->directory_fd, temporary, 0);
        fail(s, "Cannot durably save TPM state: %s", strerror(saved));
        return -1;
    }
    return 0;
}

static TPM_RESULT nv_init(void) {
    return backend && !atomic_load_explicit(&backend->failed, memory_order_relaxed)
        ? TPM_SUCCESS : TPM_FAIL;
}

static TPM_RESULT nv_load(unsigned char **data, uint32_t *length,
                           uint32_t number, const char *name) {
    HvTpmCrb *s = backend;
    *data = NULL;
    *length = 0;
    if (!s || number || !state_name_valid(name)) return TPM_FAIL;
    int fd = openat(s->directory_fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        if (errno == ENOENT && (!s->identity_exists || strcmp(name, TPM_PERMANENT_ALL_NAME)))
            return TPM_RETRY; /* Only a genuinely new TPM may be manufactured. */
        fail(s, "Cannot load existing TPM state %s: %s", name, strerror(errno));
        return TPM_FAIL;
    }
    struct stat information;
    if (fstat(fd, &information) || !S_ISREG(information.st_mode) ||
            information.st_size <= 0 || information.st_size > STATE_LIMIT) {
        close(fd);
        fail(s, "TPM state %s is invalid; it has been preserved", name);
        return TPM_FAIL;
    }
    size_t size = (size_t)information.st_size;
    uint8_t *buffer = malloc(size);
    if (!buffer) {
        close(fd);
        fail(s, "Cannot allocate the TPM state buffer");
        return TPM_FAIL;
    }
    size_t offset = 0;
    while (offset < size) {
        ssize_t n = read(fd, buffer + offset, size - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        offset += (size_t)n;
    }
    close(fd);
    if (offset != size) {
        free(buffer);
        fail(s, "Cannot completely read TPM state %s", name);
        return TPM_FAIL;
    }
    *data = buffer;
    *length = (uint32_t)size;
    return TPM_SUCCESS;
}

static TPM_RESULT nv_store(const unsigned char *data, uint32_t length,
                            uint32_t number, const char *name) {
    HvTpmCrb *s = backend;
    if (!s || number || !state_name_valid(name) || !data || !length || length > STATE_LIMIT)
        return TPM_FAIL;
    return store_file_atomically(s, name, data, length) ? TPM_FAIL : TPM_SUCCESS;
}

static TPM_RESULT nv_delete(uint32_t number, const char *name, TPM_BOOL must_exist) {
    HvTpmCrb *s = backend;
    if (!s || number || !state_name_valid(name)) return TPM_FAIL;
    if (unlinkat(s->directory_fd, name, 0)) {
        if (errno == ENOENT && !must_exist) return TPM_SUCCESS;
        fail(s, "Cannot remove TPM state %s: %s", name, strerror(errno));
        return TPM_FAIL;
    }
    if (fsync(s->directory_fd)) {
        fail(s, "Cannot commit TPM state removal: %s", strerror(errno));
        return TPM_FAIL;
    }
    return TPM_SUCCESS;
}

static TPM_RESULT io_locality(TPM_MODIFIER_INDICATOR *locality, uint32_t number) {
    if (!backend || number) return TPM_FAIL;
    *locality = backend->locality == NO_LOCALITY ? 0 : backend->locality;
    return TPM_SUCCESS;
}

static TPM_RESULT io_presence(TPM_BOOL *present, uint32_t number) {
    if (number) return TPM_FAIL;
    *present = FALSE; /* No synthetic physical-presence authorization. */
    return TPM_SUCCESS;
}

static int flush_locked(HvTpmCrb *s) {
    if (atomic_load_explicit(&s->failed, memory_order_relaxed)) return -1;
    unsigned char *data = NULL;
    uint32_t length = 0;
    TPM_RESULT result = TPMLIB_GetState(TPMLIB_STATE_PERMANENT, &data, &length);
    if (result != TPM_SUCCESS || !data || !length || length > STATE_LIMIT) {
        free(data);
        fail(s, "Cannot serialize persistent TPM state (0x%x)", result);
        return -1;
    }
    int saved = store_file_atomically(s, TPM_PERMANENT_ALL_NAME, data, length);
    free(data);
    if (saved) return -1;
    if (!s->identity_exists) {
        if (store_file_atomically(s, "identity", identity_contents, sizeof identity_contents - 1)) return -1;
        s->identity_exists = 1;
    }
    return 0;
}

static void reset_registers(HvTpmCrb *s) {
    s->locality = NO_LOCALITY;
    s->pending = s->seized = 0;
    s->control_status = 2; /* tpmIdle */
    s->start = 0;
    s->fifo_status = TIS_VALID | TIS_READY;
    s->fifo_in = s->fifo_out = s->fifo_response_size = 0;
    memset(s->crb_buffer, 0, sizeof s->crb_buffer);
    memset(s->fifo_command, 0, sizeof s->fifo_command);
    memset(s->fifo_response, 0, sizeof s->fifo_response);
}

static int start_library(HvTpmCrb *s) {
    if (TPMLIB_ChooseTPMVersion(TPMLIB_TPM_VERSION_2) != TPM_SUCCESS) {
        fail(s, "This libtpms build cannot provide TPM 2.0");
        return -1;
    }
    struct libtpms_callbacks callbacks = {
        .sizeOfStruct = sizeof callbacks,
        .tpm_nvram_init = nv_init,
        .tpm_nvram_loaddata = nv_load,
        .tpm_nvram_storedata = nv_store,
        .tpm_nvram_deletename = nv_delete,
        .tpm_io_init = nv_init,
        .tpm_io_getlocality = io_locality,
        .tpm_io_getphysicalpresence = io_presence,
    };
    if (TPMLIB_RegisterCallbacks(&callbacks) != TPM_SUCCESS) {
        fail(s, "Cannot configure the TPM 2.0 backend");
        return -1;
    }
    unsigned char *state = NULL;
    uint32_t length = 0;
    TPM_RESULT loaded = nv_load(&state, &length, 0, TPM_PERMANENT_ALL_NAME);
    if (loaded == TPM_SUCCESS) {
        TPM_RESULT result = TPMLIB_SetState(TPMLIB_STATE_PERMANENT, state, length);
        free(state);
        if (result != TPM_SUCCESS) {
            fail(s, "Existing TPM state is unreadable (0x%x); it has not been reset", result);
            return -1;
        }
    } else if (loaded != TPM_RETRY) {
        return -1;
    }
    s->buffer_size = TPMLIB_SetBufferSize(BUFFER_CAPACITY, NULL, NULL);
    if (s->buffer_size < 10 || s->buffer_size > BUFFER_CAPACITY) {
        fail(s, "TPM backend command capacity is unsupported");
        return -1;
    }
    s->library_started = 1; /* Also terminate a partially initialized library. */
    TPM_RESULT result = TPMLIB_MainInit();
    if (result != TPM_SUCCESS || atomic_load_explicit(&s->failed, memory_order_relaxed)) {
        fail(s, "TPM 2.0 initialization failed (0x%x); existing state was preserved", result);
        return -1;
    }
    return flush_locked(s);
}

static uint32_t execute(HvTpmCrb *s, uint8_t *command, uint32_t length, uint8_t *response) {
    if (atomic_load_explicit(&s->failed, memory_order_relaxed)) return 0;
    if (length < 10 || length > s->buffer_size || be32(command + 2) != length) {
        fail(s, "TPM transport received an invalid command length");
        return 0;
    }
    unsigned char *output = NULL;
    uint32_t output_size = 0, allocation = 0;
    TPM_RESULT result = TPMLIB_Process(&output, &output_size, &allocation, command, length);
    if (result != TPM_SUCCESS || atomic_load_explicit(&s->failed, memory_order_relaxed) ||
            !output || output_size < 10 || output_size > s->buffer_size ||
            be32(output + 2) != output_size) {
        free(output);
        fail(s, "TPM command execution failed (0x%x)", result);
        return 0;
    }
    if (be32(output + 6) == 0x101) { /* TPM_RC_FAILURE: backend is in failure mode. */
        free(output);
        fail(s, "TPM 2.0 entered failure mode; execution has been stopped");
        return 0;
    }
    memcpy(response, output, output_size);
    free(output);
    return output_size;
}

static void release_locality(HvTpmCrb *s) {
    s->locality = NO_LOCALITY;
    for (int locality = 4; locality >= 0; --locality) {
        if (s->pending & (1u << locality)) {
            s->pending &= (uint8_t)~(1u << locality);
            s->locality = (uint8_t)locality;
            break;
        }
    }
}

static void request_locality(HvTpmCrb *s, uint8_t locality, int seize) {
    if (s->locality == NO_LOCALITY || s->locality == locality) {
        s->locality = locality;
        s->pending &= (uint8_t)~(1u << locality);
    } else if (seize && locality > s->locality) {
        s->seized |= (uint8_t)(1u << s->locality);
        s->pending &= (uint8_t)~(1u << locality);
        s->locality = locality;
    } else {
        s->pending |= (uint8_t)(1u << locality);
    }
}

static uint8_t not_established(void) {
    TPM_BOOL established = FALSE;
    return TPM_IO_TpmEstablished_Get(&established) == TPM_SUCCESS && established ? 0 : 1;
}

static uint64_t crb_read(void *opaque, uint64_t offset, unsigned size) {
    HvTpmCrb *s = opaque;
    if (!size || size > 8 || offset > HV_TPM_CRB_SIZE - size) return 0;
    pthread_mutex_lock(&backend_lock);
    uint64_t value = 0;
    if (offset >= CRB_BUFFER_OFFSET && offset + size <= CRB_BUFFER_OFFSET + s->buffer_size) {
        value = little_read(s->crb_buffer + offset - CRB_BUFFER_OFFSET, size);
    } else if (offset + size <= CRB_BUFFER_OFFSET) {
        uint8_t registers[CRB_BUFFER_OFFSET] = {0};
        uint32_t assigned = s->locality != NO_LOCALITY;
        registers[0] = 0x80 | not_established() | (assigned << 1) |
                       ((assigned ? s->locality : 0) << 2);
        registers[0x0c] = (s->locality == 0 ? 1 : 0) | ((s->seized & 1) ? 2 : 0);
        /* CRB-only, locality 0, 64-byte transfers, fixed interface selector. */
        little_write(registers + 0x30, 1u | (1u << 4) | (3u << 11) |
                     (1u << 14) | (1u << 17) | (1u << 19), 4);
        little_write(registers + 0x34, 0x00011014, 4);
        little_write(registers + 0x44, s->control_status, 4);
        little_write(registers + 0x4c, s->start, 4);
        little_write(registers + 0x58, s->buffer_size, 4);
        little_write(registers + 0x5c, s->base + CRB_BUFFER_OFFSET, 8);
        little_write(registers + 0x64, s->buffer_size, 4);
        little_write(registers + 0x68, s->base + CRB_BUFFER_OFFSET, 8);
        value = little_read(registers + offset, size);
    }
    pthread_mutex_unlock(&backend_lock);
    return value;
}

static void crb_write(void *opaque, uint64_t offset, uint64_t value, unsigned size) {
    HvTpmCrb *s = opaque;
    if (!size || size > 8 || offset > HV_TPM_CRB_SIZE - size) return;
    pthread_mutex_lock(&backend_lock);
    if (atomic_load_explicit(&s->failed, memory_order_relaxed)) goto done;
    if (offset >= CRB_BUFFER_OFFSET && offset + size <= CRB_BUFFER_OFFSET + s->buffer_size) {
        little_write(s->crb_buffer + offset - CRB_BUFFER_OFFSET, value, size);
    } else if (offset == 0x08) {
        if (value & 2) {
            if (s->locality == 0) release_locality(s);
        } else if (value & 1) {
            s->seized &= (uint8_t)~1u;
            request_locality(s, 0, 0);
        }
    } else if (offset == 0x40) {
        if (value & 1) s->control_status &= ~2u;
        else if (value & 2) s->control_status |= 2;
    } else if (offset == 0x4c && (value & 1) && s->locality == 0 && !s->start) {
        s->start = 1;
        uint32_t length = be32(s->crb_buffer + 2);
        uint32_t output_size = execute(s, s->crb_buffer, length, s->crb_buffer);
        if (output_size < s->buffer_size)
            memset(s->crb_buffer + output_size, 0, s->buffer_size - output_size);
        s->start = 0;
    }
    /* Commands are synchronous; cancellation cannot race an active request.
     * This polling interface does not advertise interrupt capability. */
done:
    pthread_mutex_unlock(&backend_lock);
}

static uint32_t fifo_burst(HvTpmCrb *s) {
    uint32_t remaining;
    if (s->fifo_status & TIS_DATA) remaining = s->fifo_response_size - s->fifo_out;
    else remaining = s->buffer_size - s->fifo_in;
    return remaining < 64 ? remaining : 64;
}

static uint32_t fifo_register(HvTpmCrb *s, uint8_t locality, uint32_t offset) {
    switch (offset) {
    case 0x00:
        return 0x80 | not_established() | (s->locality == locality ? 0x20 : 0) |
               ((s->seized & (1u << locality)) ? 0x10 : 0) | (s->pending ? 4 : 0);
    case 0x14: return (3u << 28) | (3u << 9); /* TPM2 TIS, dynamic burst, polling */
    case 0x18:
        return (1u << 26) | (fifo_burst(s) << 8) |
               (s->locality == locality ? s->fifo_status : 0);
    case 0x30: return (1u << 8) | (1u << 13) | (1u << 19); /* FIFO, five localities */
    case 0xf00: return 0x00011014;
    case 0xf04: return 1;
    default: return 0;
    }
}

static int fifo_data_register(uint32_t offset) {
    return (offset >= 0x24 && offset <= 0x27) || (offset >= 0x80 && offset <= 0xbf);
}

static uint64_t tis_read(void *opaque, uint64_t offset, unsigned size) {
    HvTpmCrb *s = opaque;
    if (!size || size > 8 || offset >= 0x5000 || offset + size > 0x5000) return UINT64_MAX;
    uint8_t locality = (uint8_t)(offset >> 12);
    uint32_t reg = (uint32_t)offset & 0xfff;
    pthread_mutex_lock(&backend_lock);
    uint64_t value = 0;
    if (fifo_data_register(reg)) {
        for (unsigned i = 0; i < size; ++i) {
            uint8_t byte = 0xff;
            if (s->locality == locality && (s->fifo_status & TIS_DATA) &&
                    s->fifo_out < s->fifo_response_size) {
                byte = s->fifo_response[s->fifo_out++];
                if (s->fifo_out == s->fifo_response_size) s->fifo_status &= (uint8_t)~TIS_DATA;
            }
            value |= (uint64_t)byte << (i * 8);
        }
    } else {
        for (unsigned i = 0; i < size; ++i) {
            uint32_t off = reg + i;
            uint32_t word = fifo_register(s, locality, off & ~3u);
            value |= (uint64_t)((word >> ((off & 3) * 8)) & 0xff) << (i * 8);
        }
    }
    pthread_mutex_unlock(&backend_lock);
    return value;
}

static void fifo_ready(HvTpmCrb *s) {
    s->fifo_in = s->fifo_out = s->fifo_response_size = 0;
    s->fifo_status = TIS_VALID | TIS_READY;
}

static void fifo_append(HvTpmCrb *s, uint8_t byte) {
    if (!(s->fifo_status & (TIS_READY | TIS_EXPECT))) return;
    if (s->fifo_in >= s->buffer_size) {
        fail(s, "TPM FIFO command exceeds the backend buffer");
        return;
    }
    s->fifo_command[s->fifo_in++] = byte;
    s->fifo_status = TIS_VALID | TIS_EXPECT;
    if (s->fifo_in >= 6) {
        uint32_t length = be32(s->fifo_command + 2);
        if (length < 10 || length > s->buffer_size) {
            fail(s, "TPM FIFO header has an invalid command size");
            return;
        }
        if (s->fifo_in == length) s->fifo_status &= (uint8_t)~TIS_EXPECT;
    }
}

static void tis_write(void *opaque, uint64_t offset, uint64_t value, unsigned size) {
    HvTpmCrb *s = opaque;
    if (!size || size > 8 || offset >= 0x5000 || offset + size > 0x5000) return;
    uint8_t locality = (uint8_t)(offset >> 12);
    uint32_t reg = (uint32_t)offset & 0xfff;
    pthread_mutex_lock(&backend_lock);
    if (atomic_load_explicit(&s->failed, memory_order_relaxed)) goto done;
    if (reg == 0) {
        if ((value & 0x20) && s->locality == locality) release_locality(s);
        if (value & 0x10) s->seized &= (uint8_t)~(1u << locality);
        if (value & 8) request_locality(s, locality, 1);
        else if (value & 2) request_locality(s, locality, 0);
    } else if (s->locality == locality) {
        if (fifo_data_register(reg)) {
            for (unsigned i = 0; i < size; ++i) fifo_append(s, (uint8_t)(value >> (i * 8)));
        } else if (reg >= 0x18 && reg < 0x1c && reg + size <= 0x1c) {
            uint32_t bits = (uint32_t)value << ((reg - 0x18) * 8);
            if (bits & TIS_READY) fifo_ready(s);
            else if ((bits & 0x20) && !(s->fifo_status & TIS_EXPECT) && s->fifo_in) {
                s->fifo_response_size = execute(s, s->fifo_command, s->fifo_in, s->fifo_response);
                s->fifo_out = 0;
                s->fifo_status = TIS_VALID | (s->fifo_response_size ? TIS_DATA : 0);
            } else if ((bits & 2) && s->fifo_response_size) {
                s->fifo_out = 0;
                s->fifo_status = TIS_VALID | TIS_DATA;
            }
            if ((bits & (1u << 25)) && locality >= 3)
                TPM_IO_TpmEstablished_Reset();
        }
    }
done:
    pthread_mutex_unlock(&backend_lock);
}

static int open_directory(HvTpmCrb *s, const char *path) {
    if (!path || !*path) {
        fail(s, "A private TPM state directory is required");
        return -1;
    }
    if (mkdir(path, 0700) && errno != EEXIST) {
        fail(s, "Cannot create the TPM state directory: %s", strerror(errno));
        return -1;
    }
    s->directory_fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (s->directory_fd < 0) {
        fail(s, "Cannot open the TPM state directory: %s", strerror(errno));
        return -1;
    }
    s->lock_fd = openat(s->directory_fd, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (s->lock_fd < 0 || flock(s->lock_fd, LOCK_EX | LOCK_NB)) {
        fail(s, "TPM state is in use or cannot be locked: %s", strerror(errno));
        return -1;
    }
    int identity = openat(s->directory_fd, "identity", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (identity < 0) {
        if (errno != ENOENT) {
            fail(s, "Cannot read TPM state identity: %s", strerror(errno));
            return -1;
        }
    } else {
        struct stat information;
        char content[sizeof identity_contents];
        ssize_t length = -1;
        if (!fstat(identity, &information) && S_ISREG(information.st_mode))
            length = read(identity, content, sizeof content);
        close(identity);
        if (length != sizeof identity_contents - 1 ||
                memcmp(content, identity_contents, sizeof identity_contents - 1)) {
            fail(s, "Unknown TPM state identity format; existing files were preserved");
            return -1;
        }
        s->identity_exists = 1;
    }
    return 0;
}

HvTpmCrb *hv_tpm_crb_create(HvMachine *m, uint64_t base, const char *state_dir,
                            char *error, size_t error_size) {
    HvTpmCrb *s = calloc(1, sizeof *s);
    if (!s) {
        if (error && error_size) snprintf(error, error_size, "Cannot allocate TPM device");
        return NULL;
    }
    s->directory_fd = s->lock_fd = -1;
    s->base = base;
    s->locality = NO_LOCALITY;
    pthread_mutex_lock(&backend_lock);
    if (backend) fail(s, "Another TPM instance is already active; relaunch the app before switching VMs");
    else if (!m || base > UINT64_MAX - HV_TPM_CRB_SIZE - HV_TPM_TIS_SIZE || m->nmmio > HV_MAX_MMIO - 2)
        fail(s, "Cannot register the TPM MMIO devices");
    else if (!open_directory(s, state_dir)) {
        backend = s;
        reset_registers(s);
        start_library(s);
    }
    int failed = atomic_load_explicit(&s->failed, memory_order_acquire);
    if (!failed) {
        hv_machine_add_mmio(m, base, HV_TPM_CRB_SIZE, s, crb_read, crb_write, "tpm2-crb");
        hv_machine_add_mmio(m, base + HV_TPM_CRB_SIZE, HV_TPM_TIS_SIZE, s, tis_read, tis_write, "tpm2-tis");
    }
    if (failed && error && error_size) snprintf(error, error_size, "%s", s->error);
    pthread_mutex_unlock(&backend_lock);
    if (failed) {
        hv_tpm_crb_destroy(s);
        return NULL;
    }
    return s;
}

int hv_tpm_crb_reset(HvTpmCrb *s) {
    if (!s) return 0;
    pthread_mutex_lock(&backend_lock);
    int result = flush_locked(s);
    if (!result) {
        TPMLIB_Terminate();
        s->library_started = 0;
        reset_registers(s);
        result = start_library(s);
    }
    pthread_mutex_unlock(&backend_lock);
    return result;
}

int hv_tpm_crb_flush(HvTpmCrb *s) {
    if (!s) return 0;
    pthread_mutex_lock(&backend_lock);
    int result = flush_locked(s);
    pthread_mutex_unlock(&backend_lock);
    return result;
}

const char *hv_tpm_crb_error(const HvTpmCrb *s) {
    return s && atomic_load_explicit(&s->failed, memory_order_acquire) ? s->error : NULL;
}

void hv_tpm_crb_destroy(HvTpmCrb *s) {
    if (!s) return;
    pthread_mutex_lock(&backend_lock);
    if (backend == s) {
        if (s->library_started) {
            if (!atomic_load_explicit(&s->failed, memory_order_relaxed)) flush_locked(s);
            TPMLIB_Terminate();
        }
        backend = NULL;
    }
    pthread_mutex_unlock(&backend_lock);
    if (s->lock_fd >= 0) close(s->lock_fd);
    if (s->directory_fd >= 0) close(s->directory_fd);
    memset(s, 0, sizeof *s);
    free(s);
}

#else

/* Native Mac builds may omit the optional dependency. Never advertise an
 * operational TPM when that backend has not actually been linked. */
HvTpmCrb *hv_tpm_crb_create(HvMachine *m, uint64_t base, const char *state_dir,
                            char *error, size_t error_size) {
    (void)m; (void)base; (void)state_dir;
    if (error && error_size) snprintf(error, error_size, "TPM 2.0 backend is not included in this build");
    return NULL;
}
int hv_tpm_crb_reset(HvTpmCrb *s) { (void)s; return -1; }
int hv_tpm_crb_flush(HvTpmCrb *s) { (void)s; return -1; }
const char *hv_tpm_crb_error(const HvTpmCrb *s) { (void)s; return "TPM 2.0 backend is not included in this build"; }
void hv_tpm_crb_destroy(HvTpmCrb *s) { (void)s; }

#endif
