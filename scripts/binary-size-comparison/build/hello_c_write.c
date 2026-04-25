#include <unistd.h>
int main() {
    write(2, "Hello, World!\n", 14);
    return 0;
}
