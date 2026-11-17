// oriwarm: creates every DXBC shader in a folder, then draws each pipeline state listed in a plan file,
// so D3DMetal and Metal compile and cache them ahead of time.
//
// Usage: oriwarm_t.exe <shader dir> --plan <file> [--skipdraws N] [--sleep ms]
//
// Plan lines: <vs> <ps|-> <state> [input layout] [strides]
//   state         formats/DSV/blend/depth/samples, e.g. 26,28/T/1,5,6,1,5,6,1,15/1,0,4/1
//                 formats  DXGI formats of the bound render targets
//                 DSV      D (D32) S (D24S8) T (D32S8) N (none)
//                 blend    enable,src,dst,op,srcA,dstA,opA,mask; one per target separated by '|'
//                 depth    enable,write,func
//   input layout  NAME,index,format,slot,offset,class,step;...
//   strides       s0,s1,...
// Progress and results are written to warm.log next to the executable.
#include <windows.h>
#include <d3d11.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <map>
#include <algorithm>
#include <fstream>
#include <sstream>

struct Elem { std::string name; UINT idx, sv, ct, reg; BYTE mask; };
struct Shader {
    std::string ck; std::vector<char> code; int type = -1;
    std::vector<Elem> in;
    ID3D11DeviceChild* obj = nullptr; ID3D11InputLayout* il = nullptr;
};

static FILE* L;
#define LOG(...) (fprintf(L, __VA_ARGS__), fflush(L))

static UINT u32(const std::vector<char>& b, size_t o) { UINT v = 0; if (o + 4 <= b.size()) memcpy(&v, &b[o], 4); return v; }

// Input signature. ISGN has 24-byte elements; ISG1 has 32-byte elements with a 4-byte stream field first.
static std::vector<Elem> parseSig(const std::vector<char>& b, size_t d, int stride, int pre) {
    std::vector<Elem> r; UINT n = u32(b, d);
    for (UINT i = 0; i < n && n < 256; i++) {
        size_t e = d + 8 + i * stride + pre;
        if (e + 24 > b.size()) break;
        UINT no = u32(b, e);
        Elem x; x.name = (d + no < b.size()) ? std::string(&b[d + no]) : "";
        x.idx = u32(b, e + 4); x.sv = u32(b, e + 8); x.ct = u32(b, e + 12); x.reg = u32(b, e + 16); x.mask = (BYTE)b[e + 20];
        r.push_back(x);
    }
    return r;
}

// A signature with a name offset outside its chunk, or two elements sharing register components, crashes
// D3DMetal's shader converter. Shaders like that are left out.
static bool badSig(const std::vector<char>& b, size_t o) {
    UINT sz = u32(b, o + 4), n = u32(b, o + 8); size_t d = o + 8; BYTE used[64] = {};
    for (UINT i = 0; i < n && i < 64; i++) {
        size_t e = d + 8 + i * 24; UINT no = u32(b, e), reg = u32(b, e + 16); BYTE m = e + 20 < b.size() ? b[e + 20] : 0;
        if (no >= sz || reg >= 64 || (used[reg] & m)) return true;
        used[reg] |= m;
    }
    return false;
}

// Sets s.type to the program type (0 pixel, 1 vertex, 5 compute), or -2 for a malformed signature.
static void parse(Shader& s) {
    const auto& b = s.code; UINT n = u32(b, 28);
    for (UINT i = 0; i < n && i < 64; i++) {
        size_t o = u32(b, 32 + 4 * i); if (o + 8 > b.size()) continue;
        std::string tag(&b[o], 4); size_t d = o + 8;
        if ((tag == "SHEX" || tag == "SHDR") && s.type != -2) s.type = u32(b, d) >> 16;
        else if (tag == "ISGN") { s.in = parseSig(b, d, 24, 0); if (badSig(b, o)) s.type = -2; }
        else if (tag == "ISG1") s.in = parseSig(b, d, 32, 4);
        else if (tag == "OSGN" && badSig(b, o)) s.type = -2;
    }
}

static DXGI_FORMAT inputFormat(UINT componentType, BYTE mask) {
    int w = (mask & 8) ? 4 : (mask & 4) ? 3 : (mask & 2) ? 2 : 1;
    static const DXGI_FORMAT F[3][4] = {
        {DXGI_FORMAT_R32_UINT, DXGI_FORMAT_R32G32_UINT, DXGI_FORMAT_R32G32B32_UINT, DXGI_FORMAT_R32G32B32A32_UINT},
        {DXGI_FORMAT_R32_SINT, DXGI_FORMAT_R32G32_SINT, DXGI_FORMAT_R32G32B32_SINT, DXGI_FORMAT_R32G32B32A32_SINT},
        {DXGI_FORMAT_R32_FLOAT, DXGI_FORMAT_R32G32_FLOAT, DXGI_FORMAT_R32G32B32_FLOAT, DXGI_FORMAT_R32G32B32A32_FLOAT}};
    return (componentType >= 1 && componentType <= 3) ? F[componentType - 1][w - 1] : DXGI_FORMAT_R32G32B32A32_FLOAT;
}

