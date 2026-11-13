---
type: reference
title: 本机 GUI 会话与微信提示过滤验收
tags: [宿主安全, GUI, 微信开发者工具]
intent: 为 sky 与 Windows 原生传输提供同一类观察失效门禁，并验证微信提示过滤事务
---

# 本机 GUI 适配层

源码由 host-safety 拥有，直接从本仓库导入，不需部署到用户脚本目录。`gui-session.mjs` 保留 sky 适配并提供 `createNativeSession`，Windows 传输由 `native-gui.mjs`／`native-gui.py` 实现，过滤事务在 `wechat-console-filter.mjs`。仅在已有本次 GUI 授权时使用；有官方 Computer Use 后端时先按该 skill 的 API、guidance 和 confirmations 操作。没有该后端的 Harness 会话可选择下面的受管 Windows 入口，不另写 ctypes 点按脚本。同一任务只选择一个后端；失败不换后端绕过停止。

## 窗口观察与单次输入

先按官方初始化步骤导入 `@oai/sky` 并列出窗口。从刚返回的对象选择唯一目标，不猜 app ID、窗口 ID 或标题。然后创建会话，同一 `sky` 对象只能建立一个会话，后续复用 `gui`：

```js
globalThis.guiModule = await import('file:///D:/agents/projects/统一环境/managed/host-diagnostics/gui-session.mjs');
// targetAppId / targetTitle 必须来自本次 sky.list_windows() 结果。
globalThis.gui = guiModule.createSkySession(sky, {
  selectWindow: window => window.app === targetAppId && window.title === targetTitle,
});
globalThis.observation = await gui.observe();
nodeRepl.write(observation.state.accessibility?.tree || 'No accessibility tree');
```

停下检查树和目标截图，再在下一格执行一个动作。用当前树中实际索引替换 `filterIndex`；用当前截图发出坐标点击时，还必须依据官方坐标合同检查完整覆盖、遮挡与坐标系，`screenshotId` 必须来自当前观察。适配层只证明截图身份，不证明目标没被遮挡。

```js
globalThis.observation = await gui.act(observation, 'set_value', {
  element_index: filterIndex, value: desiredFilter,
});
nodeRepl.write(observation.state.accessibility?.tree || 'No accessibility tree');
```

每次输入消费观察令牌并立即刷新。官方 `get_window_state` 自动展示截图；必须实际检查，不再重复 emit、解码或保存截图来检查。过期令牌不能复用；输入失败不会自动重放。重新 `observe()` 时最多重定位一次；连续两次失败停止会话。发现遮挡或旧树时调用 `gui.rejectObservation(observation)`，重新观察；连续两次拒绝也停止。不得把成功取得 AX 树当成无遮挡证明。需要前台激活时，将 `activate_window` 作为单独动作后重新检查。

用户物理 Esc、工具的 user-stopped/turn-ended 报错或 `AbortSignal` 中止后，立即停止输入；不以新会话、新后端或回滚绕过停止。宿主在调用间发来停止消息时先调用 `gui.stop()`。只读状态回收也不继续。以后用户明确重新授权 GUI 工作时才可重置 `node_repl`，从官方初始化和窗口选择重新开始；同一 backend 对象不提供解除停止的入口。

## Windows 原生传输（Harness 无官方 GUI 后端时）

先用只读进程查询取得当前窗口的 PID 与精确标题；Python 路径取当前宿主依赖报告，需有 Pillow。不要照抄历史 PID。使用同一长驻 Node 对象创建会话：

```js
const { createWindowsGuiSession } = await import('file:///D:/agents/projects/统一环境/managed/host-diagnostics/native-gui.mjs');
const gui = createWindowsGuiSession({ python: absolutePython, pid: observedPid, title: observedTitle,
  evidenceRoot: 'D:/agents/run-evidence/gui/current-task', signal: abortController.signal });
let observation = await gui.observe();
```

`observe()` 返回 `state.screenshots[].path`，必须先用当前宿主图片读取工具查看该图；看到被测控件后再输入。截图坐标为窗口左上角起的物理像素，不能从小程序逻辑 viewport 或旧机型截图直接换算。输入使用 `gui.click(observation, {screenshotId, x, y})`，其中 screenshotId 来自该观察。Windows 矩形、进程创建时间、HWND、DPI、前台与上层窗口遮挡在截取前后及按下前后重新核对；任一变化即拒绝。失焦后不再截图，原生按下／释放放在 try／finally 内。

`observe()`／`click()` 不激活窗口，也不发送 Alt。确需激活时，先单独 `await gui.activate()` 并重新看图；Windows 不允许激活或窗口已最小化时，交给人工恢复。连续两次证据失效后 `gui.status === 'manual-review'`，后续输入被拒绝；先取得一次人工基线再决定下一步，不根据这类失败修改业务代码或安装包。输入失败不重放。物理 Esc 在原生检查点检测，调用间的用户停止通过 `gui.stop()` 或 AbortSignal 终止；此传输没有驻留的全局键盘钩子。

