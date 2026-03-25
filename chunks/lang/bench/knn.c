#include <stdio.h>
#include <stdlib.h>
long long abs_val(long long x) { return x >= 0 ? x : -x; }
long long manhattan(long long x1, long long y1, long long x2, long long y2) {
    return abs_val(x1 - x2) + abs_val(y1 - y2);
}
long long grid_row(long long y, long long cols, long long qx, long long qy) {
    if (cols == 0) return 0;
    return manhattan(cols, y, qx, qy) + grid_row(y, cols - 1, qx, qy);
}
long long grid_distances(long long n, long long qx, long long qy) {
    if (n == 0) return 0;
    return grid_row(n, n, qx, qy) + grid_distances(n - 1, qx, qy);
}
int main() {
    printf("%lld\n", grid_distances(1000, 500, 500));
    return 0;
}
