import time

class Node:
    def __init__(self):
        self.hops = 0

    def pass_token(self, token):
        self.hops += 1
        return token + 1

start = time.time()
nodes = [Node() for _ in range(10)]
total = 0
for _ in range(100):
    for node in nodes:
        total = node.pass_token(total)
elapsed = time.time() - start
print(f"{total} ({elapsed*1000:.1f}ms)")
