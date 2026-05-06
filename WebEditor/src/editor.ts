import "./style.css";

import { Compartment, EditorState } from "@codemirror/state";
import {
  EditorView,
  highlightActiveLine,
  highlightActiveLineGutter,
  keymap,
  lineNumbers
} from "@codemirror/view";
import {
  defaultKeymap,
  history,
  historyKeymap,
  indentWithTab,
  selectAll,
} from "@codemirror/commands";
import {
  SearchQuery,
  findNext,
  findPrevious,
  highlightSelectionMatches,
  openSearchPanel,
  search,
  searchKeymap,
  setSearchQuery
} from "@codemirror/search";
import { autocompletion, closeBrackets, completionKeymap } from "@codemirror/autocomplete";
import {
  bracketMatching,
  defaultHighlightStyle,
  foldGutter,
  indentOnInput,
  syntaxHighlighting
} from "@codemirror/language";
import { lintGutter } from "@codemirror/lint";

import { debugToNative, postToNative } from "./bridge";
import { inferLanguageFromPath, languageExtension, type RemoraLanguage } from "./languages";

type SearchOptions = {
  caseSensitive?: boolean;
  regexp?: boolean;
  wholeWord?: boolean;
};

type DocumentPayload = {
  documentID: string;
  contentVersion: number;
  text: string;
  path?: string;
  language?: RemoraLanguage;
  isEditable?: boolean;
  lineWrapping?: boolean;
  resetViewState?: boolean;
};

let view: EditorView;
let revision = 0;
let cleanRevision = 0;
let suppressChangeNotifications = false;
let maxLogChars = 2 * 1024 * 1024;

const languageCompartment = new Compartment();
const editableCompartment = new Compartment();
const readOnlyCompartment = new Compartment();
const wrapCompartment = new Compartment();

function reconfigureDocumentState(payload: DocumentPayload) {
  const language = payload.language ?? inferLanguageFromPath(payload.path);
  const isEditable = payload.isEditable ?? true;
  const lineWrapping = payload.lineWrapping ?? true;

  view.dispatch({
    effects: [
      languageCompartment.reconfigure(languageExtension(language)),
      editableCompartment.reconfigure(EditorView.editable.of(isEditable)),
      readOnlyCompartment.reconfigure(EditorState.readOnly.of(!isEditable)),
      wrapCompartment.reconfigure(lineWrapping ? EditorView.lineWrapping : [])
    ]
  });
}

function replaceWholeDocument(text: string) {
  suppressChangeNotifications = true;
  view.dispatch({
    changes: {
      from: 0,
      to: view.state.doc.length,
      insert: text
    }
  });
  suppressChangeNotifications = false;
}

function trimLogText(text: string) {
  if (text.length <= maxLogChars) {
    return text;
  }

  const tail = text.slice(-maxLogChars);
  const newlineIndex = tail.indexOf("\n");
  return newlineIndex >= 0 ? tail.slice(newlineIndex + 1) : tail;
}

function createEditor() {
  const parent = document.getElementById("editor");
  if (!parent) {
    postToNative({ type: "error", message: "Missing #editor element" });
    return;
  }

  const state = EditorState.create({
    doc: "",
    extensions: [
      lineNumbers(),
      foldGutter(),
      lintGutter(),
      highlightActiveLineGutter(),
      highlightActiveLine(),
      history(),
      closeBrackets(),
      bracketMatching(),
      autocompletion(),
      indentOnInput(),
      search({ top: true }),
      highlightSelectionMatches(),
      syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
      languageCompartment.of(languageExtension("plain")),
      editableCompartment.of(EditorView.editable.of(true)),
      readOnlyCompartment.of(EditorState.readOnly.of(false)),
      wrapCompartment.of(EditorView.lineWrapping),
      keymap.of([
        {
          key: "Mod-s",
          preventDefault: true,
          run: () => {
            debugToNative("keydown Mod-s");
            requestSave();
            return true;
          }
        },
        {
          key: "Mod-f",
          preventDefault: true,
          run: (view) => {
            debugToNative("keydown Mod-f");
            return openSearchPanel(view);
          }
        },
        {
          key: "Mod-g",
          preventDefault: true,
          run: (view) => {
            debugToNative("keydown Mod-g");
            return findNext(view);
          }
        },
        {
          key: "Shift-Mod-g",
          preventDefault: true,
          run: (view) => {
            debugToNative("keydown Shift-Mod-g");
            return findPrevious(view);
          }
        },
        indentWithTab,
        ...searchKeymap,
        ...completionKeymap,
        ...historyKeymap,
        ...defaultKeymap
      ]),
      EditorView.updateListener.of((update) => {
        if (update.docChanged && !suppressChangeNotifications) {
          revision += 1;
          debugToNative(`docChanged revision=${revision} chars=${update.state.doc.length}`);
          postToNative({ type: "changed", revision });
        }
      }),
      EditorView.theme({
        "&": {
          height: "100%",
          fontSize: "13px"
        },
        ".cm-scroller": {
          fontFamily: "Menlo, Monaco, 'SF Mono', monospace"
        },
        ".cm-content": {
          caretColor: "var(--remora-caret)"
        },
        ".cm-cursor, .cm-dropCursor": {
          borderLeft: "2px solid var(--remora-caret)"
        },
        ".cm-focused .cm-cursor": {
          borderLeft: "2px solid var(--remora-caret)"
        },
        ".cm-cursorLayer": {
          zIndex: "20"
        },
        ".cm-selectionLayer": {
          zIndex: "10"
        },
        ".cm-focused": {
          outline: "none"
        },
        ".cm-gutters": {
          backgroundColor: "var(--remora-gutter-bg)",
          color: "var(--remora-gutter-fg)",
          borderRight: "1px solid var(--remora-border)"
        },
        ".cm-searchMatch": {
          outline: "1px solid var(--remora-search-border)",
          backgroundColor: "var(--remora-search-bg)"
        },
        ".cm-searchMatch.cm-searchMatch-selected": {
          backgroundColor: "var(--remora-search-selected-bg)"
        },
        ".cm-panels": {
          backgroundColor: "var(--remora-bg)",
          color: "var(--remora-fg)",
          borderBottom: "1px solid var(--remora-border)"
        }
      })
    ]
  });

  view = new EditorView({
    state,
    parent
  });

  const editorRect = view.dom.getBoundingClientRect();
  const scrollerRect = view.scrollDOM.getBoundingClientRect();
  const parentRect = parent.getBoundingClientRect();
  debugToNative(
    `readyRects parent=${parentRect.x},${parentRect.y},${parentRect.width},${parentRect.height} editor=${editorRect.x},${editorRect.y},${editorRect.width},${editorRect.height} scroller=${scrollerRect.x},${scrollerRect.y},${scrollerRect.width},${scrollerRect.height}`
  );

  postToNative({ type: "ready" });
}

