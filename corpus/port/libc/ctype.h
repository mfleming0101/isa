/* The character classification the Embench sources call, defined in libc.c. */
#ifndef CORPUS_CTYPE_H
#define CORPUS_CTYPE_H
int tolower(int c);
int toupper(int c);
int isspace(int c);
int isdigit(int c);
int isalpha(int c);
int isxdigit(int c);
#endif
