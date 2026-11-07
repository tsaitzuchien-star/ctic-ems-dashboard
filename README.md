# 中創園區 排程指令信箱

空調監控主機的 `tools/sched_cmd.ps1` 每 2 分鐘讀取 `commands/sched_cmd.json`，檢查通過才寫入 InTouch 的製冰／融冰／磁浮排程。
只有 Cliff 在專案對話中確認「執行」的內容才會放到這裡。格式與硬規則見 main 分支 `tools/sched_cmd.ps1` 開頭說明。
