#pragma once
#include <string>
#include <vector>
#include <stdexcept>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

// .NET starts workers with a Unicode command line. Keep the JSON and native
// model APIs UTF-8, including profiles whose Windows user name is not ASCII.
inline std::wstring voice_wide_path(const std::string &text) {
    if (text.empty()) return {};
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         text.data(), int(text.size()), nullptr, 0);
    if (!count) throw std::runtime_error("Invalid UTF-8 file path.");
    std::wstring wide(size_t(count), L'\0');
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), int(text.size()), wide.data(), count))
        throw std::runtime_error("Cannot convert file path.");
    return wide;
}
inline int voice_windows_entry(int argc, wchar_t **argv, int (*run)(int, char **)) {
    try {
        std::vector<std::string> strings;
        strings.reserve(size_t(argc));
        for (int i = 0; i < argc; ++i) {
            const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[i], -1, nullptr, 0, nullptr, nullptr);
            if (!count) return 2;
            std::string value(size_t(count), '\0');
            if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[i], -1, value.data(), count, nullptr, nullptr)) return 2;
            value.pop_back();
            strings.push_back(std::move(value));
        }
        std::vector<char *> pointers;
        pointers.reserve(size_t(argc) + 1);
        for (auto &s : strings) pointers.push_back(s.data());
        pointers.push_back(nullptr);
        return run(argc, pointers.data());
    } catch (...) { return 2; }
}
#define VOICE_MAIN voice_main
#define VOICE_WINDOWS_ENTRY int wmain(int argc, wchar_t **argv) { return voice_windows_entry(argc, argv, voice_main); }
#else
#define VOICE_MAIN main
#define VOICE_WINDOWS_ENTRY
#endif
