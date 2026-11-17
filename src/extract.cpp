// extract <game dir> <out dir>: dumps unique DXBC shader blobs (raw or LZ4-inside Unity
// Shader assets) from <game dir>/oriwotw_Data and UnityPlayer.dll as <checksum>_<sha1 prefix>.dxbc.
#include <CommonCrypto/CommonDigest.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <functional>
#include <set>
#include <string>
#include <vector>
namespace fs = std::filesystem;
typedef std::vector<uint8_t> Bytes;

static uint32_t u32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

static bool readFile(const fs::path &p, Bytes &b) {
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) return false;
    fseek(f, 0, SEEK_END); b.resize(ftell(f)); fseek(f, 0, SEEK_SET);
    bool ok = fread(b.data(), 1, b.size(), f) == b.size();
    fclose(f);
    return ok;
}

// Shader program type (0 pixel, 1 vertex, ... 5 compute), or -1 if the blob has no program chunk.
static int progType(const uint8_t *b, uint64_t len) {
    if (len < 32) return -1;
    uint64_t n = u32(b + 28);
    if (n > 64 || 32 + 4 * n > len) return -1;
    for (uint64_t i = 0; i < n; i++) {
        uint64_t off = u32(b + 32 + 4 * i);
        if (off + 12 <= len && (!memcmp(b + off, "SHEX", 4) || !memcmp(b + off, "SHDR", 4))) {
            int t = b[off + 10] | b[off + 11] << 8;
            return t <= 5 ? t : -1;
        }
    }
    return -1;
}

// LZ4 block decode. Fails on malformed input or if the output would exceed the expected size.
static bool lz4(const uint8_t *s, size_t n, size_t dec, Bytes &d) {
    size_t i = 0;
    for (;;) {
        if (i >= n) return false;
        unsigned t = s[i++]; size_t l = t >> 4;
        if (l == 15) for (;;) { if (i >= n) return false; unsigned b = s[i++]; l += b; if (b != 255) break; }
        if (l > n - i) return false;
        d.insert(d.end(), s + i, s + i + l); i += l;
        if (i == n) return true;
        if (i + 1 >= n) return false;
        size_t off = s[i] | s[i + 1] << 8; i += 2;
        if (off == 0 || off > d.size()) return false;
        size_t m = t & 15;
        if (m == 15) for (;;) { if (i >= n) return false; unsigned b = s[i++]; m += b; if (b != 255) break; }
        m += 4;
        size_t cur = d.size();
        if (cur + m > dec) return false;
        d.resize(cur + m);
        for (size_t k = 0; k < m; k++) d[cur + k] = d[cur + k - off];
    }
}

static void dxbcs(const uint8_t *buf, size_t len, bool rawOnly, const std::function<void(const uint8_t *, size_t)> &fn) {
    const uint8_t *j = (const uint8_t *)memmem(buf, len, "DXBC", 4);
    while (j) {
        size_t pos = j - buf;
        uint64_t sz = pos + 28 <= len ? u32(j + 24) : 0;
        if (32 <= sz && sz <= len - pos && (!rawOnly || progType(j, sz) >= 0)) fn(j, sz);
        size_t next = pos + 4;
        j = next <= len ? (const uint8_t *)memmem(buf + next, len - next, "DXBC", 4) : nullptr;
    }
}