// Log the crash and exit without a debugger dialog; the caller restarts after the draw that crashed.
static LONG WINAPI onCrash(EXCEPTION_POINTERS* e) {
    LOG("CRASH code=0x%08lx addr=%p\n", e->ExceptionRecord->ExceptionCode, e->ExceptionRecord->ExceptionAddress);
    TerminateProcess(GetCurrentProcess(), 3); return EXCEPTION_EXECUTE_HANDLER;
}

// Render targets, depth buffer, blend and depth state for one plan state string.
struct State {
    std::vector<ID3D11RenderTargetView*> rtv; ID3D11DepthStencilView* dsv = nullptr;
    ID3D11BlendState* blend = nullptr; ID3D11DepthStencilState* depth = nullptr;
};

static State makeState(ID3D11Device* dev, const D3D11_TEXTURE2D_DESC& base, const std::string& spec) {
    State s;
    std::vector<std::string> f;
    for (size_t a = 0, b; a <= spec.size(); a = b + 1) { b = spec.find('/', a); if (b == std::string::npos) b = spec.size(); f.push_back(spec.substr(a, b - a)); }
    UINT samples = f.size() > 4 ? atoi(f[4].c_str()) : 1; if (!samples) samples = 1;

    for (const char* p = f[0].c_str(); *p;) {
        D3D11_TEXTURE2D_DESC d = base; d.Format = (DXGI_FORMAT)strtoul(p, (char**)&p, 10); d.SampleDesc.Count = samples;
        ID3D11Texture2D* t; ID3D11RenderTargetView* r = nullptr;
        if (SUCCEEDED(dev->CreateTexture2D(&d, nullptr, &t))) dev->CreateRenderTargetView(t, nullptr, &r);
        s.rtv.push_back(r); if (*p == ',') p++;
    }
    char dk = f.size() > 1 && !f[1].empty() ? f[1][0] : 'N';
    if (dk == 'D' || dk == 'S' || dk == 'T') {
        D3D11_TEXTURE2D_DESC d = base; d.BindFlags = D3D11_BIND_DEPTH_STENCIL; d.SampleDesc.Count = samples;
        d.Format = dk == 'S' ? DXGI_FORMAT_D24_UNORM_S8_UINT : dk == 'T' ? DXGI_FORMAT_D32_FLOAT_S8X24_UINT : DXGI_FORMAT_D32_FLOAT;
        ID3D11Texture2D* t;
        if (SUCCEEDED(dev->CreateTexture2D(&d, nullptr, &t))) dev->CreateDepthStencilView(t, nullptr, &s.dsv);
    }
    if (f.size() > 2 && !f[2].empty()) {
        D3D11_BLEND_DESC b = {}; int first = 0; size_t a = 0;
        for (;;) {
            size_t bar = f[2].find('|', a); std::string one = f[2].substr(a, bar == std::string::npos ? std::string::npos : bar - a);
            int v[8] = {0, 2, 1, 1, 2, 1, 1, 15}; sscanf(one.c_str(), "%d,%d,%d,%d,%d,%d,%d,%d", v, v + 1, v + 2, v + 3, v + 4, v + 5, v + 6, v + 7);
            for (int k = first; k < 8; k++) {
                auto& t = b.RenderTarget[k];
                t.BlendEnable = v[0]; t.SrcBlend = (D3D11_BLEND)v[1]; t.DestBlend = (D3D11_BLEND)v[2]; t.BlendOp = (D3D11_BLEND_OP)v[3];
                t.SrcBlendAlpha = (D3D11_BLEND)v[4]; t.DestBlendAlpha = (D3D11_BLEND)v[5]; t.BlendOpAlpha = (D3D11_BLEND_OP)v[6]; t.RenderTargetWriteMask = (UINT8)v[7];
            }
            if (bar == std::string::npos) break;
            b.IndependentBlendEnable = TRUE; first++; a = bar + 1;
        }
        dev->CreateBlendState(&b, &s.blend);
    }
    if (f.size() > 3 && !f[3].empty()) {
        int e = 1, w = 1, fn = 2; sscanf(f[3].c_str(), "%d,%d,%d", &e, &w, &fn);
        D3D11_DEPTH_STENCIL_DESC d = {}; d.DepthEnable = e; d.DepthWriteMask = (D3D11_DEPTH_WRITE_MASK)w; d.DepthFunc = (D3D11_COMPARISON_FUNC)fn;
        dev->CreateDepthStencilState(&d, &s.depth);
    }
    return s;
}

