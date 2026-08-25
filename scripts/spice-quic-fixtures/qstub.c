#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <glib.h>
void spice_log(GLogLevelFlags level, const char *strloc, const char *function,
               const char *format, ...) {
    va_list args; va_start(args, format);
    vfprintf(stderr, format, args); va_end(args); fputc('\n', stderr);
    if (level & (G_LOG_LEVEL_ERROR | G_LOG_LEVEL_CRITICAL)) abort();
}
