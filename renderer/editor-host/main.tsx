// The note editor as hosted by the native Mac app.
//
// This is the same TipTap editor the Electron app uses, with the same node
// types, and nothing around it. The native side owns the document: it hands
// one in with `load`, and every change is posted back to it as document JSON.
// See macos/Sources/HeraclesApp/EditorWebView.swift for the other end.
import React, { useEffect, useRef } from 'react';
import { createRoot } from 'react-dom/client';
import { EditorContent, useEditor, type JSONContent } from '@tiptap/react';
import { DOMParser as PMDOMParser } from 'prosemirror-model';
import type { EditorView } from 'prosemirror-view';
import StarterKit from '@tiptap/starter-kit';
import TaskList from '@tiptap/extension-task-list';
import TaskItem from '@tiptap/extension-task-item';
import Link from '@tiptap/extension-link';
import { BlockId } from '../src/editor/BlockId';
import { CalloutBlock } from '../src/editor/CalloutBlock';
import { CodeMirrorBlock } from '../src/editor/CodeMirrorBlock';
import { Column } from '../src/editor/Column';
import { ColumnBlock } from '../src/editor/ColumnBlock';
import { ColumnsNormalizer } from '../src/editor/columnCommands';
import { ImageBlock } from '../src/editor/ImageBlock';
import SlashCommand from '../src/editor/SlashCommand';
import { ToggleBlock } from '../src/editor/ToggleBlock';
import { htmlToEditorHtml } from '../src/lib/htmlImport';
import 'tippy.js/dist/tippy.css';
import '../src/styles.css';
import './host.css';

/** How long typing must pause before a change is sent to be saved. */
const SAVE_DELAY_MS = 250;

type LoadRequest = { noteId: string; content: JSONContent; editable: boolean };

type HostApi = {
  /** Show a note. Anything unsaved from the previous note is sent first. */
  load: (request: LoadRequest) => void;
  /** Send any change still waiting out the save delay. */
  flush: () => void;
  focus: () => void;
  /** The current document as JSON text. */
  content: () => string;
  /** Type text at the cursor, as the user would. */
  insertText: (text: string) => void;
};

type NativeBridge = { postMessage: (message: unknown) => Promise<unknown> };

declare global {
  interface Window {
    heraclesEditor?: HostApi;
    webkit?: { messageHandlers?: { heracles?: NativeBridge } };
  }
}

const post = (message: Record<string, unknown>): Promise<unknown> =>
  window.webkit?.messageHandlers?.heracles?.postMessage(message) ?? Promise.resolve(null);

const imageFilesFrom = (files: FileList | null | undefined): File[] =>
  Array.from(files ?? []).filter((file) => file.type.startsWith('image/'));

const toBase64 = (file: File): Promise<string> =>
  new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error);
    // The result is a data URL. The native side wants the base64 part.
    reader.onload = () => resolve(String(reader.result).split(',', 2)[1] ?? '');
    reader.readAsDataURL(file);
  });

/**
 * Hand image files to the native image store and insert a block for each at
 * `position`. The document only ever holds the store's URL for an image.
 */
const insertImages = async (view: EditorView, files: File[], position: number) => {
  const sources: { src: string; alt: string }[] = [];
  for (const file of files) {
    const src = await post({ type: 'storeImage', mime: file.type, base64: await toBase64(file) });
    if (typeof src === 'string') sources.push({ src, alt: file.name });
  }
  let tr = view.state.tr;
  let pos = Math.min(position, tr.doc.content.size);
  for (const attrs of sources) {
    const node = view.state.schema.nodes.image.create(attrs);
    tr = tr.insert(pos, node);
    pos += node.nodeSize;
  }
  if (sources.length > 0) view.dispatch(tr.scrollIntoView());
};

const applyTheme = () => {
  const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
};

