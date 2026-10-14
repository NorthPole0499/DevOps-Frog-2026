import os
import threading
import time

# Потребление задаётся через env — чтобы менять из values.yaml, не трогая код
MEMORY_MB = int(os.getenv("MEMORY_MB", "200"))
CPU_WORKERS = int(os.getenv("CPU_WORKERS", "1"))
CHUNK_MB = 10

_held = []  # держим аллокации живыми


def cpu_burn():
    """Бесконечный CPU-цикл, результат никому не нужен."""
    while True:
        acc = 0
        for i in range(50_000_000):
            acc += (i * i) % 7
        # acc не используется — просто чтобы компилятор/интерпретатор не выкинул цикл


def mem_alloc():
    """Постепенно аллоцируем до MEMORY_MB и держим."""
    target = MEMORY_MB * 1024 * 1024
    allocated = 0
    while allocated < target:
        _held.append(bytearray(CHUNK_MB * 1024 * 1024))
        allocated += CHUNK_MB * 1024 * 1024
        time.sleep(0.2)
    # периодически «трогаем» страницы, чтобы память оставалась резидентной
    while True:
        for buf in _held:
            buf[0] = 1
        time.sleep(5)


if __name__ == "__main__":
    print(f"batch: MEMORY_MB={MEMORY_MB} CPU_WORKERS={CPU_WORKERS}", flush=True)
    for _ in range(CPU_WORKERS):
        threading.Thread(target=cpu_burn, daemon=True).start()
    mem_alloc()