function setTheme(theme: "light" | "dark") {
  document.documentElement.dataset.theme = theme;
}

function setDocument(payload: DocumentPayload) {
  debugToNative(
    `setDocument id=${payload.documentID} contentVersion=${payload.contentVersion} chars=${(payload.text ?? "").length} path=${payload.path ?? ""}`
  );
  replaceWholeDocument(payload.text ?? "");
  reconfigureDocumentState(payload);
  revision = 0;
  cleanRevision = 0;
  if (payload.resetViewState ?? true) {
    view.dispatch({
      selection: { anchor: 0 },
      scrollIntoView: true
    });
  }
}

function requestSave() {
  debugToNative(`requestSave revision=${revision}`);
  postToNative({ type: "saveRequested", revision });
}

function markSaved(savedRevision?: number) {
  cleanRevision = savedRevision ?? revision;
  debugToNative(`markSaved cleanRevision=${cleanRevision} revision=${revision}`);
}

function isDirty() {
  return revision !== cleanRevision;
}

function insertText(text: string) {
  const selection = view.state.selection.main;
  view.dispatch({
    changes: {
      from: selection.from,
      to: selection.to,
      insert: text
    },
    selection: {
      anchor: selection.from + text.length
    },
    scrollIntoView: true
  });
}

function replaceSelection(text: string) {
  insertText(text);
}

function deleteSelection() {
  const selection = view.state.selection.main;
  if (selection.empty) return;

  view.dispatch({
    changes: {
      from: selection.from,
      to: selection.to,
      insert: ""
    },
    selection: {
      anchor: selection.from
    },
    scrollIntoView: true
  });
}

function pasteText(text: string) {
  focusPreservingScroll();
  insertText(text);
}

function setLogDocument(text: string, follow: boolean) {
  replaceWholeDocument(trimLogText(text));
  const editor = document.querySelector(".cm-editor") as HTMLElement | null;
  const scroller = document.querySelector(".cm-scroller") as HTMLElement | null;
  const editorRect = editor?.getBoundingClientRect();
  const scrollerRect = scroller?.getBoundingClientRect();
  debugToNative(
    `setLogDocument follow=${follow} chars=${text.length} editorRect=${editorRect ? `${editorRect.x},${editorRect.y},${editorRect.width},${editorRect.height}` : "n/a"} scrollerRect=${scrollerRect ? `${scrollerRect.x},${scrollerRect.y},${scrollerRect.width},${scrollerRect.height}` : "n/a"}`
  );
  if (follow) {
    view.scrollDOM.scrollTop = view.scrollDOM.scrollHeight;
  }
}

function appendLogText(text: string, follow: boolean) {
  const current = view.state.doc.toString();
  const next = trimLogText(current + text);
  replaceWholeDocument(next);
  if (follow) {
    view.scrollDOM.scrollTop = view.scrollDOM.scrollHeight;
  }
}

function focusEditor() {
  debugToNative("api focus()");
  view.focus();
}

