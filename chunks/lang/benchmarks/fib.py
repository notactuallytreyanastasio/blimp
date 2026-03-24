import time

def fib(n):
    if n <= 1:
        return n
    return fib(n - 1) + fib(n - 2)

start = time.time()
result = fib(30)
elapsed = time.time() - start
print(f"{result} ({elapsed*1000:.1f}ms)")
