import "./style.css";

import { Compartment, EditorState } from "@codemirror/state";
import {
  EditorView,
  drawSelection,
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
  redo,
  selectAll,
  undo
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
};

let view: EditorView;
let revision = 0;
let cleanRevision = 0;
let suppressChangeNotifications = false;

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
      drawSelection(),
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

  view.scrollDOM.addEventListener("scroll", () => {
    debugToNative(`scroll scrollTop=${view.scrollDOM.scrollTop}`);
  });

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
  view.dispatch({
    selection: { anchor: 0 },
    scrollIntoView: true
  });
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

function focusEditor() {
  debugToNative("api focus()");
  view.focus();
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
    selectAll(view);
  },

  undo() {
    undo(view);
  },

  redo() {
    redo(view);
  },

  scrollToBottom() {
    view.scrollDOM.scrollTop = view.scrollDOM.scrollHeight;
  }
};

createEditor();
