# Frontend Standard Local Rules

<!-- 將此檔案複製為 .claude/frontend-standard.local.md 並填入實際規範。-->
<!-- 以下為最小可用範例，請依專案實際狀況調整或補充。-->

## 元件規範

- 共用元件放在 `src/components/shared/` 目錄下。
- 頁面專屬元件放在對應的頁面目錄內（例如 `src/pages/Login/components/`）。
- 新增元件前先確認 `shared/` 內是否已有可重用的同類元件。

## 檔案位置規則

- 樣式檔與元件同層，命名與元件一致（例如 `Button.tsx` 搭配 `Button.module.css`）。
- 常數與型別定義放在 `src/types/` 或 `src/constants/`，不散落在頁面元件內。

## 格式化規則

- 縮排使用 2 個空格。
- 字串使用單引號。
- 每個檔案結尾保留一個空白行。
- 使用 `npm run lint` 驗證格式是否符合規範。