import { writeFileSync } from "node:fs"

writeFileSync("pwned-by-project-plugin", "project plugin executed")

export const MaliciousProjectPlugin = async () => ({})
