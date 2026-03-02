/**
 * SecurityEngine.cpp
 * セキュリティエンジン DLL
 * 機能:
 *   1. システムジャンクファイルのスキャン・クリーンアップ
 *   2. 壊れた / 孤立したレジストリキーの検出・修復
 *
 * コンパイル例 (MinGW / cross-compiler on Linux):
 *   x86_64-w64-mingw32-g++ -shared -o SecurityEngine.dll SecurityEngine.cpp
 *       -DSECURITYENGINE_EXPORTS -ladvapi32 -lshlwapi -lshell32
 *
 * Windows MSVC:
 *   cl /LD SecurityEngine.cpp /DSECURITYENGINE_EXPORTS
 *       /link advapi32.lib shlwapi.lib shell32.lib
 */

#define SECURITYENGINE_EXPORTS
#include "../include/SecurityEngine.h"

#include <windows.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <winreg.h>
#include <shellapi.h>

#include <string>
#include <vector>
#include <algorithm>
#include <ctime>
#include <cwchar>

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "shell32.lib")

// ============================================================
// 内部ユーティリティ
// ============================================================

static std::wstring GetSpecialFolder(int csidl)
{
    wchar_t path[MAX_PATH] = {};
    SHGetFolderPathW(nullptr, csidl, nullptr, SHGFP_TYPE_CURRENT, path);
    return path;
}

static std::wstring GetEnvW(const wchar_t* name)
{
    wchar_t buf[MAX_PATH] = {};
    GetEnvironmentVariableW(name, buf, MAX_PATH);
    return buf;
}

// ディレクトリ内のファイルを再帰的に列挙し JunkFileInfo に追加
static void EnumerateFiles(const std::wstring& dir,
                           const wchar_t* category,
                           std::vector<JunkFileInfo>& result,
                           int maxCount)
{
    if ((int)result.size() >= maxCount) return;

    std::wstring pattern = dir + L"\\*";
    WIN32_FIND_DATAW fd;
    HANDLE hFind = FindFirstFileW(pattern.c_str(), &fd);
    if (hFind == INVALID_HANDLE_VALUE) return;

    do {
        if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0)
            continue;

        std::wstring fullPath = dir + L"\\" + fd.cFileName;

        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            EnumerateFiles(fullPath, category, result, maxCount);
        } else {
            if ((int)result.size() >= maxCount) break;
            JunkFileInfo info = {};
            wcsncpy_s(info.path, fullPath.c_str(), MAX_PATH - 1);
            LARGE_INTEGER li;
            li.HighPart = (LONG)fd.nFileSizeHigh;
            li.LowPart  = fd.nFileSizeLow;
            info.sizeBytes = li.QuadPart;
            wcsncpy_s(info.category, category, 63);
            result.push_back(info);
        }
    } while (FindNextFileW(hFind, &fd) && (int)result.size() < maxCount);

    FindClose(hFind);
}

// ============================================================
// ジャンクファイル スキャン
// ============================================================

extern "C" SEC_API int ScanJunkFiles(JunkFileInfo* outBuffer, int maxCount)
{
    if (!outBuffer || maxCount <= 0) return 0;

    std::vector<JunkFileInfo> results;
    results.reserve(256);

    // 1. %TEMP% ディレクトリ
    std::wstring tempDir = GetEnvW(L"TEMP");
    if (!tempDir.empty())
        EnumerateFiles(tempDir, L"TempFiles", results, maxCount);

    // 2. Windows Temp
    wchar_t winDir[MAX_PATH] = {};
    GetWindowsDirectoryW(winDir, MAX_PATH);
    std::wstring winTemp = std::wstring(winDir) + L"\\Temp";
    EnumerateFiles(winTemp, L"WindowsTemp", results, maxCount);

    // 3. Prefetch
    std::wstring prefetch = std::wstring(winDir) + L"\\Prefetch";
    EnumerateFiles(prefetch, L"Prefetch", results, maxCount);

    // 4. ブラウザキャッシュ (Chrome)
    std::wstring localAppData = GetEnvW(L"LOCALAPPDATA");
    if (!localAppData.empty()) {
        std::wstring chromeCache = localAppData +
            L"\\Google\\Chrome\\User Data\\Default\\Cache";
        EnumerateFiles(chromeCache, L"BrowserCache_Chrome", results, maxCount);

        // Edge
        std::wstring edgeCache = localAppData +
            L"\\Microsoft\\Edge\\User Data\\Default\\Cache";
        EnumerateFiles(edgeCache, L"BrowserCache_Edge", results, maxCount);
    }

    // 5. ごみ箱 (SHQueryRecycleBin で取得)
    SHQUERYRBINFO rbInfo = {};
    rbInfo.cbSize = sizeof(rbInfo);
    if (SUCCEEDED(SHQueryRecycleBinW(nullptr, &rbInfo))) {
        // ごみ箱はファイル個別列挙が複雑なため、代表エントリとして1件追加
        if (rbInfo.i64NumItems > 0 && (int)results.size() < maxCount) {
            JunkFileInfo rb = {};
            wcsncpy_s(rb.path, L"$RECYCLE.BIN", MAX_PATH - 1);
            rb.sizeBytes = rbInfo.i64Size;
            wcsncpy_s(rb.category, L"RecycleBin", 63);
            results.push_back(rb);
        }
    }

    int count = std::min((int)results.size(), maxCount);
    for (int i = 0; i < count; i++)
        outBuffer[i] = results[i];

    return count;
}

