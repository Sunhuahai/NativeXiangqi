//! Fixed resource-policy constants for analysis, throttle, idle, and restart
//! behavior. These are release gates, not claims: every value is enforced by
//! the coordinator and the session.

import Foundation

public enum PikafishResourcePolicy {
  /// Default UI-facing analysis update frequency (Hz).
  public static let defaultUIUpdateHz = 5
  /// Hard maximum UI-facing update frequency (Hz). Raw engine output may be
  /// parsed far faster; rendering never exceeds this rate.
  public static let maximumUIUpdateHz = 10
  /// Milliseconds between throttled UI flushes at the default rate.
  public static let defaultUIUpdateIntervalMilliseconds = 1_000 / defaultUIUpdateHz
  /// Idle helper shutdown deadline once no search is active.
  public static let defaultIdleTimeout = Duration.seconds(180)
  /// Maximum explicit restarts per rolling hour before requiring the user.
  public static let maximumRestartsPerHour = 5
}
