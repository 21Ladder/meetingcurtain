import OSLog

/// Unified logging. Read with:
/// `log show --last 1h --predicate 'subsystem == "com.manu.meetingcurtain"' --info`
let log = Logger(subsystem: "com.manu.meetingcurtain", category: "app")