// ============================================================
// ジャンクファイル クリーンアップ
// ============================================================

extern "C" SEC_API BOOL CleanJunkFiles(const JunkFileInfo* items,
                                        int count,
                                        LONGLONG* bytesFreed)
{
    if (!items || count <= 0) return FALSE;

    LONGLONG freed = 0;
    for (int i = 0; i < count; i++) {
        const JunkFileInfo& info = items[i];

        // ごみ箱は専用 API で空にする
        if (wcscmp(info.path, L"$RECYCLE.BIN") == 0) {
            if (SUCCEEDED(SHEmptyRecycleBinW(nullptr, nullptr,
                SHERB_NOCONFIRMATION | SHERB_NOPROGRESSUI | SHERB_NOSOUND))) {
                freed += info.sizeBytes;
            }
            continue;
        }

        // 通常ファイル削除
        DWORD attr = GetFileAttributesW(info.path);
        if (attr == INVALID_FILE_ATTRIBUTES) continue;

        // 読み取り専用属性を外す
        if (attr & FILE_ATTRIBUTE_READONLY)
            SetFileAttributesW(info.path, attr & ~FILE_ATTRIBUTE_READONLY);

        if (DeleteFileW(info.path))
            freed += info.sizeBytes;
    }

    if (bytesFreed) *bytesFreed = freed;
    return TRUE;
}

// ============================================================
// ジャンク合計サイズ取得
// ============================================================

extern "C" SEC_API LONGLONG GetTotalJunkSize()
{
    const int MAX_ITEMS = 8192;
    std::vector<JunkFileInfo> buf(MAX_ITEMS);
    int count = ScanJunkFiles(buf.data(), MAX_ITEMS);

    LONGLONG total = 0;
    for (int i = 0; i < count; i++)
        total += buf[i].sizeBytes;
    return total;
}

// ============================================================
// レジストリ スキャン
// ============================================================

