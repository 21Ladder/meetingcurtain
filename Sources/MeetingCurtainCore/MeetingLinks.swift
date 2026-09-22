import Foundation

/// Finds the video-call link of an event.
public enum MeetingLinks {
    /// Looks at the event's URL field, then its location, then its notes, and returns the first video-call link.
    public static func joinURL(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, let link = normalized(url) { return link }
        for text in [location, notes] {
            if let text, !text.isEmpty, let link = firstLink(in: text) { return link }
        }
        return nil
    }

    // Building a detector compiles its patterns, so one instance is shared; matching is thread-safe.
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    public static func firstLink(in text: String) -> URL? {
        guard let detector else { return nil }
        // Google sends rich-text descriptions as HTML, so query strings arrive as "&amp;".
        let text = text.replacingOccurrences(of: "&amp;", with: "&")
        var found: URL?
        detector.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            if let url = match?.url, let link = normalized(url) {
                found = link
                stop.pointee = true
            }
        }
        return found
    }

    /// A short, human name for the service behind a join link, e.g. "Google Meet".
    public static func serviceName(for url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        func under(_ domain: String) -> Bool { Self.under(domain, host) }
        if host == "meet.google.com" { return "Google Meet" }
        if scheme == "zoommtg" || under("zoom.us") || under("zoomgov.com") { return "Zoom" }
        if host.hasPrefix("teams.") { return "Teams" }
        if under("webex.com") { return "Webex" }
        if host == "facetime.apple.com" { return "FaceTime" }
        if host == "app.slack.com" { return "Slack" }
        return "Meeting"
    }

    /// Returns the link if it points to a known video-call service, unwrapping Google redirect links.
    /// Links come from invitations anyone can send, so only known hosts pass, and never unencrypted.
    static func normalized(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        // The Zoom app's own scheme, but only for Zoom's hosts: an invitation must not be able to hand
        // arbitrary parameters to another app.
        if scheme == "zoommtg" { return under("zoom.us", host) || under("zoomgov.com", host) ? url : nil }
        guard scheme == "https" || scheme == "http" else { return nil }

        // Google wraps links in event descriptions as https://www.google.com/url?q=<target>.
        if under("google.com", host), url.path == "/url" {
            let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "q" }?.value
            return target.flatMap(URL.init(string:)).flatMap(normalized)
        }
        guard isVideoCall(host: host, path: url.path.lowercased()),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        return components.url
    }

    private static func under(_ domain: String, _ host: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    static func isVideoCall(host: String, path: String) -> Bool {
        func under(_ domain: String) -> Bool { Self.under(domain, host) }
        let hasPath = path.count > 1

        if host == "meet.google.com" { return hasPath }
        if under("zoom.us") || under("zoomgov.com") {
            return ["/j/", "/my/", "/w/", "/s/", "/wc/"].contains { path.hasPrefix($0) }
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" {
            return path.contains("meetup-join") || path.hasPrefix("/meet/") || path.hasPrefix("/l/meet")
        }
        if under("webex.com") { return path.contains("/meet") || path.contains("j.php") || path.contains("/join") }
        if host == "facetime.apple.com" { return path.hasPrefix("/join") }
        if host == "app.slack.com" { return path.contains("/huddle/") }
        let generic = ["chime.aws", "meet.jit.si", "whereby.com", "meet.goto.com", "gotomeeting.com", "bluejeans.com", "around.co"]
        return hasPath && generic.contains(where: under)
    }
}
