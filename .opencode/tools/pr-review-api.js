import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { tool } from "@opencode-ai/plugin";

const adapter = fileURLToPath(
  new URL("../scripts/pr-review-gh.sh", import.meta.url),
);

export default tool({
  description:
    "Run a validated, scoped GitHub review request and return bounded response pages.",
  args: {
    request: tool.schema
      .string()
      .describe("Structured review request encoded as JSON"),
  },
  async execute(args, context) {
    if (
      typeof args.request !== "string" ||
      Buffer.byteLength(args.request, "utf8") > 1024 * 1024
    ) {
      throw new Error("Review request must be a JSON string of at most 1 MiB");
    }
    return new Promise((resolve, reject) => {
      const child = execFile(
        "bash",
        [adapter, "--request-stdin"],
        {
          cwd: context.directory,
          encoding: "utf8",
          maxBuffer: 32768,
          timeout: 120000,
          signal: context.abort,
        },
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
      child.stdin.end(args.request);
    });
  },
});
