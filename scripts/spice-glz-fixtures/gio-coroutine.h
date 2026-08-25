#pragma once
#include <glib.h>
/* The real one suspends the coroutine until the referenced image arrives.
   This harness feeds images in id order, so the condition is already true
   the first time it is asked; calling it once is the whole behaviour. */
typedef void GCoroutine;
static inline GCoroutine *g_coroutine_self(void) { return NULL; }
static inline gboolean g_coroutine_condition_wait(GCoroutine *c,
                                                  gboolean (*cond)(gpointer),
                                                  gpointer data) {
    (void)c; return cond(data);
}
