export type EditorToNativeMessage =
  | { type: "ready" }
  | { type: "changed"; revision: number }
  | { type: "saveRequested"; revision: number }
  | { type: "debug"; message: string }
  | { type: "error"; message: string };

export function postToNative(message: EditorToNativeMessage) {
  const handler = (window as Window & {
    webkit?: {
      messageHandlers?: {
        remoraEditor?: {
          postMessage: (payload: EditorToNativeMessage) => void;
        };
      };
    };
  }).webkit?.messageHandlers?.remoraEditor;

  handler?.postMessage(message);
}

export function debugToNative(message: string) {
  postToNative({ type: "debug", message });
}
