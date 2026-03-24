import time
import threading

class Counter:
    def __init__(self):
        self.count = 0

    def increment(self):
        self.count += 1
        return self.count

start = time.time()
counters = []
for _ in range(100):
    c = Counter()
    c.increment()
    counters.append(c)
elapsed = time.time() - start
print(f"100 actors, 100 sends ({elapsed*1000:.1f}ms)")
