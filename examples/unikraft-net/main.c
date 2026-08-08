#include <stdio.h>

extern void koru_main(void);

int main(int argc, char *argv[])
{
	(void) argc; (void) argv;
	koru_main();
	return 0;
}
