/* Prints the exact payload a SPICE client puts after the id in
 * VD_AGENT_FILE_XFER_START, for a table of (name, size) pairs.
 *
 * The reference is channel-main.c's file_xfer_init_task_async_cb: a GKeyFile
 * with group "vdagent-file-xfer", keys "name" and "size", serialised by
 * g_key_file_to_data, then queued with data_len + 1 — the terminating NUL
 * travels on the wire. A fixture written by hand would only confirm that the
 * same person guessed GLib's escaping twice; this one is GLib's own answer.
 *
 * Build and run (glib-2.0 development files required):
 *   cc gen.c $(pkg-config --cflags --libs glib-2.0) -o gen && ./gen
 */
#include <glib.h>
#include <stdio.h>

static void emit(const char *label, const char *name, guint64 size) {
    GKeyFile *keyfile = g_key_file_new();
    gsize len = 0;
    gchar *data;
    g_key_file_set_string(keyfile, "vdagent-file-xfer", "name", name);
    g_key_file_set_uint64(keyfile, "vdagent-file-xfer", "size", size);
    data = g_key_file_to_data(keyfile, &len, NULL);
    printf("%s ", label);
    for (gsize i = 0; i <= len; i++) /* <=: the NUL is part of the payload */
        printf("%02x", (unsigned char)data[i]);
    printf("\n");
    g_free(data);
    g_key_file_free(keyfile);
}

int main(void) {
    emit("plain", "notes.txt", 5);
    emit("utf8", "café été.txt", 1234567890123ULL);
    emit("space-inside", "mon fichier.txt", 0);
    emit("leading-space", " garde.txt", 7);
    emit("backslash", "a\\b.txt", 42);
    emit("equals", "a=b.txt", 1);
    emit("brackets", "[section].txt", 2);
    emit("hash", "#pas-un-commentaire", 3);
    emit("tab", "avant\tapres.txt", 4);
    emit("newline", "ligne\ncoupee.txt", 9);
    emit("carriage", "avant\rapres.txt", 9);
    emit("trailing-space", "fin .txt ", 9);
    emit("two-leading", "  deux.txt", 9);
    emit("leading-tab", "\ttab-en-tete.txt", 9);
    /* The two edges of the leading-blank run, measured because they are not
     * what one would guess: a backslash ends the run (the space after it goes
     * raw), while an escaped newline leaves it open (the space after it is
     * still \s). */
    emit("backslash-ends-run", "\\ apres-antislash", 9);
    emit("newline-keeps-run", "\n suite.txt", 9);
    return 0;
}
