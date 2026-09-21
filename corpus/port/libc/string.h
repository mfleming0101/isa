/* The memory and string primitives libc.c implements for the corpus. */
#ifndef CORPUS_STRING_H
#define CORPUS_STRING_H
#include <stddef.h>
void *memcpy(void *d, const void *s, size_t n);
void *memmove(void *d, const void *s, size_t n);
void *memset(void *d, int c, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
char *strchr(const char *s, int c);
int strcmp(const char *a, const char *b);
#endif
