#pragma once

#ifdef SECURITYENGINE_EXPORTS
#define SEC_API __declspec(dllexport)
#else
#define SEC_API __declspec(dllimport)
#endif

#include <windows.h>
#include <string>
#include <vector>

// ============================================================
// 構造体定義
// ============================================================

// ジャンクファイル情報
struct JunkFileInfo {
    wchar_t path[MAX_PATH];
    LONGLONG sizeBytes;
    wchar_t category[64]; // "TempFiles", "BrowserCache", "RecycleBin" など
};

// レジストリ問題情報
struct RegistryIssue {
    wchar_t keyPath[512];
    wchar_t valueName[256];
    wchar_t issueType[128]; // "MissingFile", "InvalidPath", "OrphanedKey" など
    wchar_t description[512];
    int     severity;       // 1=低, 2=中, 3=高
};

// スキャン結果サマリー
struct ScanSummary {
    int     junkFileCount;
    LONGLONG totalJunkBytes;
    int     registryIssueCount;
    int     criticalIssues;
    wchar_t scanTime[64];
};

// ============================================================
// エクスポート関数
// ============================================================
extern "C" {

    // --- ジャンクファイルスキャン ---
    SEC_API int  ScanJunkFiles(JunkFileInfo* outBuffer, int maxCount);
    SEC_API BOOL CleanJunkFiles(const JunkFileInfo* items, int count, LONGLONG* bytesFreed);
    SEC_API LONGLONG GetTotalJunkSize();

    // --- レジストリ監視・修復 ---
    SEC_API int  ScanRegistryIssues(RegistryIssue* outBuffer, int maxCount);
    SEC_API BOOL FixRegistryIssue(const RegistryIssue* issue);
    SEC_API BOOL FixAllRegistryIssues(const RegistryIssue* issues, int count, int* fixedCount);

    // --- サマリー取得 ---
    SEC_API BOOL GetScanSummary(ScanSummary* summary);

    // --- ユーティリティ ---
    SEC_API const wchar_t* GetEngineVersion();
    SEC_API BOOL           IsAdminPrivilege();
}
