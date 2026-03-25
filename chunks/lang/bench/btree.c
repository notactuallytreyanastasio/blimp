#include <stdio.h>
long long tree_build(long long depth) {
    if (depth == 0) return 1;
    long long left = tree_build(depth - 1);
    long long right = tree_build(depth - 1);
    return left + right + 1;
}
int main() {
    printf("%lld\n", tree_build(25));
    return 0;
}
