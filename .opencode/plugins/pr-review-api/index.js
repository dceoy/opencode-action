import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { Plugin } from "@opencode/plugin";

const adapter = fileURLToPath(
  new URL("../../scripts/pr-review-gh.sh", import.meta.url),
);

// OpenCode 2 does not load OpenCode 1 custom tools from tools/, so this
// registers the same trusted adapter bridge as ../../tools/pr-review-api.js
// through the OpenCode 2 plugin API. Keep the bounds in both files identical.
function runReviewRequest(request, cwd, signal) {
  if (
    typeof request !== "string" ||
    Buffer.byteLength(request, "utf8") > 1024 * 1024
  ) {
    throw new Error("Review request must be a JSON string of at most 1 MiB");
  }
  return new Promise((resolve, reject) => {
    const child = execFile(
      "bash",
      [adapter, "--request-stdin"],
      { cwd, encoding: "utf8", maxBuffer: 32768, timeout: 120000, signal },
      (error, stdout, stderr) => {
        if (error)
          reject(
            new Error(
              `Review request failed: ${stderr.slice(0, 2048) || "adapter unavailable"}`,
            ),
          );
        else resolve(stdout);
      },
    );
    child.stdin.on("error", () => {});
    child.stdin.end(request);
  });
}

export default Plugin.define({
  id: "pr-review-api",
  async setup(ctx) {
    await ctx.tool.transform((editor) => {
      editor.add({
        name: "pr-review-api",
        description:
          "Run a validated, scoped GitHub review request and return bounded response pages.",
        input: {
          type: "object",
          properties: {
            request: {
              type: "string",
              description: "Structured review request encoded as JSON",
            },
          },
          required: ["request"],
          additionalProperties: false,
        },
        execute: async (input, context) => ({
          content: await runReviewRequest(
            input.request,
            ctx.location.directory,
            context.signal,
          ),
        }),
      });
    });
  },
});
