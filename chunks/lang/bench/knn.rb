def abs_val(x)
  x >= 0 ? x : -x
end
def manhattan(x1, y1, x2, y2)
  abs_val(x1 - x2) + abs_val(y1 - y2)
end
def grid_row(y, cols, qx, qy)
  return 0 if cols == 0
  manhattan(cols, y, qx, qy) + grid_row(y, cols - 1, qx, qy)
end
def grid_distances(n, qx, qy)
  return 0 if n == 0
  grid_row(n, n, qx, qy) + grid_distances(n - 1, qx, qy)
end
puts grid_distances(1000, 500, 500)
