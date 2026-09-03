import { Node } from "prosemirror-model";
import { ProsemirrorHelper } from "@server/models/helpers/ProsemirrorHelper";
import nodesWithEmptyTextNode from "@server/test/fixtures/notion-page-with-empty-text-nodes.json";
import allNodes from "@server/test/fixtures/notion-page.json";
import type { ProsemirrorData, ProsemirrorDoc } from "@shared/types";
import type { NotionPage } from "./NotionConverter";
import { NotionConverter } from "./NotionConverter";

const generatedId = "550e8400-e29b-41d4-a716-446655440000";

function normalizeGeneratedIds(node: ProsemirrorDoc | ProsemirrorData) {
  if (node.type === "container_toggle" && node.attrs) {
    node.attrs.id = generatedId;
  }

  node.content?.forEach(normalizeGeneratedIds);
}

describe("NotionConverter", () => {
  it("converts a page", () => {
    const response = NotionConverter.page({
      children: allNodes,
    } as NotionPage);

    normalizeGeneratedIds(response);
    expect(response).toMatchSnapshot();
    expect(ProsemirrorHelper.toProsemirror(response)).toBeInstanceOf(Node);
  });

  it("converts a page with empty text nodes", () => {
    const response = NotionConverter.page({
      children: nodesWithEmptyTextNode,
    } as NotionPage);

    normalizeGeneratedIds(response);
    expect(response).toMatchSnapshot();
    expect(ProsemirrorHelper.toProsemirror(response)).toBeInstanceOf(Node);
  });

  it("drops an empty table", () => {
    const response = NotionConverter.page({
      children: [
        {
          object: "block",
          id: "1b32c2bb-bca8-8022-b490-e42a8f6b00f5",
          type: "table",
          has_children: false,
          table: {
            table_width: 0,
            has_column_header: false,
            has_row_header: false,
          },
        },
      ],
    } as unknown as NotionPage);

    expect(response.content).toEqual([]);
    expect(ProsemirrorHelper.toProsemirror(response)).toBeInstanceOf(Node);
  });

  it("drops media with an unrecognized file variant", () => {
    // The variant name is deliberately not one Notion is known to send – the
    // converter must fall back on shape, not on a known discriminant value.
    const response = NotionConverter.page({
      children: [
        {
          object: "block",
          id: "2d2d236d-0cc4-817c-80e3-ca7d0e4f4a70",
          type: "image",
          has_children: false,
          image: {
            type: "some_future_type",
            some_future_type: { id: "f7a1c0de-0000-4000-8000-000000000001" },
            caption: [],
          },
        },
      ],
    } as unknown as NotionPage);

    expect(response.content).toEqual([]);
    expect(ProsemirrorHelper.toProsemirror(response)).toBeInstanceOf(Node);
  });

  it("converts an image with a file variant", () => {
    const response = NotionConverter.page({
      children: [
        {
          object: "block",
          id: "2d2d236d-0cc4-811d-b94f-d1d68b476b52",
          type: "image",
          has_children: false,
          image: {
            type: "file",
            file: {
              url: "https://example.com/i.png",
              expiry_time: "2026-01-01T00:00:00.000Z",
            },
            caption: [],
          },
        },
      ],
    } as unknown as NotionPage);

    expect(response.content).toEqual([
      {
        type: "paragraph",
        content: [
          {
            type: "image",
            attrs: { src: "https://example.com/i.png", alt: "" },
          },
        ],
      },
    ]);
  });
});
