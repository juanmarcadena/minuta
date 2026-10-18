// The MCP helper bundled at Minuta.app/Contents/MacOS/minuta-mcp.
// Point an MCP client at that path; it serves the transcripts read-only over stdio.
import MinutaMCP

try await MinutaMCPServer.run()