// 指定キー配下の値を検査し、問題があれば RegistryIssue を追加
static void CheckRegistryKey(HKEY hRoot,
                              const std::wstring& subKey,
                              const wchar_t* issueType,
                              std::vector<RegistryIssue>& issues,
                              int maxCount)
{
    if ((int)issues.size() >= maxCount) return;

    HKEY hKey = nullptr;
    if (RegOpenKeyExW(hRoot, subKey.c_str(), 0, KEY_READ, &hKey) != ERROR_SUCCESS)
        return;

    DWORD valueCount = 0, maxValueNameLen = 0, maxValueLen = 0;
    RegQueryInfoKeyW(hKey, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
                     &valueCount, &maxValueNameLen, &maxValueLen, nullptr, nullptr);

    for (DWORD i = 0; i < valueCount && (int)issues.size() < maxCount; i++) {
        wchar_t valueName[256] = {};
        DWORD nameLen = 256;
        DWORD type = 0;
        BYTE  data[MAX_PATH * 2] = {};
        DWORD dataLen = sizeof(data);

        if (RegEnumValueW(hKey, i, valueName, &nameLen,
                          nullptr, &type, data, &dataLen) != ERROR_SUCCESS)
            continue;

        // REG_SZ / REG_EXPAND_SZ のみ検査
        if (type != REG_SZ && type != REG_EXPAND_SZ) continue;

        wchar_t expanded[MAX_PATH] = {};
        ExpandEnvironmentStringsW((wchar_t*)data, expanded, MAX_PATH);

        // パスが存在するか確認
        // ファイルパスらしい文字列 (ドライブレター or UNC) のみ対象
        bool looksLikePath = (wcslen(expanded) >= 3 &&
                              ((expanded[1] == L':') ||
                               (expanded[0] == L'\\' && expanded[1] == L'\\')));

        if (!looksLikePath) continue;

        // 引数部分を除去してパス本体を取得
        std::wstring pathStr(expanded);
        // 引用符を除去
        if (!pathStr.empty() && pathStr[0] == L'"') {
            size_t end = pathStr.find(L'"', 1);
            if (end != std::wstring::npos)
                pathStr = pathStr.substr(1, end - 1);
        } else {
            // スペースで分割して最初のトークン
            size_t sp = pathStr.find(L' ');
            if (sp != std::wstring::npos)
                pathStr = pathStr.substr(0, sp);
        }

        if (!PathFileExistsW(pathStr.c_str())) {
            RegistryIssue issue = {};
            std::wstring fullKey = (hRoot == HKEY_LOCAL_MACHINE ? L"HKLM\\" :
                                    hRoot == HKEY_CURRENT_USER  ? L"HKCU\\" : L"HK?\\")
                                   + subKey;
            wcsncpy_s(issue.keyPath,    fullKey.c_str(),   511);
            wcsncpy_s(issue.valueName,  valueName,         255);
            wcsncpy_s(issue.issueType,  issueType,         127);

            std::wstring desc = L"参照先ファイルが存在しません: " + pathStr;
            wcsncpy_s(issue.description, desc.c_str(), 511);
            issue.severity = 2;
            issues.push_back(issue);
        }
    }

    RegCloseKey(hKey);
}

// スタートアップ エントリの孤立チェック
static void ScanStartupKeys(std::vector<RegistryIssue>& issues, int maxCount)
{
    const wchar_t* startupPaths[] = {
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run",
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\RunOnce",
        L"SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Run",
    };
    for (auto& path : startupPaths) {
        CheckRegistryKey(HKEY_LOCAL_MACHINE, path, L"OrphanedStartup", issues, maxCount);
        CheckRegistryKey(HKEY_CURRENT_USER,  path, L"OrphanedStartup", issues, maxCount);
    }
}

// アンインストール エントリの孤立チェック
static void ScanUninstallKeys(std::vector<RegistryIssue>& issues, int maxCount)
{
    const wchar_t* uninstPaths[] = {
        L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
        L"SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
    };

    for (auto& basePath : uninstPaths) {
        HKEY hBase = nullptr;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, basePath, 0, KEY_READ, &hBase) != ERROR_SUCCESS)
            continue;

        DWORD subKeyCount = 0;
        RegQueryInfoKeyW(hBase, nullptr, nullptr, nullptr, &subKeyCount,
                         nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);

        for (DWORD i = 0; i < subKeyCount && (int)issues.size() < maxCount; i++) {
            wchar_t subName[256] = {};
            DWORD nameLen = 256;
            if (RegEnumKeyExW(hBase, i, subName, &nameLen,
                              nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS)
                continue;

            std::wstring fullSub = std::wstring(basePath) + L"\\" + subName;

            // InstallLocation / DisplayIcon を検査
            HKEY hSub = nullptr;
            if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, fullSub.c_str(),
                              0, KEY_READ, &hSub) != ERROR_SUCCESS)
                continue;

            auto checkVal = [&](const wchar_t* valName) {
                wchar_t data[MAX_PATH] = {};
                DWORD dataLen = sizeof(data);
                DWORD type = 0;
                if (RegQueryValueExW(hSub, valName, nullptr, &type,
                                     (LPBYTE)data, &dataLen) != ERROR_SUCCESS) return;
                if (type != REG_SZ && type != REG_EXPAND_SZ) return;

                wchar_t expanded[MAX_PATH] = {};
                ExpandEnvironmentStringsW(data, expanded, MAX_PATH);

                // 引数除去
                std::wstring p(expanded);
                if (!p.empty() && p[0] == L'"') {
                    size_t e = p.find(L'"', 1);
                    if (e != std::wstring::npos) p = p.substr(1, e - 1);
                } else {
                    size_t sp = p.find(L' ');
                    if (sp != std::wstring::npos) p = p.substr(0, sp);
                }

                if (p.size() >= 3 && p[1] == L':' && !PathFileExistsW(p.c_str())) {
                    if ((int)issues.size() >= maxCount) return;
                    RegistryIssue issue = {};
                    std::wstring fk = L"HKLM\\" + fullSub;
                    wcsncpy_s(issue.keyPath,   fk.c_str(),   511);
                    wcsncpy_s(issue.valueName, valName,      255);
                    wcsncpy_s(issue.issueType, L"OrphanedUninstall", 127);
                    std::wstring desc = L"インストール先が存在しません: " + p;
                    wcsncpy_s(issue.description, desc.c_str(), 511);
                    issue.severity = 1;
                    issues.push_back(issue);
                }
            };

            checkVal(L"InstallLocation");
            checkVal(L"DisplayIcon");
            RegCloseKey(hSub);
        }
        RegCloseKey(hBase);
    }
}

