import Foundation
import Network

/// One parsed HTTP/1.1 request. Header names are lowercased.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    /// Percent-decoded, without the query.
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:],
                headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func text(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"],
                     body: Data(text.utf8))
    }

    public static func json<T: Encodable>(_ value: T) -> HTTPResponse {
        guard let data = try? JSONEncoder().encode(value) else { return .text(500, "encoding failed") }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json",
                                                   "Cache-Control": "no-store"], body: data)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return status < 500 ? "Error" : "Internal Server Error"
        }
    }

    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

/// Just enough HTTP/1.1 for a phone browser: a request line, headers, a `Content-Length` body.
enum HTTPParser {
    /// Requests bigger than this are refused. The largest real one is a rating POST.
    static let maximumSize = 64 * 1024

    enum Result: Equatable {
        case incomplete
        case invalid
        case tooLarge
        /// The request plus how many bytes of the buffer it used.
        case request(HTTPRequest, consumed: Int)
    }

    private static let separator = Data("\r\n\r\n".utf8)

    static func parse(_ buffer: Data) -> Result {
        guard let end = buffer.range(of: separator) else {
            return buffer.count > maximumSize ? .tooLarge : .incomplete
        }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/"),
              let components = URLComponents(string: String(requestLine[1])),
              components.path.hasPrefix("/") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        let bodyStart = end.upperBound
        guard bodyStart - buffer.startIndex + length <= maximumSize else { return .tooLarge }
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let request = HTTPRequest(method: String(requestLine[0]).uppercased(),
                                  path: components.path,
                                  query: query,
                                  headers: headers,
                                  body: Data(buffer[bodyStart..<bodyStart + length]))
        return .request(request, consumed: bodyStart - buffer.startIndex + length)
    }
}

/// A small keep-alive HTTP server on one local address. Handlers run as async tasks; the
/// connections themselves live on a private queue.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "dev.yannickpulver.rawviewer.http")

    /// `port` 0 picks a free one; read it back from `port` once the server is ready.
    public init(host: String, port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host),
                                                     port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    public var port: UInt16? { listener.port?.rawValue }

    /// Calls `onReady` once listening, or `onFailure` with the reason.
    public func start(onReady: @escaping @Sendable () -> Void,
                      onFailure: @escaping @Sendable (String) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: onReady()
            case .failed(let error):
                onFailure(error.localizedDescription)
                self?.listener.cancel()
            case .waiting(let error):
                onFailure(error.localizedDescription)
                self?.listener.cancel()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.process(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    /// Answers every complete request in `buffer`, then reads more.
    private func process(_ connection: NWConnection, buffer: Data) {
        switch HTTPParser.parse(buffer) {
        case .request(let request, let consumed):
            let rest = Data(buffer.dropFirst(consumed))
            let keepAlive = request.headers["connection"]?.lowercased() != "close"
            let handler = self.handler
            Task { [weak self] in
                let response = await handler(request)
                connection.send(content: response.serialized(keepAlive: keepAlive),
                                completion: .contentProcessed { error in
                    guard let self, error == nil, keepAlive else { connection.cancel(); return }
                    self.queue.async { self.process(connection, buffer: rest) }
                })
            }
        case .incomplete:
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                [weak self] data, _, _, error in
                guard let self, error == nil, let data, !data.isEmpty else {
                    connection.cancel()
                    return
                }
                var next = buffer
                next.append(data)
                self.process(connection, buffer: next)
            }
        case .invalid:
            fail(connection, .text(400, "bad request"))
        case .tooLarge:
            fail(connection, .text(413, "too large"))
        }
    }

    private func fail(_ connection: NWConnection, _ response: HTTPResponse) {
        connection.send(content: response.serialized(keepAlive: false),
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
