#include "test_framework.h"

int main() {
    int passed = 0;
    int failed = 0;

    for (auto& t : tests()) {
        int before = failure_count();
        t.func();
        if (failure_count() > before) {
            fprintf(stderr, "FAIL: %s\n", t.name.c_str());
            failed++;
        } else {
            printf("  ok: %s\n", t.name.c_str());
            passed++;
        }
    }

    printf("\n%d passed, %d failed\n", passed, failed);
    return failed > 0 ? 1 : 0;
}