这里验证的是输入证据。`input-sent` 只说明发出了按压，按钮业务是否响应仍需用同页状态谓词确认；不能把选择器 tap 的成功替代坐标可达证据。后端测试包含失焦、遮挡、窗口／DPI 变化、旧观察、故障预算和鼠标释放，不等于已对任何产品做过真实输入验收。

## 微信 preload 过滤验收

此功能只过滤两条本机资源的未使用 preload 提示，未修改预加载机制。目标为 `WAServiceMainContext.js` 和 `WAAutoService.js`；`WAWebview.js`、网络 500、普通警告和真实错误应保留。规则不锚定消息开头，支持渲染文本前缀与空白差异。Console 的文本过滤不能按错误级别做例外，因此实际样本中若有相同文字的真实错误，直接拒绝应用。

先从当前控制台收集完整文本与级别，包括两条目标 warning、至少一条普通 warning 和一条真实 error；不能拿“看不到任何消息”当作成功。把当前 Filter 值完整保存为 `originalFilter`。若缺少对照消息，停在未验证，不能编造。`samples` 形状为 `{level: 'warning'|'error', text: '实际完整消息'}` 数组。

```js
globalThis.filterModule = await import('file:///D:/agents/projects/统一环境/managed/host-diagnostics/wechat-console-filter.mjs');
globalThis.filterTx = filterModule.createFilterTransaction({
  samples, originalFilter, revision: observation.revision, session: gui,
});
globalThis.desiredFilter = filterTx.requestedFilter;
```

每一次过滤事务内的 GUI 动作都包住失败分支；一格仅执行一个动作，下面的 catch 只登记恢复状态，不继续输入：

```js
try {
  globalThis.observation = await gui.act(observation, 'set_value', {
    element_index: filterIndex, value: filterTx.requestedFilter,
  });
  nodeRepl.write(observation.state.accessibility?.tree || 'No accessibility tree');
} catch (error) {
  nodeRepl.write(JSON.stringify(filterTx.fail(error)));
  throw error;
}
```

停下检查新树和自动展示的截图。若需要触发编辑事件，依据实际焦点执行单独 Return 或 Tab 动作并再次观察，该动作使用同样的 catch。不要把 Filter 输入框 readback 当成已生效。

从新观察提取 `readbackFilter` 和 `visibleMessages`（完整消息字符串数组），执行：

```js
filterTx.verify({ filter: readbackFilter, visibleMessages, revision: observation.revision });
```

返回 `compile` 才能进入重编译。通过当前观察到的编译控件发出单独 GUI 动作；观察编译实际结束后调用 `filterTx.compiled({ revision: observation.revision })`。再取得更新的控制台观察，重复 `verify`；仅 `verified` 代表两条提示隐藏、所有对照消息仍可见且重新编译后仍有效。若编译清空了对照消息，重新复现相同对照后再验收；无法复现就不能通过。

`verify` 或 `compiled` 普通失败会自动将事务转到 `rollback` 并抛错；GUI 动作失败由上面的 catch 调用 `filterTx.fail(error)`。处于 `rollback` 时，以当前观察重新定位 Filter，并通过同一 `gui` 写入 `filterTx.requestedFilter`（原值），再用更新的观察调用 `verify({filter: readbackFilter, revision: observation.revision})`，必须得到 `rolled-back`。恢复失败则保留“未恢复”状态并报告。用户停止时 `fail` 返回 `stopped, rollback:false`，不得继续恢复原值。

## ASAR 只读检索

`managed/host-diagnostics/asar_extract.py` 是 host-safety 拥有的源码；本机旧入口 `D:/Codex/tools/asar-extract/asar_extract.py` 只转发此源，不保留第二份实现。先 list 固定包内模块，再 grep 固定方法；默认整批 6000 UTF-8 字节，可用 `--json --max-output-bytes 1200 --max-files 1 --max-per-file 2 --context 100` 收窄。JSON 同时返回总命中、文件数、展示片段和遗漏条数；未命中退出 1。grep 不修改安装包，查到字符串也不代表运行实例已加载该模块。

## 验证边界

```powershell
node --test managed/host-diagnostics/gui-session.test.mjs
py -3.14 -B managed/host-diagnostics/native-gui.test.py
py -3.14 -B managed/host-diagnostics/test_asar_extract.py
node scripts/Validate-ModuleBoundaries.cjs --json
```

fixture 覆盖官方 API 参数接线、观察失效、动态重绑、有限失败、遮挡拒绝、Esc、实际提示样本以及过滤/回滚状态转换。它不替代真实窗口验收；未实际运行两轮 Console 验证时只能报告“适配层与检查已实现”，不能报告提示已隐藏。
