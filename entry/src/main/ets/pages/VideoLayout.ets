export interface VideoFrame { width: number; height: number; }

export function fitVideoFrame(viewWidth: number, viewHeight: number, videoWidth: number, videoHeight: number,
  fill: boolean = false): VideoFrame {
  if (!Number.isFinite(viewWidth) || !Number.isFinite(viewHeight) || viewWidth <= 0 || viewHeight <= 0) {
    return { width: 0, height: 0 };
  }
  if (fill) { return { width: viewWidth, height: viewHeight }; }
  const ratio = videoWidth > 0 && videoHeight > 0 ? videoWidth / videoHeight : 16 / 9;
  if (viewWidth / viewHeight > ratio) { return { width: viewHeight * ratio, height: viewHeight }; }
  return { width: viewWidth, height: viewWidth / ratio };
}
