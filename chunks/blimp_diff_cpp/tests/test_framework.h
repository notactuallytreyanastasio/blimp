#pragma once
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <functional>

struct Test {
    std::string name;
    std::function<void()> func;
};

inline std::vector<Test>& tests() {
    static std::vector<Test> t;
    return t;
}

inline int& failure_count() {
    static int f = 0;
    return f;
}

inline void register_test(const char* name, std::function<void()> func) {
    tests().push_back({name, func});
}

#define TEST(name) \
    void test_##name(); \
    static struct Register_##name { \
        Register_##name() { register_test(#name, test_##name); } \
    } reg_##name; \
    void test_##name()

#define ASSERT_EQ(a, b) do { \
    auto _a = (a); auto _b = (b); \
    if (_a != _b) { \
        fprintf(stderr, "  FAIL %s:%d: %s != %s\n", __FILE__, __LINE__, #a, #b); \
        failure_count()++; return; \
    } \
} while(0)

#define ASSERT_TRUE(x) do { \
    if (!(x)) { \
        fprintf(stderr, "  FAIL %s:%d: %s is false\n", __FILE__, __LINE__, #x); \
        failure_count()++; return; \
    } \
} while(0)

#define ASSERT_FALSE(x) do { \
    if ((x)) { \
        fprintf(stderr, "  FAIL %s:%d: %s is true\n", __FILE__, __LINE__, #x); \
        failure_count()++; return; \
    } \
} while(0)
