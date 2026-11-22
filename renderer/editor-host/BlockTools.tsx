// The handle that appears beside the block under the pointer: drag it to
// move the block or drop it at another block's right edge to make columns,
// click + to add a block below, click ⋮⋮ for the block's menu.
import React, { useCallback, useEffect, useRef, useState } from 'react';
import type { Editor } from '@tiptap/react';
import type { EditorView } from 'prosemirror-view';
import {
  BLOCK_DRAG_MIME,
  getDropTarget,
  resolveOuterBlock,
  type OuterBlock
} from '../src/editor/columnCommands';

type Anchor = { pos: number; top: number; left: number; height: number };
export type DropMark = { top: number; left: number; width: number; height: number; mode: 'column' | 'reorder' };

/**
 * The movable block at a point: one that sits in the main flow or directly in
 * a column. Unlike a text position, this also finds blocks with no text in
 * them, such as images and code.
 */
export const blockAtPoint = (view: EditorView, clientX: number, clientY: number): OuterBlock | null => {
  const content = view.dom.getBoundingClientRect();
  // The pointer is usually in the margin beside the block, not on it.
  const left = Math.min(Math.max(clientX, content.left + 4), content.right - 4);
  const found = view.posAtCoords({ left, top: clientY });
  if (!found) return null;
  const { doc } = view.state;
  const direct = resolveOuterBlock(doc, found.pos);
  if (direct) return direct;
  if (found.inside < 0) return null;
  const node = doc.nodeAt(found.inside);
  const parent = doc.resolve(found.inside).parent.type.name;
  if (!node || (parent !== 'doc' && parent !== 'column')) return null;
  if (node.type.name === 'columnBlock' || node.type.name === 'column') return null;
  return { pos: found.inside, node, parentIsColumn: parent === 'column' };
};

/** Where to draw the line that shows what a drop would do. */
export const dropMarkAt = (
  view: EditorView,
  container: HTMLElement,
  clientX: number,
  clientY: number
): DropMark | null => {
  const target = getDropTarget(view, clientX, clientY);
  if (!target) return null;
  const frame = container.getBoundingClientRect();
  const { rect } = target;
  if (target.mode === 'column') {
    return { top: rect.top - frame.top, left: rect.right - frame.left, height: rect.height, width: 3, mode: 'column' };
  }
  const edge = target.side === 'before' ? rect.top : rect.bottom;
  return { top: edge - frame.top, left: rect.left - frame.left, height: 3, width: rect.width, mode: 'reorder' };
};

type TurnInto = 'paragraph' | 'heading1' | 'heading2' | 'heading3' | 'bulletList' | 'taskList' | 'blockquote' | 'code';

const TURN_INTO: { id: TurnInto; label: string }[] = [
  { id: 'paragraph', label: 'Text' },
  { id: 'heading1', label: 'Heading 1' },
  { id: 'heading2', label: 'Heading 2' },
  { id: 'heading3', label: 'Heading 3' },
  { id: 'bulletList', label: 'Bullet list' },
  { id: 'taskList', label: 'Task list' },
  { id: 'blockquote', label: 'Quote' },
  { id: 'code', label: 'Code block' }
];

type Props = {
  editor: Editor;
  container: HTMLElement;
  /** The drop line, set by the editor's drag handlers. */
  dropMark: DropMark | null;
  onCopyLink: (blockId: string) => void;
};

