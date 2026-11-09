function validRectangle(x, y, width, height) {
  return [x, y, width, height].every(Number.isFinite) && width > 0 && height > 0 &&
    Number.isFinite(x + width) && Number.isFinite(y + height) && x + width > x && y + height > y;
}

/**
 * 根据明确窗口范围选择点击使用的截图，返回相对该截图左上角的坐标。
 * windowBounds、point 和截图 originX/originY 必须使用同一坐标系与像素单位。
 * windowBounds 形状为 {x, y, width, height}；右边界和下边界不属于可点击区域。
 * screenshots 项含 {id, originX, originY, width, height}，point 形状为 {x, y}。
 * 本函数只处理元数据，不捕获、激活窗口或发送输入；调用方应传入最新截图。
 */
export function selectScreenshotForClick({ screenshots, windowBounds, point } = {}) {
  if (!Array.isArray(screenshots) || screenshots.length === 0 || !windowBounds || !point ||
      !validRectangle(windowBounds.x, windowBounds.y, windowBounds.width, windowBounds.height) ||
      !Number.isFinite(point.x) || !Number.isFinite(point.y)) {
    throw new Error('窗口范围、截图列表或点击坐标无效。');
  }
  const ids = new Set();
  for (const shot of screenshots) {
    if (!shot || typeof shot.id !== 'string' || !shot.id.trim() ||
        !validRectangle(shot.originX, shot.originY, shot.width, shot.height)) {
      throw new Error('截图标识或边界无效。');
    }
    if (ids.has(shot.id)) throw new Error('截图标识重复。');
    ids.add(shot.id);
  }
  if (point.x < windowBounds.x || point.y < windowBounds.y ||
      point.x >= windowBounds.x + windowBounds.width || point.y >= windowBounds.y + windowBounds.height) {
    throw new Error('点击坐标超出窗口范围。');
  }
  const candidates = screenshots.filter((shot) =>
    shot.originX <= windowBounds.x && shot.originY <= windowBounds.y &&
    shot.originX + shot.width >= windowBounds.x + windowBounds.width &&
    shot.originY + shot.height >= windowBounds.y + windowBounds.height);
  if (candidates.length !== 1) throw new Error('需要唯一一张完整覆盖窗口的截图。');
  const shot = candidates[0];
  return { screenshotId: shot.id, x: point.x - shot.originX, y: point.y - shot.originY };
}
