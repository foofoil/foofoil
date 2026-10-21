#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--version") != 0) return 2;
    puts("fixture-tool 1");
    return 0;
}
