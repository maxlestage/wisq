# What a GLZ window too small for one image does

`window-probe.c` builds the reference GLZ **encoder** — the server's, from
`spice-server/server/glz-encoder-dict.c` — against a dictionary of a chosen
size, encodes one image into it, and reports whether the encoder called its
error callback.

## Why this needed running rather than reading

`SPICE_MSGC_DISPLAY_INIT` carries two numbers, a pixmap cache size and a GLZ
dictionary window size, and nothing in the message says they behave
differently. They do, and only one of them is safe to get wrong.

The cache is a budget. `dcc_add_to_cache` subtracts, evicts while it is
negative, and if eviction cannot free enough it returns `FALSE` and the image
goes out uncached. Too small a cache costs bandwidth.

The window is a floor. `glz_dictionary_pre_encode` runs at the top of every
GLZ encode and calls:

```c
static WindowImage *glz_dictionary_window_get_new_head(SharedDictionary *dict, int new_image_size)
{
    if ((uint32_t)new_image_size > dict->window.size_limit) {
        dict->cur_usr->error(dict->cur_usr, "image is bigger than window\n");
    }
```

`dict->cur_usr->error` is `glz_usr_error` in `image-encoders.cpp`, which calls
`spice_critical`, which — `spice-common/common/log.c`, `spice_logv` — calls
`abort()`. There is no fallback encoding and no smaller window used instead.

Reading that is not the same as knowing it, which is why this exists. `size` is
also not obviously reachable at zero: `glz_dictionary_window_create` only
refuses sizes **above** `LZ_MAX_WINDOW_SIZE`, so a zero sails through creation
and only detonates at the first encode, one message later.

## What it prints

```
$ for w in 0 4095 4096 1048576; do ./gzwin $w 64 64; done
  usr->error: image is bigger than window
window = 0 pixels, image = 64x64 (4096 pixels)
  dictionary create: ok, errors so far = 0
  glz_encode: 253 bytes, usr->error called 1 time(s) during encode
  VERDICT: SERVER WOULD ABORT
  usr->error: image is bigger than window
window = 4095 pixels, image = 64x64 (4096 pixels)
  dictionary create: ok, errors so far = 0
  glz_encode: 253 bytes, usr->error called 1 time(s) during encode
  VERDICT: SERVER WOULD ABORT
window = 4096 pixels, image = 64x64 (4096 pixels)
  dictionary create: ok, errors so far = 0
  glz_encode: 253 bytes, usr->error called 0 time(s) during encode
  VERDICT: clean
window = 1048576 pixels, image = 64x64 (4096 pixels)
  dictionary create: ok, errors so far = 0
  glz_encode: 253 bytes, usr->error called 0 time(s) during encode
  VERDICT: clean
```

The boundary is exact and it is the thing worth taking away: the test is
`image_size > size_limit`, so the requirement is not "a non-zero window" but
**a window at least as large as the largest single image the server will
encode**. `__get_pixels_num` makes that `height * stride / bytes_per_pixel` for
RGB, and `can_lz_compress` has already refused anything with extra stride, so
for everything that reaches GLZ it is exactly width × height.

That is what fixes `SpiceDisplayClient.glzWindowPixels` at `1 << 23`: it is not
a judgement about how much history is worth keeping, it is one whole frame of
anything up to 3840×2160, decided before the guest's resolution is known.

The probe keeps encoding after the error so the output shows what the call
was; spice-server does not get that choice.

## To rebuild

The vendored headers, the clones and the object files are the ones
`scripts/spice-glz-fixtures/README.md` sets up — follow its **To rebuild**
section as far as `glz-encoder-dict.o`, then:

```sh
cp ../wisq/scripts/spice-glz-window/window-probe.c .
cc $CF -o gzwin window-probe.c glz-encoder.o glz-encoder-dict.o \
   $(pkg-config --libs glib-2.0) -lpthread
./gzwin 0 64 64
```

Nothing here is generated into the build. The number this justifies is a
constant in Swift with the reasoning next to it; this is what lets someone
disbelieve it.
