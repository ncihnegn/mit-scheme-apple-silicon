#ifndef MOCK_GDBM_H
#define MOCK_GDBM_H

#include <stddef.h>

#define GDBM_VERSION_MAJOR 1
#define GDBM_VERSION_MINOR 23

#define GDBM_READER  0
#define GDBM_WRITER  1
#define GDBM_WRCREAT 2
#define GDBM_NEWDB   3
#define GDBM_FAST    0x010
#define GDBM_SYNC    0x020
#define GDBM_NOLOCK  0x040

#define GDBM_INSERT  0
#define GDBM_REPLACE 1

#define GDBM_CACHESIZE    1
#define GDBM_FASTMODE     2
#define GDBM_SYNCMODE     3
#define GDBM_CENTFREE     4
#define GDBM_COALESCEBLKS 5

typedef enum {
    GDBM_NO_ERROR = 0,
    GDBM_MALLOC_ERROR,
    GDBM_BLOCK_SIZE_ERROR,
    GDBM_FILE_OPEN_ERROR,
    GDBM_FILE_WRITE_ERROR,
    GDBM_FILE_SEEK_ERROR,
    GDBM_FILE_READ_ERROR,
    GDBM_BAD_MAGIC_NUMBER,
    GDBM_EMPTY_DATABASE,
    GDBM_CANT_BE_READER,
    GDBM_CANT_BE_WRITER,
    GDBM_READER_CANT_DELETE,
    GDBM_READER_CANT_STORE,
    GDBM_READER_CANT_REORGANIZE,
    GDBM_UNKNOWN_UPDATE,
    GDBM_ITEM_NOT_FOUND,
    GDBM_REORGANIZE_FAILED,
    GDBM_CANNOT_REPLACE,
    GDBM_ILLEGAL_DATA,
    GDBM_OPT_ALREADY_SET,
    GDBM_OPT_ILLEGAL
} gdbm_error;

typedef struct {
    char *dptr;
    int dsize;
} datum;

typedef struct gdbm_file_info *GDBM_FILE;

extern const char *gdbm_version;
extern gdbm_error *gdbm_errno_location(void);
#define gdbm_errno (*gdbm_errno_location())

extern GDBM_FILE gdbm_open(const char *, int, int, int, void (*)(const char *));
extern int gdbm_close(GDBM_FILE);
extern int gdbm_store(GDBM_FILE, datum, datum, int);
extern datum gdbm_fetch(GDBM_FILE, datum);
extern int gdbm_exists(GDBM_FILE, datum);
extern int gdbm_delete(GDBM_FILE, datum);
extern datum gdbm_firstkey(GDBM_FILE);
extern datum gdbm_nextkey(GDBM_FILE, datum);
extern int gdbm_reorganize(GDBM_FILE);
extern int gdbm_sync(GDBM_FILE);
extern int gdbm_setopt(GDBM_FILE, int, void *, int);
extern const char *gdbm_strerror(gdbm_error);

#endif
