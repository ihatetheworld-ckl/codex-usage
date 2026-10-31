import Foundation

/// Only initializes the local app-server and reads account rate limits. Never starts a model turn.
final class CodexClient {
    var onUsage: ((UsagePayload) -> Void)?
    var onError: ((String) -> Void)?
    var onAccountChanged: (() -> Void)?
    private let queue = DispatchQueue(label: "local.codex-usage.transport")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var ready = false
    private var stopped = false
    private var requestID = 1
    private var pending: Int?
    private var timeout: DispatchWorkItem?

    static func executable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        var candidates = [String]()
        if let configured = environment["CODEX_USAGE_CLI"] { candidates.append(configured) }
        candidates += [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            if self.process == nil { self.start() }
            else if self.ready && self.pending == nil { self.requestUsage() }
        }
    }

    private func start() {
        guard let executable = Self.executable() else {
            fail("找不到 Codex CLI，请安装 Codex 或 ChatGPT 桌面版")
            return
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.arguments = ["app-server"]
        child.standardInput = stdin
        child.standardOutput = stdout
        // The app-server owns authentication. We neither read nor log its credentials or stderr.
        child.standardError = FileHandle.nullDevice
        child.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        ready = false
        buffer.removeAll()
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { [weak self] in self?.receive(data) }
        }
        child.terminationHandler = { [weak self] child in
            self?.queue.async { [weak self] in
                guard let self, self.process === child else { return }
                self.dispose()
                if !self.stopped { self.fail("Codex 连接断开，将自动重连") }
            }
        }
        do {
            try child.run()
            send(["id": 1, "method": "initialize", "params": ["clientInfo": [
                "name": "codex_usage", "title": "Codex Usage", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.1"
            ]]])
            armTimeout()
        } catch {
            dispose()
            fail("无法启动 Codex 用量连接")
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        do { try input?.write(contentsOf: data + Data([10])) }
        catch { disconnect("Codex 连接写入失败") }
    }

    private func requestUsage() {
        requestID += 1
        pending = requestID
        send(["id": requestID, "method": "account/rateLimits/read"])
        armTimeout()
    }

    private func armTimeout() {
        timeout?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.disconnect("用量请求超时，将自动重试") }
        timeout = task
        queue.asyncAfter(deadline: .now() + 20, execute: task)
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 2_000_000 else { disconnect("Codex 响应过大"); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            buffer.removeSubrange(...end)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(json)
        }
    }

    private func handle(_ json: [String: Any]) {
        if let id = json["id"] as? Int, id == 1 {
            timeout?.cancel()
            guard json["error"] == nil else { disconnect("Codex 协议初始化失败"); return }
            ready = true
            send(["method": "initialized", "params": [:]])
            requestUsage()
        } else if let id = json["id"] as? Int, id == pending {
            timeout?.cancel()
            pending = nil
            if let error = json["error"] as? [String: Any] {
                let message = (error["message"] as? String ?? "").lowercased()
                if message.contains("auth") || message.contains("login") || message.contains("401") {
                    // Do not retain another account's percentages after authentication fails.
                    DispatchQueue.main.async { [weak self] in self?.onAccountChanged?() }
                    fail("登录已失效，请在 Codex 中重新登录")
                } else { fail("暂时无法读取用量，将自动重试") }
            } else if let result = json["result"] { publish(result) }
            else { fail("Codex 没有返回用量数据") }
        } else if json["method"] as? String == "account/rateLimits/updated", let params = json["params"] {
            // Unsolicited updates may contain only a partial bucket; fetch the full response.
            _ = params
            if ready && pending == nil { requestUsage() }
        } else if json["method"] as? String == "account/updated" {
            DispatchQueue.main.async { [weak self] in self?.onAccountChanged?() }
            if ready && pending == nil { requestUsage() }
        } else if let id = json["id"], json["method"] != nil {
            send(["id": id, "error": ["code": -32601, "message": "This read-only client does not handle server requests"]])
        }
    }

    private func publish(_ object: Any) {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            let payload = try JSONDecoder().decode(UsagePayload.self, from: data)
            DispatchQueue.main.async { [weak self] in self?.onUsage?(payload) }
        } catch { fail("用量格式发生变化，暂时无法解析") }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    private func disconnect(_ message: String) {
        let child = process
        dispose()
        if child?.isRunning == true { child?.terminate() }
        if !stopped { fail(message) }
    }

    private func dispose() {
        timeout?.cancel(); timeout = nil
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close()
        input = nil; output = nil; process = nil; ready = false; pending = nil
        buffer.removeAll()
    }

    func stop() {
        queue.sync {
            stopped = true
            let child = process
            dispose()
            if child?.isRunning == true { child?.terminate() }
        }
    }
}
