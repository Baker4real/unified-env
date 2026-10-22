# Native generation 回收

**Decision:** 不做 native generation 回收（2026-10-21 维护者决定，统一环境 #96）。

**Reason:** generation 是不可变的内容寻址目录。加载路径先校验，再整读字节交给 `Assembly.Load(byte[])`，文件不会被锁住，所以任何删除都会和其他进程的校验、读取窗口竞争。保留规则还得跨 PowerShell 版本（同一份源码在不同 pwsh 版本下是不同 generation）。每代约 80 KB，为这点空间给安全敏感的 loader 加一条删除路径不划算。将来数量或体量真成问题时另开新票，并重新论证上述前提。

**Prior requests:**

- [#96](https://github.com/Baker4real/unified-env/issues/96) native loader：回收旧 generation，清理遗留的固定路径 StatusScan DLL