export function BlockTools({ editor, container, dropMark, onCopyLink }: Props) {
  const [anchor, setAnchor] = useState<Anchor | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const toolsRef = useRef<HTMLDivElement | null>(null);

  const place = useCallback(
    (block: OuterBlock) => {
      const dom = editor.view.nodeDOM(block.pos);
      const element = dom instanceof HTMLElement ? dom : dom?.parentElement;
      if (!element) return;
      const frame = container.getBoundingClientRect();
      const rect = element.getBoundingClientRect();
      setAnchor({ pos: block.pos, top: rect.top - frame.top, left: rect.left - frame.left, height: rect.height });
    },
    [container, editor]
  );

  useEffect(() => {
    const onMove = (event: MouseEvent) => {
      if (menuOpen || !editor.isEditable) return;
      if (toolsRef.current?.contains(event.target as Node)) return;
      const block = blockAtPoint(editor.view, event.clientX, event.clientY);
      if (block) place(block);
      else setAnchor(null);
    };
    const onLeave = () => {
      if (!menuOpen) setAnchor(null);
    };
    container.addEventListener('mousemove', onMove);
    container.addEventListener('mouseleave', onLeave);
    return () => {
      container.removeEventListener('mousemove', onMove);
      container.removeEventListener('mouseleave', onLeave);
    };
  }, [container, editor, menuOpen, place]);

  useEffect(() => {
    if (!menuOpen) return;
    const close = (event: MouseEvent | KeyboardEvent) => {
      if (event instanceof KeyboardEvent && event.key !== 'Escape') return;
      if (event instanceof MouseEvent && toolsRef.current?.contains(event.target as Node)) return;
      setMenuOpen(false);
    };
    document.addEventListener('mousedown', close);
    document.addEventListener('keydown', close);
    return () => {
      document.removeEventListener('mousedown', close);
      document.removeEventListener('keydown', close);
    };
  }, [menuOpen]);

  // An edit can move or remove the block the handle was beside.
  useEffect(() => {
    const hide = () => {
      if (!menuOpen) setAnchor(null);
    };
    editor.on('update', hide);
    return () => {
      editor.off('update', hide);
    };
  }, [editor, menuOpen]);

  const block = anchor ? editor.state.doc.nodeAt(anchor.pos) : null;
  if (!anchor || !block) {
    return dropMark ? <DropLine mark={dropMark} /> : null;
  }
  const end = anchor.pos + block.nodeSize;

  /** Put the cursor in the block, so commands that act on the selection act on it. */
  const select = () =>
    block.isTextblock || block.content.size > 0
      ? editor.chain().focus().setTextSelection(anchor.pos + 1)
      : editor.chain().focus().setNodeSelection(anchor.pos);

  const done = () => {
    setMenuOpen(false);
    setAnchor(null);
  };

  const addBelow = () => {
    editor.chain().focus().insertContentAt(end, { type: 'paragraph' }).setTextSelection(end + 1).run();
    done();
  };

  const duplicate = () => {
    // `toJSON` hands back the block's own attributes, not a copy of them.
    // Clearing the id there would take it from the original block and break
    // every link to it, so the copy gets attributes of its own, without an
    // id. The editor gives it a new one.
    const json = block.toJSON();
    const copy = { ...json, attrs: { ...json.attrs, blockId: null } };
    editor.chain().focus().insertContentAt(end, copy).run();
    done();
  };

  const remove = () => {
    editor.chain().focus().deleteRange({ from: anchor.pos, to: end }).run();
    done();
  };

  const copyLink = () => {
    let id = block.attrs.blockId as string | null | undefined;
    if (!id) {
      // A list has no id of its own. Its first item does.
      block.descendants((child) => {
        if (!id && child.attrs.blockId) id = child.attrs.blockId as string;
        return !id;
      });
    }
    if (id) onCopyLink(id);
    done();
  };

  const turnInto = (target: TurnInto) => {
    const blockId = block.attrs.blockId as string | null | undefined;
    if (target === 'code') {
      editor
        .chain()
        .focus()
        .command(({ tr, state }) => {
          const code = state.schema.nodes.codeMirrorBlock.create({
            language: 'javascript',
            code: block.textContent,
            blockId
          });
          tr.replaceRangeWith(anchor.pos, end, code);
          return true;
        })
        .run();
    } else if (target === 'paragraph') {
      select().setParagraph().run();
    } else if (target === 'bulletList') {
      select().toggleBulletList().run();
    } else if (target === 'taskList') {
      select().toggleTaskList().run();
    } else if (target === 'blockquote') {
      select().toggleBlockquote().run();
    } else {
      const level = Number(target.slice(-1)) as 1 | 2 | 3;
      select().setNode('heading', blockId ? { level, blockId } : { level }).run();
    }
    done();
  };

  // Lists, quotes and the like hold other blocks. "Turn into" is for a single
  // block of text.
  const canTurn = block.isTextblock;

  return (
    <div ref={toolsRef}>
      <div
        className="block-handle"
        style={{ top: anchor.top + Math.min(8, anchor.height / 4), left: Math.max(0, anchor.left - 72) }}
      >
        <div
          className="block-handle__button block-handle__button--drag"
          role="button"
          aria-label="Drag to move or make a column"
          title="Drag to move · drag to a block's right edge to make a column"
          draggable
          onDragStart={(event) => {
            event.dataTransfer.effectAllowed = 'move';
            event.dataTransfer.setData(BLOCK_DRAG_MIME, String(anchor.pos));
            event.dataTransfer.setData('text/plain', '');
            setMenuOpen(false);
          }}
        >
          ⠿
        </div>
        <button
          type="button"
          className="block-handle__button block-handle__button--add"
          aria-label="Add block"
          onMouseDown={(event) => event.preventDefault()}
          onClick={addBelow}
        >
          +
        </button>
        <button
          type="button"
          className="block-handle__button block-handle__button--menu"
          aria-label="Block actions"
          onMouseDown={(event) => event.preventDefault()}
          onClick={() => setMenuOpen((open) => !open)}
        >
          ⋮⋮
        </button>
      </div>
      {menuOpen && (
        <div className="block-menu" style={{ top: anchor.top + 30, left: Math.max(0, anchor.left - 72) }}>
          <div className="block-menu__title">Actions</div>
          <div className="block-menu__section">
            <MenuItem label="Copy link to block" onSelect={copyLink} />
            <MenuItem label="Duplicate" onSelect={duplicate} />
            <MenuItem label="Delete" onSelect={remove} />
          </div>
          {canTurn && (
            <>
              <div className="block-menu__divider" />
              <div className="block-menu__title">Turn into</div>
              <div className="block-menu__section">
                {TURN_INTO.map((item) => (
                  <MenuItem key={item.id} label={item.label} onSelect={() => turnInto(item.id)} />
                ))}
              </div>
            </>
          )}
        </div>
      )}
      {dropMark && <DropLine mark={dropMark} />}
    </div>
  );
}

function MenuItem({ label, onSelect }: { label: string; onSelect: () => void }) {
  return (
    <button
      type="button"
      className="block-menu__item"
      onMouseDown={(event) => event.preventDefault()}
      onClick={onSelect}
    >
      {label}
    </button>
  );
}

function DropLine({ mark }: { mark: DropMark }) {
  return (
    <div
      className={`block-drop-indicator block-drop-indicator--${mark.mode}`}
      style={{ top: mark.top, left: mark.left, width: mark.width, height: mark.height }}
    />
  );
}
