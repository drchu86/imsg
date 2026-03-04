import Commander
import Foundation
import IMsgCore

enum ServeCommand {
  static let spec = CommandSpec(
    name: "serve",
    abstract: "Run a local HTTP server (REST + SSE)",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "host", names: [.long("host")], help: "Bind address (default: 127.0.0.1)"),
          .make(label: "port", names: [.long("port")], help: "Port number (default: 3939)"),
        ]
      )
    ),
    usageExamples: [
      "imsg serve",
      "imsg serve --port 8080",
      "IMSG_HTTP_TOKEN=secret imsg serve",
    ]
  ) { values, _ in
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let host = values.option("host") ?? "127.0.0.1"
    let port = values.optionInt("port") ?? 3939
    let token = ProcessInfo.processInfo.environment["IMSG_HTTP_TOKEN"]

    let store = try MessageStore(path: dbPath)
    let httpServer = HTTPServer(
      store: store,
      host: host,
      port: port,
      token: token
    )
    try await httpServer.run()
  }
}
