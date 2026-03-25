import sys
sys.setrecursionlimit(1000000)
def abs_val(x):
    return x if x >= 0 else -x
def manhattan(x1, y1, x2, y2):
    return abs_val(x1 - x2) + abs_val(y1 - y2)
def grid_row(y, cols, qx, qy):
    if cols == 0: return 0
    return manhattan(cols, y, qx, qy) + grid_row(y, cols - 1, qx, qy)
def grid_distances(n, qx, qy):
    if n == 0: return 0
    return grid_row(n, n, qx, qy) + grid_distances(n - 1, qx, qy)
print(grid_distances(1000, 500, 500))
