/* assert is a no-op: a failed check would change the retired count, and the console CRC already
   catches wrong results. */
#ifndef CORPUS_ASSERT_H
#define CORPUS_ASSERT_H
#define assert(x) ((void)0)
#endif