function HostEditor() {
  const noteId = useRef<string | null>(null);
  const saveTimer = useRef<number | null>(null);

  const editor = useEditor({
    extensions: [
      BlockId,
      StarterKit.configure({ codeBlock: false }),
      TaskList,
      TaskItem.configure({ nested: true }),
      Link.configure({ openOnClick: false, autolink: true }),
      CodeMirrorBlock,
      CalloutBlock,
      ToggleBlock,
      ImageBlock,
      ColumnBlock,
      Column,
      ColumnsNormalizer,
      SlashCommand
    ],
    content: '',
    editable: false,
    editorProps: {
      attributes: { class: 'editor-content' },
      handleDrop: (view, event) => {
        const images = imageFilesFrom((event as DragEvent).dataTransfer?.files);
        if (images.length === 0) return false;
        event.preventDefault();
        const dropped = view.posAtCoords({ left: event.clientX, top: event.clientY });
        void insertImages(view, images, dropped?.pos ?? view.state.selection.from);
        return true;
      },
      handlePaste: (view, event) => {
        const images = imageFilesFrom(event.clipboardData?.files);
        if (images.length > 0) {
          event.preventDefault();
          if (!view.state.selection.empty) view.dispatch(view.state.tr.deleteSelection());
          void insertImages(view, images, view.state.selection.from);
          return true;
        }
        // Rich text from outside the app is converted to the editor's own
        // nodes first. A copy made inside the editor pastes as it is.
        const html = event.clipboardData?.getData('text/html');
        if (html && html.trim().length > 0 && !html.includes('data-pm-slice')) {
          const converted = htmlToEditorHtml(html);
          if (converted && converted !== '<p></p>') {
            event.preventDefault();
            const dom = new DOMParser().parseFromString(converted, 'text/html');
            const slice = PMDOMParser.fromSchema(view.state.schema).parseSlice(dom.body, {
              preserveWhitespace: true
            });
            view.dispatch(view.state.tr.replaceSelection(slice).scrollIntoView());
            return true;
          }
        }
        return false;
      },
      // ⌘-click follows a link. A plain click places the cursor, as in any editor.
      handleClick: (_view, _pos, event) => {
        const link = (event.target as HTMLElement | null)?.closest('a[href]');
        if (!link || !event.metaKey) return false;
        event.preventDefault();
        void post({ type: 'openLink', href: link.getAttribute('href') ?? '' });
        return true;
      }
    },
    onUpdate: () => {
      if (saveTimer.current !== null) window.clearTimeout(saveTimer.current);
      saveTimer.current = window.setTimeout(() => window.heraclesEditor?.flush(), SAVE_DELAY_MS);
    }
  });

  useEffect(() => {
    if (!editor) return;

    const flush = () => {
      if (saveTimer.current === null) return;
      window.clearTimeout(saveTimer.current);
      saveTimer.current = null;
      if (noteId.current === null) return;
      void post({
        type: 'changed',
        noteId: noteId.current,
        content: JSON.stringify(editor.getJSON())
      });
    };

    window.heraclesEditor = {
      load: ({ noteId: id, content, editable }) => {
        flush();
        noteId.current = id;
        // `false`: showing a document is not an edit, so nothing is sent back.
        editor.commands.setContent(content, false);
        editor.setEditable(editable);
      },
      flush,
      focus: () => editor.commands.focus(),
      content: () => JSON.stringify(editor.getJSON()),
      insertText: (text) => editor.chain().focus('end').insertContent(text).run()
    };

    // Leaving the page, or the window going to the background, must not
    // strand a change in the save delay.
    const flushIfHidden = () => {
      if (document.visibilityState === 'hidden') flush();
    };
    window.addEventListener('pagehide', flush);
    window.addEventListener('blur', flush);
    document.addEventListener('visibilitychange', flushIfHidden);
    void post({ type: 'ready' });

    return () => {
      window.removeEventListener('pagehide', flush);
      window.removeEventListener('blur', flush);
      document.removeEventListener('visibilitychange', flushIfHidden);
      delete window.heraclesEditor;
    };
  }, [editor]);

  return (
    <div className="editor-host">
      <EditorContent editor={editor} />
    </div>
  );
}

applyTheme();
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', applyTheme);

// A file dropped outside the editor must not replace the page with that file.
for (const type of ['dragover', 'drop'] as const) {
  window.addEventListener(type, (event) => {
    if (event.dataTransfer?.types.includes('Files')) event.preventDefault();
  });
}

const container = document.getElementById('root');
if (!container) throw new Error('Root element not found');
createRoot(container).render(<HostEditor />);
