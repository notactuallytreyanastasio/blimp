import sys
sys.setrecursionlimit(3000000)
def tree_build(depth):
    if depth == 0: return 1
    left = tree_build(depth - 1)
    right = tree_build(depth - 1)
    return left + right + 1
print(tree_build(25))
