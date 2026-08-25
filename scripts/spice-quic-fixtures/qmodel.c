/* Dumps the adaptive model's fixed layout and its behaviour under a known
   sequence, so the Swift model is compared against the codec's own numbers.
   #includes quic.c because find_model_params, fill_model_structures,
   update_model and tabrand are all file-static there. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define main quic_main_unused
#include "quic.c"
#undef main

static void dumpLayout(int bpc) {
    unsigned ncounters, levels, nptrs, repfirst, firstsize, repnext, mulsize, nbuckets;
    Encoder e; memset(&e, 0, sizeof e);
    find_model_params(&e, bpc, &ncounters, &levels, &nptrs,
                      &repfirst, &firstsize, &repnext, &mulsize, &nbuckets);
    printf("layout bpc=%d ncounters=%u levels=%u nbuckets=%u repfirst=%u firstsize=%u repnext=%u mulsize=%u\n",
           bpc, ncounters, levels, nbuckets, repfirst, firstsize, repnext, mulsize);

    /* Which bucket each value lands in, by replaying fill_model_structures'
       own walk rather than guessing at it. */
    FamilyStat fs;
    fs.buckets_ptrs = calloc(nptrs, sizeof(s_bucket *));
    fs.buckets_buf  = calloc(nbuckets, sizeof(s_bucket));
    fs.counters     = calloc((size_t)nbuckets * ncounters, sizeof(COUNTER));
    fill_model_structures(&e, &fs, repfirst, firstsize, repnext, mulsize,
                          levels, ncounters, nbuckets, nptrs);
    printf("buckets bpc=%d:", bpc);
    for (unsigned v = 0; v < levels; v++)
        printf(" %ld", (long)(fs.buckets_ptrs[v] - fs.buckets_buf));
    printf("\n");
}

int main(void) {
    family_init(&family_8bpc, 8, DEFmaxclen);
    family_init(&family_5bpc, 5, DEFmaxclen);

    dumpLayout(8);
    dumpLayout(5);

    /* tabrand from the codec's own starting seed. */
    unsigned seed = stabrand();
    printf("stabrand %u\n", seed);
    printf("tabrand:");
    for (int i = 0; i < 40; i++) printf(" %u", tabrand(&seed));
    printf("\n");

    /* wm_trigger across the whole index range, past the clamp. */
    printf("wmtrigger:");
    for (unsigned idx = 0; idx <= 12; idx++) {
        CommonState s; memset(&s, 0, sizeof s);
        s.wmidx = idx;
        set_wm_trigger(&s);
        printf(" %u", s.wm_trigger);
    }
    printf("\n");

    /* The halving boundary itself. `update_model` halves when the best total
       is strictly greater than the trigger, so the two readings of that
       comparison only differ when the total lands exactly on it. Setting the
       trigger directly is the only way to reach that: set_wm_trigger can only
       produce the eleven tabulated values. */
    {
        COUNTER counters[8]; memset(counters, 0, sizeof counters);
        s_bucket bucket = { counters, 0 };
        CommonState st; memset(&st, 0, sizeof st);
        /* First find what the best total is after one update of value 0. */
        st.wm_trigger = 0xFFFFFFFF;
        update_model_8bpc(&st, &bucket, 0);
        unsigned exact = counters[bucket.bestcode];
        printf("boundary exact=%u\n", exact);

        /* Replay from zero with the trigger set to precisely that total. */
        memset(counters, 0, sizeof counters);
        bucket.bestcode = 0;
        st.wm_trigger = exact;
        update_model_8bpc(&st, &bucket, 0);
        printf("boundary at=%u best=%u counters:", exact, bucket.bestcode);
        for (int c = 0; c < 8; c++) printf(" %u", counters[c]);
        printf("\n");

        /* And one below it, where halving must happen. */
        memset(counters, 0, sizeof counters);
        bucket.bestcode = 0;
        st.wm_trigger = exact - 1;
        update_model_8bpc(&st, &bucket, 0);
        printf("boundary below=%u best=%u counters:", exact - 1, bucket.bestcode);
        for (int c = 0; c < 8; c++) printf(" %u", counters[c]);
        printf("\n");
    }

    /* update_model, 8bpc, from zeroed counters, under a fixed sequence that
       crosses the halving threshold. */
    for (int bpc = 8; bpc >= 5; bpc -= 3) {
        COUNTER counters[8]; memset(counters, 0, sizeof counters);
        s_bucket bucket = { counters, 0 };
        CommonState st; memset(&st, 0, sizeof st);
        st.wmidx = 0;
        set_wm_trigger(&st);
        printf("update bpc=%d trigger=%u\n", bpc, st.wm_trigger);
        unsigned vals[] = {0, 1, 2, 3, 7, 15, 31, 63, 127, 255, 128, 64, 5, 5, 5, 200, 199, 1, 0, 250};
        for (unsigned i = 0; i < sizeof vals / sizeof *vals; i++) {
            BYTE v = (BYTE)(bpc == 8 ? vals[i] : (vals[i] & 0x1f));
            if (bpc == 8) update_model_8bpc(&st, &bucket, v);
            else          update_model_5bpc(&st, &bucket, v);
            printf("  v=%3u best=%u counters:", v, bucket.bestcode);
            for (int c = 0; c < bpc; c++) printf(" %u", counters[c]);
            printf("\n");
        }
    }
    return 0;
}
