import assert from 'node:assert/strict';
import test from 'node:test';
import { selectScreenshotForClick } from './screenshot-geometry.mjs';

test('多张截图中选择完整窗口，跳过前两张 14×14 图块', () => {
  const screenshots = [
    { id: 'screenshot-0', width: 14, height: 14, originX: 0, originY: 0 },
    { id: 'screenshot-1', width: 14, height: 14, originX: 0, originY: 0 },
    { id: 'screenshot-2', width: 2534, height: 1104, originX: 0, originY: 0 },
  ];
  assert.deepEqual(selectScreenshotForClick({
    screenshots,
    windowBounds: { x: 0, y: 0, width: 2534, height: 1104 },
    point: { x: 1185, y: 27 },
  }), { screenshotId: 'screenshot-2', x: 1185, y: 27 });
});

test('单张截图按不同原点换算局部坐标且不修改输入', () => {
  const request = {
    screenshots: [{ id: 'desktop', originX: -1920, originY: 0, width: 1920, height: 1080 }],
    windowBounds: { x: -1800, y: 50, width: 1000, height: 800 },
    point: { x: -1700, y: 125 },
  };
  const before = structuredClone(request);
  assert.deepEqual(selectScreenshotForClick(request), { screenshotId: 'desktop', x: 220, y: 125 });
  assert.deepEqual(request, before);
});

test('点击必须位于窗口范围内，包括排除右边界和下边界', () => {
  for (const point of [{ x: 9, y: 30 }, { x: 110, y: 30 }, { x: 10, y: 120 }]) {
    assert.throws(() => selectScreenshotForClick({
      screenshots: [{ id: 'large', originX: 0, originY: 0, width: 1000, height: 1000 }],
      windowBounds: { x: 10, y: 20, width: 100, height: 100 },
      point,
    }), /点击坐标超出窗口/);
  }
});

test('不在两张完整截图之间猜测，也不接受局部截图', () => {
  const request = {
    windowBounds: { x: 0, y: 0, width: 100, height: 80 },
    point: { x: 20, y: 20 },
  };
  assert.throws(() => selectScreenshotForClick({ ...request, screenshots: [
    { id: 'first', originX: 0, originY: 0, width: 100, height: 80 },
    { id: 'second', originX: 0, originY: 0, width: 200, height: 100 },
  ] }), /唯一一张/);
  assert.throws(() => selectScreenshotForClick({ ...request, screenshots: [
    { id: 'partial', originX: 0, originY: 0, width: 50, height: 50 },
  ] }), /唯一一张/);
});

test('非有限坐标、空尺寸和无效截图标识失败，不返回可点击结果', () => {
  const valid = {
    screenshots: [{ id: 'full', originX: 0, originY: 0, width: 100, height: 80 }],
    windowBounds: { x: 0, y: 0, width: 100, height: 80 },
    point: { x: 20, y: 20 },
  };
  const invalid = [
    { ...valid, point: { x: NaN, y: 20 } },
    { ...valid, point: { x: Infinity, y: 20 } },
    { ...valid, point: { x: '20', y: 20 } },
    { ...valid, windowBounds: { ...valid.windowBounds, width: 0 } },
    { ...valid, windowBounds: { ...valid.windowBounds, height: -1 } },
    { ...valid, windowBounds: { ...valid.windowBounds, x: NaN } },
    { ...valid, screenshots: [{ ...valid.screenshots[0], width: Infinity }] },
    { ...valid, screenshots: [{ ...valid.screenshots[0], id: '' }] },
    { ...valid, screenshots: [{ ...valid.screenshots[0], originX: undefined }] },
    { ...valid, screenshots: [] },
  ];
  for (const request of invalid) {
    assert.throws(() => selectScreenshotForClick(request), /无效/);
  }
});

test('重复截图标识即使只有一个范围合格也失败', () => {
  assert.throws(() => selectScreenshotForClick({
    screenshots: [
      { id: 'same', originX: 0, originY: 0, width: 14, height: 14 },
      { id: 'same', originX: 0, originY: 0, width: 100, height: 80 },
    ],
    windowBounds: { x: 0, y: 0, width: 100, height: 80 },
    point: { x: 20, y: 20 },
  }), /重复/);
});
