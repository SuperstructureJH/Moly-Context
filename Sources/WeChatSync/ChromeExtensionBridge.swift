import Foundation
import Network

struct ChromeExtensionPayload: Codable {
    let browserName: String
    let title: String
    let url: String
    let hostname: String
    let selectionText: String
    let metaDescription: String?
    let visibleText: String?
    let contentText: String
    let captureReason: String?
    let capturedAt: String

    var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedSelectionText: String {
        selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedMetaDescription: String {
        (metaDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedVisibleText: String {
        (visibleText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedContentText: String {
        contentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedCaptureReason: String {
        (captureReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ChromeExtensionBridgeStatus: Equatable {
    case stopped
    case listening(port: UInt16)
    case failed(String)

    var displayText: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .listening(let port):
            return "Listening on \(port)"
        case .failed(let reason):
            return "Error: \(reason)"
        }
    }
}

final class ChromeExtensionBridge {
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.moly.chrome-extension-bridge")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let onPayload: @Sendable (ChromeExtensionPayload) -> Void
    private let onStatusChange: @Sendable (ChromeExtensionBridgeStatus) -> Void
    private var listener: NWListener?

    init(
        port: UInt16 = 38451,
        onPayload: @escaping @Sendable (ChromeExtensionPayload) -> Void,
        onStatusChange: @escaping @Sendable (ChromeExtensionBridgeStatus) -> Void
    ) {
        self.port = port
        self.onPayload = onPayload
        self.onStatusChange = onStatusChange
    }

    func start() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.onStatusChange(.listening(port: self.port))
                case .failed(let error):
                    self.onStatusChange(.failed(error.localizedDescription))
                    self.stop()
                case .cancelled:
                    self.onStatusChange(.stopped)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }

            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onStatusChange(.failed(error.localizedDescription))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveAll(on: connection, accumulated: Data())
    }

    private func receiveAll(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.respond(
                    on: connection,
                    statusCode: 500,
                    body: ["ok": false, "error": error.localizedDescription]
                )
                return
            }

            let nextData = accumulated + (data ?? Data())
            if self.isCompleteHTTPRequest(nextData) || isComplete {
                self.process(nextData, on: connection)
            } else {
                self.receiveAll(on: connection, accumulated: nextData)
            }
        }
    }

    private func process(_ requestData: Data, on connection: NWConnection) {
        guard let request = parseHTTPRequest(from: requestData) else {
            respond(on: connection, statusCode: 400, body: ["ok": false, "error": "Malformed request"])
            return
        }

        if request.method == "OPTIONS" {
            respond(on: connection, statusCode: 204, body: nil)
            return
        }

        guard request.method == "POST", request.path == "/chrome-context" else {
            respond(on: connection, statusCode: 404, body: ["ok": false, "error": "Not found"])
            return
        }

        do {
            let payload = try decoder.decode(ChromeExtensionPayload.self, from: request.body)
            onPayload(payload)
            respond(on: connection, statusCode: 200, body: ["ok": true])
        } catch {
            respond(on: connection, statusCode: 400, body: ["ok": false, "error": error.localizedDescription])
        }
    }

    private func respond(on connection: NWConnection, statusCode: Int, body: [String: Any]?) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Internal Server Error"
        }

        let bodyData: Data
        if let body {
            bodyData = (try? JSONSerialization.data(withJSONObject: body, options: [])) ?? Data()
        } else {
            bodyData = Data()
        }

        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        response += "Content-Type: application/json\r\n"
        response += "Access-Control-Allow-Origin: *\r\n"
        response += "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
        response += "Access-Control-Allow-Headers: Content-Type\r\n"
        response += "Content-Length: \(bodyData.count)\r\n"
        response += "Connection: close\r\n\r\n"

        var responseData = Data(response.utf8)
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func isCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let request = parseHTTPRequest(from: data) else { return false }
        let contentLength = Int(request.headers["content-length"] ?? "") ?? 0
        return request.body.count >= contentLength
    }

    private func parseHTTPRequest(from data: Data) -> HTTPRequest? {
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: 0..<separatorRange.lowerBound)
        let bodyData = data.subdata(in: separatorRange.upperBound..<data.endIndex)

        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.components(separatedBy: " ")
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<separatorIndex].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        return HTTPRequest(
            method: requestParts[0],
            path: requestParts[1],
            headers: headers,
            body: bodyData
        )
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}