static ID3D11InputLayout* makeLayout(ID3D11Device* dev, const Shader& vs, const std::string& spec) {
    std::vector<std::string> names; std::vector<D3D11_INPUT_ELEMENT_DESC> ie;
    std::istringstream es(spec); std::string e;
    while (std::getline(es, e, ';')) {
        char n[64]; unsigned idx, fm, slot, off, cls, step;
        if (sscanf(e.c_str(), "%63[^,],%u,%u,%u,%u,%u,%u", n, &idx, &fm, &slot, &off, &cls, &step) != 7) continue;
        names.push_back(n); ie.push_back({nullptr, idx, (DXGI_FORMAT)fm, slot, off, (D3D11_INPUT_CLASSIFICATION)cls, step});
    }
    for (size_t i = 0; i < ie.size(); i++) ie[i].SemanticName = names[i].c_str();
    ID3D11InputLayout* il = nullptr;
    dev->CreateInputLayout(ie.data(), (UINT)ie.size(), vs.code.data(), vs.code.size(), &il);
    return il;
}

int main(int argc, char** argv) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX); SetUnhandledExceptionFilter(onCrash);
    char exe[MAX_PATH]; GetModuleFileNameA(nullptr, exe, MAX_PATH);
    std::string here(exe); here = here.substr(0, here.find_last_of('\\') + 1);
    L = fopen((here + "warm.log").c_str(), "w");

    std::string dir = argc > 1 ? argv[1] : "", planFile; size_t skipDraws = 0; DWORD sleepMs = 3000;
    for (int i = 2; i + 1 < argc; i++) {
        if (!strcmp(argv[i], "--plan")) planFile = argv[++i];
        else if (!strcmp(argv[i], "--skipdraws")) skipDraws = strtoul(argv[++i], nullptr, 10);
        else if (!strcmp(argv[i], "--sleep")) sleepMs = atoi(argv[++i]);
    }
    if (dir.empty() || planFile.empty()) { LOG("usage: oriwarm <shader dir> --plan <file> [--skipdraws N] [--sleep ms]\n"); return 1; }
    DWORD t0 = GetTickCount();

    // Load the shaders.
    std::vector<std::string> files; WIN32_FIND_DATAA fd;
    HANDLE h = FindFirstFileA((dir + "\\*.dxbc").c_str(), &fd);
    if (h != INVALID_HANDLE_VALUE) { do files.push_back(fd.cFileName); while (FindNextFileA(h, &fd)); FindClose(h); }
    std::sort(files.begin(), files.end());
    std::vector<Shader> all;
    for (auto& n : files) {
        Shader s; s.ck = n.substr(0, n.size() - 5);
        std::ifstream f(dir + "\\" + n, std::ios::binary);
        s.code.assign(std::istreambuf_iterator<char>(f), {});
        parse(s);
        if (s.type == -2) { LOG("MALFORMED SIG %s\n", s.ck.c_str()); continue; }
        if (s.type == 0 || s.type == 1 || s.type == 5) all.push_back(std::move(s));
    }
    LOG("loaded %zu shaders\n", all.size());

    // Device, a small offscreen target and a zeroed vertex buffer.
    ID3D11Device* dev; ID3D11DeviceContext* ctx; D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_0, got;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &fl, 1, D3D11_SDK_VERSION, &dev, &got, &ctx);
    LOG("D3D11CreateDevice hr=0x%08lx fl=0x%x\n", hr, got);
    if (FAILED(hr)) return 2;
    const UINT W = 64, H = 64;
    D3D11_TEXTURE2D_DESC td = {W, H, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET, 0, 0};
    ID3D11Texture2D *rt, *staging;
    dev->CreateTexture2D(&td, nullptr, &rt);
    D3D11_TEXTURE2D_DESC sd = td; sd.Usage = D3D11_USAGE_STAGING; sd.BindFlags = 0; sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    dev->CreateTexture2D(&sd, nullptr, &staging);
    D3D11_VIEWPORT vp = {0, 0, (float)W, (float)H, 0, 1}; ctx->RSSetViewports(1, &vp);
    std::vector<char> zeros(4096);
    D3D11_BUFFER_DESC bd = {4096, D3D11_USAGE_DEFAULT, D3D11_BIND_VERTEX_BUFFER, 0, 0, 0};
    D3D11_SUBRESOURCE_DATA init = {zeros.data(), 0, 0}; ID3D11Buffer* vb; dev->CreateBuffer(&bd, &init, &vb);
    ID3D11Buffer* vbs[8] = {vb, vb, vb, vb, vb, vb, vb, vb}; UINT offsets[8] = {}, stride = 16;
    ctx->IASetVertexBuffers(0, 1, vbs, &stride, offsets);
    ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

    // Create every shader. Each vertex shader also gets a default input layout built from its signature.
    size_t created[6] = {}, failed[6] = {}, layoutFailed = 0;
    for (auto& s : all) {
        const void* c = s.code.data(); SIZE_T n = s.code.size();
        if (s.type == 0) hr = dev->CreatePixelShader(c, n, nullptr, (ID3D11PixelShader**)&s.obj);
        else if (s.type == 1) hr = dev->CreateVertexShader(c, n, nullptr, (ID3D11VertexShader**)&s.obj);
        else hr = dev->CreateComputeShader(c, n, nullptr, (ID3D11ComputeShader**)&s.obj);
        if (FAILED(hr)) { s.obj = nullptr; failed[s.type]++; LOG("CREATE FAIL %s type %d hr=0x%08lx\n", s.ck.c_str(), s.type, hr); continue; }
        created[s.type]++;
        if (s.type != 1) continue;
        std::vector<D3D11_INPUT_ELEMENT_DESC> ie;
        for (auto& e : s.in) if (e.sv == 0) ie.push_back({e.name.c_str(), e.idx, inputFormat(e.ct, e.mask), 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0});
        if (!ie.empty() && FAILED(hr = dev->CreateInputLayout(ie.data(), (UINT)ie.size(), c, n, &s.il))) {
            s.il = nullptr; layoutFailed++; LOG("INPUTLAYOUT FAIL %s hr=0x%08lx\n", s.ck.c_str(), hr);
        }
    }
    DWORD tCreate = GetTickCount();

    // Draw the plan. DRAW lines carry a running index so a restarted run can skip what is already done.
    std::map<std::string, Shader*> byName; for (auto& s : all) if (s.obj) byName[s.ck] = &s;
    std::map<std::string, State> states; std::map<std::string, ID3D11InputLayout*> layouts;
    size_t draws = 0, seq = 0, unknown = 0;
    std::ifstream plan(planFile); std::string line;
    while (std::getline(plan, line)) {
        std::istringstream ls(line); std::string vsn, psn, spec, ilspec, strides; ls >> vsn >> psn >> spec >> ilspec >> strides;
        if (spec.empty()) continue;
        auto vi = byName.find(vsn), pi = byName.find(psn);
        if (vi == byName.end() || (psn != "-" && pi == byName.end())) { unknown++; continue; }
        Shader& vs = *vi->second; Shader* ps = psn == "-" ? nullptr : pi->second;

        auto si = states.find(spec); if (si == states.end()) si = states.emplace(spec, makeState(dev, td, spec)).first;
        State& st = si->second;
        ctx->OMSetRenderTargets((UINT)st.rtv.size(), st.rtv.data(), st.dsv);
        ctx->OMSetBlendState(st.blend, nullptr, 0xffffffff); ctx->OMSetDepthStencilState(st.depth, 0);

        ID3D11InputLayout* il = vs.il;
        if (!ilspec.empty() && ilspec != "-") {
            std::string key = vsn + " " + ilspec; auto li = layouts.find(key);
            if (li == layouts.end()) li = layouts.emplace(key, makeLayout(dev, vs, ilspec)).first;
            il = li->second;
            UINT s8[8] = {}; int ns = 0;
            std::istringstream ss(strides); std::string x; while (std::getline(ss, x, ',') && ns < 8) s8[ns++] = atoi(x.c_str());
            if (ns) ctx->IASetVertexBuffers(0, ns, vbs, s8, offsets);
        }

        if (seq++ < skipDraws) continue;
        LOG("DRAW %zu %s %s\n", seq - 1, vs.ck.c_str(), ps ? ps->ck.c_str() : "-");
        ctx->IASetInputLayout(il);
        ctx->VSSetShader((ID3D11VertexShader*)vs.obj, nullptr, 0);
        ctx->PSSetShader(ps ? (ID3D11PixelShader*)ps->obj : nullptr, nullptr, 0);
        ctx->Draw(3, 0); ctx->Flush(); draws++;
    }

    // Wait for the GPU, then give Metal time to finish compiling and write its cache.
    ctx->Flush(); ctx->CopyResource(staging, rt);
    D3D11_MAPPED_SUBRESOURCE m; if (SUCCEEDED(ctx->Map(staging, 0, D3D11_MAP_READ, 0, &m))) ctx->Unmap(staging, 0);
    DWORD tDraw = GetTickCount();
    Sleep(sleepMs);
    LOG("SUMMARY created ps %zu vs %zu cs %zu | failed ps %zu vs %zu cs %zu | layouts failed %zu | draws %zu | "
        "unknown shaders %zu | resumed after %zu | create %lu ms, draw %lu ms\n",
        created[0], created[1], created[5], failed[0], failed[1], failed[5], layoutFailed, draws, unknown, skipDraws, tCreate - t0, tDraw - tCreate);
    fclose(L);
    ExitProcess(0);
}
