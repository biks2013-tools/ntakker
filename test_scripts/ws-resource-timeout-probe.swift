// test_scripts/ws-resource-timeout-probe.swift
//
// EVAL-2026-10-16 INF-3 probe: does URLSessionConfiguration
// .timeoutIntervalForResource close an already-upgraded WebSocket?
// Starts a local Network.framework WebSocket echo server, connects a
// URLSessionWebSocketTask with the given resource timeout, exchanges
// 16 messages over ~13 s (including a 6 s idle gap), and reports
// whether the socket stayed open.
//
//   swiftc -O test_scripts/ws-resource-timeout-probe.swift -o /tmp/wsprobe
//   /tmp/wsprobe 3        # resource timeout 3 s
//
// Result on macOS 27 (2026-10-16): "alive-at-end=yes" with a 3 s
// resource timeout, so the 300 s value in
// URLSessionWebSocketTaskTransport does not drop Soniox sockets.

import Foundation
import Network

// Local WebSocket echo server on 127.0.0.1:47123
let params = NWParameters.tcp
let ws = NWProtocolWebSocket.Options()
ws.autoReplyPing = true
params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
let listener = try! NWListener(using: params, on: 47123)
listener.newConnectionHandler = { conn in
    conn.start(queue: .global())
    func loop() {
        conn.receiveMessage { data, ctx, _, err in
            if err != nil { return }
            if let data, let ctx {
                conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
            }
            loop()
        }
    }
    loop()
}
listener.start(queue: .global())
Thread.sleep(forTimeInterval: 0.3)

let resource = Double(CommandLine.arguments[1])!
let cfg = URLSessionConfiguration.ephemeral
cfg.timeoutIntervalForRequest = 60
cfg.timeoutIntervalForResource = resource
let session = URLSession(configuration: cfg)
let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:47123")!)
task.resume()
let start = Date()
var alive = true
for i in 0..<16 {
    let sem = DispatchSemaphore(value: 0)
    task.send(.string("ping \(i)")) { err in
        if let err { print(String(format: "t=%.1fs send failed: %@", Date().timeIntervalSince(start), err.localizedDescription)); alive = false }
        sem.signal()
    }
    sem.wait()
    if !alive { break }
    let rsem = DispatchSemaphore(value: 0)
    task.receive { r in
        if case .failure(let e) = r { print(String(format: "t=%.1fs receive failed: %@", Date().timeIntervalSince(start), e.localizedDescription)); alive = false }
        rsem.signal()
    }
    rsem.wait()
    if !alive { break }
    Thread.sleep(forTimeInterval: i == 2 ? 6 : 0.5)
}
print(String(format: "resource=%.0fs alive-at-end=%@ closeCode=%d", resource, alive ? "yes" : "no", task.closeCode.rawValue))