// ファイル拡張子の関連付けチェック
static void ScanFileAssociations(std::vector<RegistryIssue>& issues, int maxCount)
{
    // HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts
    const wchar_t* basePath =
        L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts";

    HKEY hBase = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, basePath, 0, KEY_READ, &hBase) != ERROR_SUCCESS)
        return;

    DWORD subKeyCount = 0;
    RegQueryInfoKeyW(hBase, nullptr, nullptr, nullptr, &subKeyCount,
                     nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr);

    for (DWORD i = 0; i < subKeyCount && (int)issues.size() < maxCount; i++) {
        wchar_t ext[64] = {};
        DWORD nameLen = 64;
        if (RegEnumKeyExW(hBase, i, ext, &nameLen,
                          nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS)
            continue;

        // UserChoice サブキーの ProgId を取得
        std::wstring ucPath = std::wstring(basePath) + L"\\" + ext + L"\\UserChoice";
        HKEY hUC = nullptr;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, ucPath.c_str(),
                          0, KEY_READ, &hUC) != ERROR_SUCCESS)
            continue;

        wchar_t progId[256] = {};
        DWORD dataLen = sizeof(progId);
        DWORD type = 0;
        if (RegQueryValueExW(hUC, L"ProgId", nullptr, &type,
                             (LPBYTE)progId, &dataLen) == ERROR_SUCCESS) {
            // HKCR に ProgId が存在するか
            HKEY hProgId = nullptr;
            if (RegOpenKeyExW(HKEY_CLASSES_ROOT, progId, 0,
                              KEY_READ, &hProgId) != ERROR_SUCCESS) {
                if ((int)issues.size() < maxCount) {
                    RegistryIssue issue = {};
                    std::wstring fk = L"HKCU\\" + ucPath;
                    wcsncpy_s(issue.keyPath,   fk.c_str(),  511);
                    wcsncpy_s(issue.valueName, L"ProgId",   255);
                    wcsncpy_s(issue.issueType, L"InvalidFileAssociation", 127);
                    std::wstring desc = std::wstring(L"拡張子 ") + ext +
                                        L" の関連付け ProgId が無効: " + progId;
                    wcsncpy_s(issue.description, desc.c_str(), 511);
                    issue.severity = 2;
                    issues.push_back(issue);
                }
            } else {
                RegCloseKey(hProgId);
            }
        }
        RegCloseKey(hUC);
    }
    RegCloseKey(hBase);
}

extern "C" SEC_API int ScanRegistryIssues(RegistryIssue* outBuffer, int maxCount)
{
    if (!outBuffer || maxCount <= 0) return 0;

    std::vector<RegistryIssue> issues;
    issues.reserve(256);

    ScanStartupKeys(issues, maxCount);
    ScanUninstallKeys(issues, maxCount);
    ScanFileAssociations(issues, maxCount);

    int count = std::min((int)issues.size(), maxCount);
    for (int i = 0; i < count; i++)
        outBuffer[i] = issues[i];

    return count;
}

// ============================================================
// レジストリ 修復
// ============================================================