function focusPreservingScroll() {
  const previousTop = view.scrollDOM.scrollTop;
  const previousLeft = view.scrollDOM.scrollLeft;

  view.focus();

  requestAnimationFrame(() => {
    view.scrollDOM.scrollTop = previousTop;
    view.scrollDOM.scrollLeft = previousLeft;
    debugFocus();
  });
}

function focusAfterMouseEvent() {
  requestAnimationFrame(() => {
    focusPreservingScroll();
  });
}

function debugFocus() {
  const active = document.activeElement as HTMLElement | null;
  const cursor = document.querySelector(".cm-cursor") as HTMLElement | null;
  const editor = document.querySelector(".cm-editor") as HTMLElement | null;
  const content = document.querySelector(".cm-content") as HTMLElement | null;
  const cursorStyle = cursor ? getComputedStyle(cursor) : null;
  const rect = cursor ? cursor.getBoundingClientRect() : null;

  debugToNative(
    [
      `focus active=${active?.tagName ?? "none"}`,
      `activeClass=${active?.className ?? "none"}`,
      `documentHasFocus=${document.hasFocus()}`,
      `viewHasFocus=${view.hasFocus}`,
      `editorClass=${editor?.className ?? "none"}`,
      `contentClass=${content?.className ?? "none"}`,
      `cursorExists=${cursor ? "true" : "false"}`,
      `cursorDisplay=${cursorStyle?.display ?? "n/a"}`,
      `cursorVisibility=${cursorStyle?.visibility ?? "n/a"}`,
      `cursorOpacity=${cursorStyle?.opacity ?? "n/a"}`,
      `cursorBorder=${cursorStyle?.borderLeft ?? "n/a"}`,
      `cursorRect=${rect ? `${rect.x},${rect.y},${rect.width},${rect.height}` : "n/a"}`,
      `anchor=${view.state.selection.main.anchor}`
    ].join(" ")
  );
}

function copySelection() {
  focusPreservingScroll();
  document.execCommand("copy");
}

function cutSelection() {
  focusPreservingScroll();
  deleteSelection();
}

function runSearch(query: string, options?: SearchOptions) {
  const searchQuery = new SearchQuery({
    search: query,
    caseSensitive: options?.caseSensitive ?? false,
    regexp: options?.regexp ?? false,
    wholeWord: options?.wholeWord ?? false
  });

  view.dispatch({
    effects: setSearchQuery.of(searchQuery)
  });

  openSearchPanel(view);
}

(window as Window & {
  RemoraEditor?: Record<string, unknown>;
}).RemoraEditor = {
  setDocument(payload: DocumentPayload) {
    setDocument(payload);
  },

  getText() {
    return view.state.doc.toString();
  },

  getSelectionText() {
    const range = view.state.selection.main;
    return view.state.sliceDoc(range.from, range.to);
  },

  replaceSelection(text: string) {
    replaceSelection(text);
  },

  insertText(text: string) {
    insertText(text);
  },

  pasteText(text: string) {
    pasteText(text);
  },

  setLogDocument(text: string, follow: boolean) {
    setLogDocument(text, follow);
  },

  appendLogText(text: string, follow: boolean) {
    appendLogText(text, follow);
  },

  setMaxLogChars(value: number) {
    maxLogChars = value;
  },

  setLanguage(language: RemoraLanguage) {
    view.dispatch({
      effects: languageCompartment.reconfigure(languageExtension(language))
    });
  },

  setEditable(isEditable: boolean) {
    view.dispatch({
      effects: [
        editableCompartment.reconfigure(EditorView.editable.of(isEditable)),
        readOnlyCompartment.reconfigure(EditorState.readOnly.of(!isEditable))
      ]
    });
  },

  setLineWrapping(enabled: boolean) {
    view.dispatch({
      effects: wrapCompartment.reconfigure(enabled ? EditorView.lineWrapping : [])
    });
  },

  setTheme(theme: "light" | "dark") {
    setTheme(theme);
  },

  focus() {
    focusEditor();
  },

  focusAfterMouseEvent() {
    focusAfterMouseEvent();
  },

  focusPreservingScroll() {
    focusPreservingScroll();
  },

  debugFocus() {
    debugFocus();
  },

  requestSave() {
    requestSave();
  },

  markSaved(savedRevision?: number) {
    markSaved(savedRevision);
  },

  isDirty() {
    return isDirty();
  },

  search(query: string, options?: SearchOptions) {
    runSearch(query, options);
  },

  findNext() {
    findNext(view);
  },

  findPrevious() {
    findPrevious(view);
  },

  openSearch() {
    openSearchPanel(view);
  },

  selectAll() {
    focusPreservingScroll();
    selectAll(view);
  },

  copySelection() {
    copySelection();
  },

  cutSelection() {
    cutSelection();
  },

  deleteSelection() {
    deleteSelection();
  },

  scrollToBottom() {
    view.scrollDOM.scrollTop = view.scrollDOM.scrollHeight;
  }
};

createEditor();
