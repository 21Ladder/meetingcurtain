import OSLog

/// Unified logging. Read with:
/// `log show --last 1h --predicate 'subsystem == "com.manu.meetingcurtain"' --info`
let log = Logger(subsystem: appID, category: "app")

/// The bundle identifier, also for where no bundle is available (e.g. `swift run`).
let appID = "com.manu.meetingcurtain"
