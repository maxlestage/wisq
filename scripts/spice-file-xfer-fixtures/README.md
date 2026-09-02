# Where the `FILE_XFER_START` payloads in `SpiceFileTransferTests` come from

The start message of a SPICE file transfer carries a GKeyFile document —
`channel-main.c` builds it with `g_key_file_set_string` / `g_key_file_set_uint64`
and serialises it with `g_key_file_to_data`, then queues `data_len + 1` bytes:
**the terminating NUL travels on the wire.** The agent in the guest parses it
back with GLib. So the only honest authority on these bytes is GLib itself; a
fixture written by the same person who wrote the serialiser would only confirm
that they guessed GLib's escaping the same way twice.

`gen.c` links GLib and prints the exact payload (NUL included) for names that
exercise every escape. What it measured, and what
`SpiceFileTransfer.keyFileValue` therefore does:

- `\`, `\n` (0x0A) and `\r` (0x0D) are escaped wherever they appear;
- the run of blanks at the **start** of the value is escaped character by
  character — space → `\s`, tab → `\t`;
- a tab after the first non-blank and a space at the end travel **raw**;
- `=`, `[`, `]`, `#`, `;` and non-ASCII UTF-8 travel raw;
- the two edges of the leading run are not symmetrical: a backslash **ends**
  it (the space after `\` goes raw), while an escaped newline **leaves it
  open** (the space after a leading `\n` is still `\s`).

Rebuild and re-run:

    cc gen.c $(pkg-config --cflags --libs glib-2.0) -o gen && ./gen

Each output line is `<label> <hex of the payload after the id>`; the Swift
test file holds these hex strings verbatim.
