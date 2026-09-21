/* abort and abs, the only stdlib entries the corpus sources call. */
#ifndef CORPUS_STDLIB_H
#define CORPUS_STDLIB_H
#include <stddef.h>
void abort(void);
int abs(int v);
#endif