static void blobs(const Bytes &data, const std::function<void(const uint8_t *, size_t)> &fn) {
    dxbcs(data.data(), data.size(), true, fn);
    size_t len = data.size();
    // Scan for the 36-byte header Unity writes before a compressed shader blob.
    for (size_t i = 0; i + 36 <= len;) {
        const uint8_t *p = &data[i];
        // layout: 0:01000000 4:(.) 5:000000 8:01000000 12:00000000 16:01000000 20:comp 24:01000000 28:dec 32:L
        static const uint8_t A[4] = {1, 0, 0, 0}, B[3] = {0, 0, 0}, C[12] = {1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0};
        if (memcmp(p, A, 4) || memcmp(p + 5, B, 3) || memcmp(p + 8, C, 12) || memcmp(p + 24, A, 4)) { i++; continue; }
        uint64_t comp = u32(p + 20), dec = u32(p + 28), L = u32(p + 32), pe = i + 36;
        i = pe;
        if (!(16 <= comp && comp <= L && L <= len - pe && dec >= comp)) continue;
        Bytes out;
        if (!lz4(&data[pe], comp, dec, out) || out.size() != dec) continue;
        dxbcs(out.data(), out.size(), false, fn);
    }
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: extract <game dir> <out dir>\n"); return 2; }
    fs::path game = argv[1], outDir = argv[2], dataDir = game / "oriwotw_Data", dll = game / "UnityPlayer.dll";
    std::error_code ec;
    if (!fs::is_directory(dataDir, ec)) { fprintf(stderr, "error: data dir missing: %s\n", dataDir.c_str()); return 1; }
    if (!fs::is_regular_file(dll, ec)) { fprintf(stderr, "error: missing %s\n", dll.c_str()); return 1; }
    fs::create_directories(outDir, ec);
    if (!fs::is_directory(outDir, ec)) { fprintf(stderr, "error: cannot create %s\n", outDir.c_str()); return 1; }

    std::vector<fs::path> files;
    for (fs::recursive_directory_iterator it(dataDir, ec), end; it != end; it.increment(ec)) {
        if (it->is_directory()) { if (it->path().filename() == "Plugins") it.disable_recursion_pending(); continue; }
        std::string f = it->path().filename();
        auto sw = [&](const char *s) { return f.rfind(s, 0) == 0; };
        bool ends = f.size() >= 7 && f.compare(f.size() - 7, 7, ".assets") == 0;
        if (ends || ((sw("level") || sw("globalgamemanagers")) && f.find('.') == std::string::npos) ||
            f == "unity default resources" || f == "unity_builtin_extra") files.push_back(it->path());
    }
    if (ec) { fprintf(stderr, "error: walking %s: %s\n", dataDir.c_str(), ec.message().c_str()); return 1; }

    size_t total = files.size() + 1, done = 0, written = 0;
    std::set<std::string> seen;
    auto emit = [&](const uint8_t *b, size_t n, bool dllBlob) {
        static const char *hex = "0123456789abcdef";
        uint8_t h[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1(b, (CC_LONG)n, h);
        std::string ck;
        for (int k = 4; k < 20; k++) { ck += hex[b[k] >> 4]; ck += hex[b[k] & 15]; }
        ck += '_';
        for (int k = 0; k < 4; k++) { ck += hex[h[k] >> 4]; ck += hex[h[k] & 15]; }
        if (!seen.insert(ck).second) return;
        if (!dllBlob && progType(b, n) < 0) return;
        FILE *f = fopen((outDir / (ck + ".dxbc")).c_str(), "wb");
        if (!f || fwrite(b, 1, n, f) != n) { fprintf(stderr, "error: writing %s\n", ck.c_str()); exit(1); }
        fclose(f); written++;
    };
    for (auto &p : files) {
        Bytes data;
        if (!readFile(p, data)) { fprintf(stderr, "error: reading %s\n", p.c_str()); return 1; }
        blobs(data, [&](const uint8_t *b, size_t n) { emit(b, n, false); });
        printf("PROGRESS %zu %zu\n", ++done, total); fflush(stdout);
    }
    Bytes data;
    if (!readFile(dll, data)) { fprintf(stderr, "error: reading %s\n", dll.c_str()); return 1; }
    dxbcs(data.data(), data.size(), true, [&](const uint8_t *b, size_t n) { emit(b, n, true); });
    printf("PROGRESS %zu %zu\n", ++done, total);
    printf("DONE %zu\n", written); fflush(stdout);
}
