import { Plugin } from "@opencode/plugin";

async function runReviewRequest(request, signal) {
  if (typeof request !== "string" || Buffer.byteLength(request, "utf8") > 1024 * 1024) {
    throw new Error("Review request must be a JSON string of at most 1 MiB");
  }
  const url = process.env.OPENCODE_REVIEW_BROKER_URL;
  if (!url) throw new Error("Review launcher unavailable");
  const timeout = AbortSignal.timeout(120000);
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: request,
    redirect: "error",
    signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
  });
  if (!response.ok) throw new Error(`Review request failed: ${response.statusText}`);
  return response.text();
}

export default Plugin.define({
  id: "pr-review-api",
  async setup(ctx) {
    await ctx.tool.transform((editor) => {
      editor.add({
        name: "pr-review-api",
        description:
          "Read scoped GitHub evidence or queue one commit-bound COMMENT review for the launcher to publish.",
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
          content: await runReviewRequest(input.request, context.signal),
        }),
      });
    });
  },
});
