/* The runtime every corpus image is linked against: a console buffer, a deterministic clock, the
   CRC the run ends with, and the exit the start code jumps to. Declared here, defined in port.c
   and start.S. */
#ifndef CORPUS_PORT_H
#define CORPUS_PORT_H
#define CONSOLE_SIZE 4096
extern char console[CONSOLE_SIZE];
extern unsigned console_len;
unsigned bench_clock(void);
void console_put(char c);
unsigned console_crc(void);
void bench_exit(unsigned code);
#endif
