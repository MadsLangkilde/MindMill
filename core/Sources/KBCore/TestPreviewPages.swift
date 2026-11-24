import Foundation

/// One call made against a backend while testing it.
public struct EndpointCall: Codable, Equatable, Sendable {
    public var method: String
    public var path: String
    public var status: Int?
    public var millis: Int?
    public var request: String?
    public var response: String
    public var error: String?

    public init(method: String, path: String, status: Int? = nil, millis: Int? = nil, request: String? = nil, response: String = "", error: String? = nil) {
        self.method = method
        self.path = path
        self.status = status
        self.millis = millis
        self.request = request
        self.response = response
        self.error = error
    }

    public var ok: Bool { error == nil && (status.map { (200..<400).contains($0) } ?? false) }

    /// `GET /health` or `POST /items {"a":1}`.
    public static func parse(_ line: String) -> EndpointCall? {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].contains(parts[0].uppercased()), parts[1].hasPrefix("/") else { return nil }
        return EndpointCall(method: parts[0].uppercased(), path: parts[1], request: parts.count > 2 ? parts[2] : nil)
    }
}

/// The pages the Mac makes for the phone's web view: plain HTML that reads well on a phone, in light and dark.
public enum PreviewPages {
    static let style = """
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
    :root{--bg:#fff;--fg:#1c1c1e;--muted:#6b6b70;--card:#f2f2f7;--ok:#1f8f4e;--bad:#c4321f;--line:#d9d9de}
    @media (prefers-color-scheme: dark){:root{--bg:#000;--fg:#f2f2f7;--muted:#9a9aa0;--card:#1c1c1e;--ok:#3cc477;--bad:#ff6b5a;--line:#38383a}}
    body{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:16px/1.45 -apple-system,system-ui,Roboto,sans-serif;overflow-wrap:anywhere}
    h1{font-size:1.3em;margin:0 0 4px}h2{font-size:1.05em;margin:22px 0 8px}
    .muted{color:var(--muted)}.ok{color:var(--ok)}.bad{color:var(--bad)}
    .card{background:var(--card);border-radius:12px;padding:12px;margin:8px 0}
    .pills{display:flex;flex-wrap:wrap;gap:6px}.pill{background:var(--card);border-radius:999px;padding:3px 10px;font-size:.9em}
    pre{white-space:pre-wrap;word-break:break-word;font:13px/1.4 ui-monospace,Menlo,monospace;background:var(--card);padding:10px;border-radius:10px;margin:6px 0}
    img{max-width:100%;border-radius:10px}svg{width:100%;height:auto}
    input,select,textarea,button{font:inherit;width:100%;box-sizing:border-box;margin:4px 0;padding:8px;border-radius:8px;border:1px solid var(--line);background:var(--bg);color:var(--fg)}
    button{background:#0a84ff;color:#fff;border:0}
    </style>
    """

    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func page(_ title: String, _ body: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(escape(title))</title>\(style)</head><body>\(body)</body></html>"
    }

    static func header(_ title: String, _ subtitle: String, tests: TestRunSummary?) -> String {
        var h = "<h1>\(escape(title))</h1><div class=\"muted\">\(escape(subtitle))</div>"
        if let t = tests {
            h += "<div class=\"pills\" style=\"margin-top:10px\"><span class=\"pill \(t.ok ? "ok" : "bad")\">\(t.ok ? "✓ Tests pass" : "✗ Tests fail")</span>"
            h += "<span class=\"pill\">\(t.passed) passed</span><span class=\"pill\">\(t.failed) failed</span></div>"
            if !t.lines.isEmpty, !t.ok {
                h += "<h2>Failures</h2><pre>\(escape(t.lines.joined(separator: "\n")))</pre>"
            }
        }
        return h
    }

    /// Test reports, logs, device output and graphs: for embedded, desktop and anything else.
    public static func report(title: String, subtitle: String, tests: TestRunSummary?, sections: [(title: String, text: String)],
                              images: [(title: String, path: String)] = [], series: [String: [Double]] = [:]) -> String {
        var b = header(title, subtitle, tests: tests)
        for img in images {
            b += "<h2>\(escape(img.title))</h2><img src=\"\(escape(img.path))\" alt=\"\(escape(img.title))\">"
        }
        for name in series.keys.sorted() {
            guard let values = series[name], values.count > 1 else { continue }
            b += "<h2>\(escape(name))</h2><div class=\"card\">\(chart(values))</div>"
        }
        for s in sections where !s.text.isEmpty {
            b += "<h2>\(escape(s.title))</h2><pre>\(escape(String(s.text.suffix(20000))))</pre>"
        }
        return page(title, b)
    }

