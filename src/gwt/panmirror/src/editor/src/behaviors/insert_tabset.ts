/*
 * insert-tabset.ts
 *
 * Copyright (C) 2021 by RStudio, PBC
 *
 * Unless you have received this program directly from RStudio pursuant
 * to the terms of a commercial license agreement with RStudio, then
 * this program is licensed to you under the terms of version 3 of the
 * GNU Affero General Public License. This program is distributed WITHOUT
 * ANY EXPRESS OR IMPLIED WARRANTY, INCLUDING THOSE OF NON-INFRINGEMENT,
 * MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE. Please refer to the
 * AGPL (http://www.gnu.org/licenses/agpl-3.0.txt) for more details.
 *
 */

import { EditorState, Transaction } from "prosemirror-state";
import { Node as ProsemirrorNode } from 'prosemirror-model';
import { wrapIn } from "prosemirror-commands";
import { findParentNodeOfType, setTextSelection } from "prosemirror-utils";
import { EditorView } from "prosemirror-view";

import { ExtensionContext, Extension } from "../api/extension";
import { kQuartoDocType } from "../api/format";
import { EditorCommandId, ProsemirrorCommand, toggleWrap } from "../api/command";
import { EditorUI } from "../api/ui";
import { OmniInsertGroup } from "../api/omni_insert";

const extension = (context: ExtensionContext): Extension | null => {
  const { pandocExtensions, format, ui } = context;

  if (!format.docTypes.includes(kQuartoDocType) || !pandocExtensions.fenced_divs) {
    return null;
  }

  return {
    commands: () => [
      new ProsemirrorCommand(EditorCommandId.Tabset, [], insertTabsetCommandFn(ui), {
        name: ui.context.translateText('Tabset'),
        description: ui.context.translateText('Content divided into tabs'),
        group: OmniInsertGroup.Content,
        priority: 2,
        image: () => ui.images.omni_insert?.generic!,
      }),
    ]
  };
};

function insertTabsetCommandFn(ui: EditorUI) {
  return (state: EditorState, dispatch?: (tr: Transaction) => void, view?: EditorView) => {
    
    const schema = state.schema;
    if (!toggleWrap(schema.nodes.div)(state)) {
      return false;
    }

    async function asyncInsertTabset() {
      if (dispatch) {
        const result = await ui.dialogs.insertTabset();
        if (result) {
          wrapIn(state.schema.nodes.div)(state, (tr: Transaction) => {
            // locate inserted div
            const div = findParentNodeOfType(state.schema.nodes.div)(tr.selection)!;

            // ensure that .panel-tabset is the first class then set attributes
            const kPanelTabset = "panel-tabset";
            const attr = {
              ...result.attr,
              classes: [kPanelTabset].concat((result.attr.classes || []).filter(clz => clz !== kPanelTabset))
            };
            tr.setNodeMarkup(div.pos, div.node.type, attr);
           
            // insert tabset
            const tabset: ProsemirrorNode[] = result.tabs.flatMap(tab => {
              return [
                schema.nodes.heading.create(
                  { level: 2 },
                  schema.text(tab)
                ),
                schema.nodes.paragraph.create()
              ];
            });
            tr.replaceWith(div.start, div.start + 1, tabset);

            // set selection
            setTextSelection(div.start + tabset[0].nodeSize)(tr);

            // dispatch
            dispatch(tr);
          });
        }
        if (view) {
          view.focus();
        }
      }
    }
    asyncInsertTabset();

    return true;
  };
}

export default extension;

