// --serve: the scan as a read-only HTTP endpoint, so something other than this Mac can see which
// session needs you — an ESP32 desk display, a phone on the couch, a Stream Deck.
// Same JSON as --dump. Scans per request: no timer, no shared state, nothing to go stale.
import Foundation
import Network

// ponytail: no request parsing — every request gets the same JSON, so there's no route, no query,
// and nothing to inject into. Add parsing when there's a second thing to serve.
func httpResponse(_ json: Data) -> Data {
    var head = "HTTP/1.1 200 OK\r\n"
    head += "Content-Type: application/json\r\n"
    head += "Content-Length: \(json.count)\r\n"
    head += "Access-Control-Allow-Origin: *\r\n"   // a plain browser page can fetch it
    head += "Connection: close\r\n\r\n"
    return Data(head.utf8) + json
}

// Bind address is a trust boundary: the payload carries cwd paths, branch names and your last
// prompt. Callers default `host` to 127.0.0.1 — reaching it from the LAN has to be typed out.
func serve(host: String, port: UInt16) throws -> Never {
    guard let p = NWEndpoint.Port(rawValue: port) else {
        FileHandle.standardError.write(Data("bad port \(port)\n".utf8)); exit(1)
    }
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: p)
    let listener = try NWListener(using: params)
    listener.newConnectionHandler = { conn in
        conn.start(queue: .main)
        // Read whatever the client sent (and discard it) before replying — some clients won't read
        // the response until their request has been consumed.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
            let rows = scan()
            let json = (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
            conn.send(content: httpResponse(json), completion: .contentProcessed { _ in conn.cancel() })
        }
    }
    listener.stateUpdateHandler = { st in
        switch st {
        case .ready: FileHandle.standardError.write(Data("claudewatch serving http://\(host):\(port)\n".utf8))
        case .failed(let e):
            FileHandle.standardError.write(Data("serve failed: \(e.localizedDescription)\n".utf8)); exit(1)
        default: break
        }
    }
    listener.start(queue: .main)
    RunLoop.main.run()
    exit(0)   // unreachable; RunLoop.main.run() never returns
}

// "8787" -> (127.0.0.1, 8787) · "0.0.0.0:8787" -> LAN-visible. Split on the LAST colon so an
// IPv6 literal in brackets still parses. nil = unusable argument.
func parseServeAddr(_ s: String) -> (host: String, port: UInt16)? {
    guard let i = s.lastIndex(of: ":") else {
        return UInt16(s).map { ("127.0.0.1", $0) }        // bare port -> loopback only
    }
    let h = String(s[s.startIndex..<i]), rest = String(s[s.index(after: i)...])
    guard let port = UInt16(rest), !h.isEmpty else { return nil }
    return (h.hasPrefix("[") && h.hasSuffix("]") ? String(h.dropFirst().dropLast()) : h, port)
}
