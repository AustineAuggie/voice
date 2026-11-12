// Included inside diarize.cpp's anonymous namespace, after SpeakerError.
// Windows SDK headers must be included at global scope by the translation unit.
struct Audio {
    HANDLE file = INVALID_HANDLE_VALUE;
    HANDLE mapping = nullptr;
    void *mapped = nullptr;
    size_t bytes = 0;
    explicit Audio(const std::string &path) {
        file = CreateFileW(voice_wide_path(path).c_str(), GENERIC_READ, FILE_SHARE_READ,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
        if (file == INVALID_HANDLE_VALUE) throw SpeakerError("read-audio", "Could not open meeting audio.");
        try {
            BY_HANDLE_FILE_INFORMATION info{}; LARGE_INTEGER length{};
            if (GetFileType(file) != FILE_TYPE_DISK || !GetFileInformationByHandle(file, &info) ||
                (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
                !GetFileSizeEx(file, &length) || length.QuadPart < 0 || length.QuadPart % 4 != 0 ||
                uint64_t(length.QuadPart) / sizeof(float) > uint64_t(std::numeric_limits<int32_t>::max()))
                throw SpeakerError("invalid-audio", "Invalid or oversized float32 meeting audio.");
            bytes = size_t(length.QuadPart);
            if (bytes) {
                mapping = CreateFileMappingW(file, nullptr, PAGE_WRITECOPY, 0, 0, nullptr);
                if (mapping) mapped = MapViewOfFile(mapping, FILE_MAP_COPY, 0, 0, bytes);
                if (!mapped) throw SpeakerError("read-audio", "Cannot map meeting audio into memory.");
            }
        } catch (...) { release(); throw; }
    }
    void release() noexcept {
        if (mapped) { UnmapViewOfFile(mapped); mapped = nullptr; }
        if (mapping) { CloseHandle(mapping); mapping = nullptr; }
        if (file != INVALID_HANDLE_VALUE) { CloseHandle(file); file = INVALID_HANDLE_VALUE; }
    }
    ~Audio() { release(); }
    Audio(const Audio &) = delete;
    Audio &operator=(const Audio &) = delete;
    const float *samples() const { return static_cast<const float *>(mapped); }
    int32_t size() const { return int32_t(bytes / sizeof(float)); }
    bool prepare() {
        double peak = 0;
        for (int32_t i = 0; i < size(); ++i) {
            const float x = samples()[i];
            if (!std::isfinite(x)) throw SpeakerError("invalid-audio", "Meeting audio contains non-finite samples.");
            peak = std::max(peak, std::abs(double(x)));
        }
        // FILE_MAP_COPY never writes normalisation back to the recorded file.
        if (peak > 1) {
            auto writable = static_cast<float *>(mapped);
            for (int32_t i = 0; i < size(); ++i) writable[i] = float(double(writable[i]) / peak);
            std::cerr << "speaker-audio-normalized\n";
        }
        return peak > 0;
    }
};

struct PrivateResultSecurity {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), nullptr, FALSE};
    PrivateResultSecurity() {
        HANDLE token = nullptr;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
            throw SpeakerError("write-result", "Could not secure speaker result file.");
        DWORD bytes = 0;
        GetTokenInformation(token, TokenUser, nullptr, 0, &bytes);
        std::vector<unsigned char> data(bytes);
        const bool got = bytes && GetTokenInformation(token, TokenUser, data.data(), bytes, &bytes);
        CloseHandle(token);
        if (!got) throw SpeakerError("write-result", "Could not secure speaker result file.");
        LPWSTR sid = nullptr;
        if (!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER *>(data.data())->User.Sid, &sid))
            throw SpeakerError("write-result", "Could not secure speaker result file.");
        const std::wstring sddl = L"D:P(A;;GA;;;SY)(A;;GA;;;" + std::wstring(sid) + L")";
        LocalFree(sid);
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr))
            throw SpeakerError("write-result", "Could not secure speaker result file.");
        attributes.lpSecurityDescriptor = descriptor;
    }
    ~PrivateResultSecurity() { if (descriptor) LocalFree(descriptor); }
};

void writeResult(const std::string &path, const std::string &json) {
    const auto destination = voice_wide_path(path);
    const auto temporary = destination + L".pending-" + std::to_wstring(GetCurrentProcessId());
    PrivateResultSecurity security;
    HANDLE output = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, &security.attributes,
                                CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (output == INVALID_HANDLE_VALUE) throw SpeakerError("write-result", "Could not create speaker result file.");
    try {
        size_t position = 0;
        while (position < json.size()) {
            DWORD written = 0;
            const DWORD count = DWORD(std::min<size_t>(json.size() - position, 1024 * 1024));
            if (!WriteFile(output, json.data() + position, count, &written, nullptr) || !written)
                throw SpeakerError("write-result", "Could not write speaker result file.");
            position += written;
        }
        if (!FlushFileBuffers(output)) throw SpeakerError("write-result", "Could not save speaker result file.");
        CloseHandle(output); output = INVALID_HANDLE_VALUE;
        // Same-directory move is atomic; keep the completed result or the old
        // result, never a partially written JSON file. The private DACL moves.
        if (!MoveFileExW(temporary.c_str(), destination.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            throw SpeakerError("write-result", "Could not finish speaker result file.");
    } catch (...) {
        if (output != INVALID_HANDLE_VALUE) CloseHandle(output);
        DeleteFileW(temporary.c_str());
        throw;
    }
}