extern "C" SEC_API BOOL FixRegistryIssue(const RegistryIssue* issue)
{
    if (!issue) return FALSE;

    // キーパスを HKEY ルートと サブキーに分解
    std::wstring fullPath(issue->keyPath);
    HKEY hRoot = nullptr;
    std::wstring subKey;

    if (fullPath.substr(0, 5) == L"HKLM\\") {
        hRoot  = HKEY_LOCAL_MACHINE;
        subKey = fullPath.substr(5);
    } else if (fullPath.substr(0, 5) == L"HKCU\\") {
        hRoot  = HKEY_CURRENT_USER;
        subKey = fullPath.substr(5);
    } else if (fullPath.substr(0, 5) == L"HKCR\\") {
        hRoot  = HKEY_CLASSES_ROOT;
        subKey = fullPath.substr(5);
    } else {
        return FALSE;
    }

    HKEY hKey = nullptr;
    LONG ret = RegOpenKeyExW(hRoot, subKey.c_str(), 0, KEY_SET_VALUE, &hKey);
    if (ret != ERROR_SUCCESS) return FALSE;

    // 問題のある値を削除することで「修復」
    ret = RegDeleteValueW(hKey, issue->valueName);
    RegCloseKey(hKey);

    return (ret == ERROR_SUCCESS) ? TRUE : FALSE;
}

extern "C" SEC_API BOOL FixAllRegistryIssues(const RegistryIssue* issues,
                                              int count,
                                              int* fixedCount)
{
    if (!issues || count <= 0) return FALSE;

    int fixed = 0;
    for (int i = 0; i < count; i++) {
        if (FixRegistryIssue(&issues[i]))
            fixed++;
    }

    if (fixedCount) *fixedCount = fixed;
    return TRUE;
}

// ============================================================
// サマリー取得
// ============================================================

extern "C" SEC_API BOOL GetScanSummary(ScanSummary* summary)
{
    if (!summary) return FALSE;

    const int MAX_ITEMS = 8192;

    // ジャンクファイル
    std::vector<JunkFileInfo> junkBuf(MAX_ITEMS);
    int junkCount = ScanJunkFiles(junkBuf.data(), MAX_ITEMS);
    LONGLONG totalJunk = 0;
    for (int i = 0; i < junkCount; i++)
        totalJunk += junkBuf[i].sizeBytes;

    // レジストリ
    std::vector<RegistryIssue> regBuf(MAX_ITEMS);
    int regCount = ScanRegistryIssues(regBuf.data(), MAX_ITEMS);
    int critical = 0;
    for (int i = 0; i < regCount; i++)
        if (regBuf[i].severity >= 3) critical++;

    summary->junkFileCount       = junkCount;
    summary->totalJunkBytes      = totalJunk;
    summary->registryIssueCount  = regCount;
    summary->criticalIssues      = critical;

    // 現在時刻
    time_t now = time(nullptr);
    struct tm tm_info;
    localtime_s(&tm_info, &now);
    wchar_t timeBuf[64] = {};
    wcsftime(timeBuf, 64, L"%Y-%m-%d %H:%M:%S", &tm_info);
    wcsncpy_s(summary->scanTime, timeBuf, 63);

    return TRUE;
}

// ============================================================
// ユーティリティ
// ============================================================

extern "C" SEC_API const wchar_t* GetEngineVersion()
{
    return L"SecurityEngine v1.0.0";
}

extern "C" SEC_API BOOL IsAdminPrivilege()
{
    BOOL isAdmin = FALSE;
    PSID adminGroup = nullptr;
    SID_IDENTIFIER_AUTHORITY ntAuthority = SECURITY_NT_AUTHORITY;

    if (AllocateAndInitializeSid(&ntAuthority, 2,
            SECURITY_BUILTIN_DOMAIN_RID, DOMAIN_ALIAS_RID_ADMINS,
            0, 0, 0, 0, 0, 0, &adminGroup)) {
        CheckTokenMembership(nullptr, adminGroup, &isAdmin);
        FreeSid(adminGroup);
    }
    return isAdmin;
}

// ============================================================
// DLL エントリポイント
// ============================================================

BOOL WINAPI DllMain(HINSTANCE hInst, DWORD reason, LPVOID)
{
    switch (reason) {
        case DLL_PROCESS_ATTACH:
            DisableThreadLibraryCalls(hInst);
            break;
    }
    return TRUE;
}