    /// Test results, the endpoints called with example requests and responses, failures, and a panel to try a call
    /// that the Mac makes (`try?method=GET&path=/x&body=…` is answered by `preview.get`).
    public static func backend(title: String, subtitle: String, base: String?, tests: TestRunSummary?, calls: [EndpointCall], tryPanel: Bool) -> String {
        var b = header(title, subtitle, tests: tests)
        if !calls.isEmpty {
            b += "<h2>Endpoints</h2>"
            for c in calls {
                let status = c.error.map { "<span class=\"bad\">\(escape($0))</span>" }
                    ?? "<span class=\"\(c.ok ? "ok" : "bad")\">\(c.status.map(String.init) ?? "–")</span>"
                b += "<div class=\"card\"><b>\(escape(c.method)) \(escape(c.path))</b> · \(status)\(c.millis.map { " · \($0) ms" } ?? "")"
                if let r = c.request, !r.isEmpty { b += "<div class=\"muted\">Request</div><pre>\(escape(r))</pre>" }
                if !c.response.isEmpty { b += "<div class=\"muted\">Response</div><pre>\(escape(String(c.response.prefix(4000))))</pre>" }
                b += "</div>"
            }
        }
        if tryPanel, let base {
            b += """
            <h2>Try a call</h2><div class="card"><div class="muted">The Mac calls \(escape(base)) for you.</div>
            <select id="m"><option>GET</option><option>POST</option><option>PUT</option><option>PATCH</option><option>DELETE</option></select>
            <input id="p" value="/" autocapitalize="off" autocorrect="off"><textarea id="b" rows="4" placeholder="JSON body (optional)"></textarea>
            <button onclick="go()">Send</button><pre id="out" class="muted">No call yet.</pre></div>
            <script>
            async function go(){const o=document.getElementById('out');o.textContent='Calling…';
            const q='try?method='+encodeURIComponent(document.getElementById('m').value)+'&path='+encodeURIComponent(document.getElementById('p').value)+'&body='+encodeURIComponent(document.getElementById('b').value);
            try{const r=await fetch(q);o.textContent=await r.text();}catch(e){o.textContent='Failed: '+e;}}
            </script>
            """
        }
        return page(title, b)
    }

    /// A simple line chart.
    public static func chart(_ values: [Double]) -> String {
        guard let lo = values.min(), let hi = values.max() else { return "" }
        let w = 320.0, h = 120.0, span = hi - lo == 0 ? 1 : hi - lo
        let pts = values.enumerated().map { i, v in
            String(format: "%.1f,%.1f", Double(i) / Double(max(1, values.count - 1)) * w, h - (v - lo) / span * (h - 10) - 5)
        }.joined(separator: " ")
        return "<svg viewBox=\"0 0 \(Int(w)) \(Int(h))\" role=\"img\"><polyline fill=\"none\" stroke=\"#0a84ff\" stroke-width=\"2\" points=\"\(pts)\"/></svg>"
            + "<div class=\"muted\">min \(fmt(lo)) · max \(fmt(hi)) · last \(fmt(values.last ?? 0)) · \(values.count) samples</div>"
    }

    static func fmt(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(format: "%.3g", v) }

    /// Numbers a device prints as `name=value` or `name: value`, as series to plot.
    public static func series(from log: String) -> [String: [Double]] {
        var out: [String: [Double]] = [:]
        guard let re = try? NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_\-]{0,30})\s*[=:]\s*(-?\d+(?:\.\d+)?)"#) else { return [:] }
        for line in log.components(separatedBy: "\n") {
            for m in re.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let n = Range(m.range(at: 1), in: line), let v = Range(m.range(at: 2), in: line), let d = Double(line[v]) else { continue }
                out[String(line[n]), default: []].append(d)
            }
        }
        return out.filter { $0.value.count >= 3 }
    }
}
