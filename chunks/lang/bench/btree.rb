def tree_build(depth)
  return 1 if depth == 0
  left = tree_build(depth - 1)
  right = tree_build(depth - 1)
  left + right + 1
end
puts tree_build(25)
