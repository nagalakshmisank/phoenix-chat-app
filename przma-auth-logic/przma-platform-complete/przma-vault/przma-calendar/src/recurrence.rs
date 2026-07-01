// przma-calendar/src/recurrence.rs
//
// rrule expansion for recurring calendar events.
// Wraps the rrule crate with PRZMA-specific helpers.

use chrono::{DateTime, TimeZone, Utc};
use rrule::{RRuleSet, Tz};
use crate::error::{CalendarError, CalendarResult};

// ─── EXPANSION ───────────────────────────────────────────────────────────────

/// Expand a recurrence rule into concrete instances within a date range.
///
/// # Arguments
/// * `rrule_str` - RFC 5545 RRULE string (e.g. "FREQ=WEEKLY;BYDAY=MO")
/// * `dtstart`   - Series start date (UTC)
/// * `tz`        - IANA timezone string (e.g. "America/Chicago")
/// * `range_start` / `range_end` - Window to expand into
/// * `max`       - Safety cap on returned instances
pub fn expand(
    rrule_str:   &str,
    dtstart:     DateTime<Utc>,
    tz:          &str,
    range_start: DateTime<Utc>,
    range_end:   DateTime<Utc>,
    max:         usize,
) -> CalendarResult<Vec<DateTime<Utc>>> {
    let tz: Tz = tz.parse().unwrap_or(Tz::UTC);
    let dtstart_local = dtstart.with_timezone(&tz);

    // Build DTSTART + RRULE string
    let rrule_input = format!(
        "DTSTART:{}\nRRULE:{}",
        dtstart_local.format("%Y%m%dT%H%M%S"),
        rrule_str
    );

    let rrule_set: RRuleSet = rrule_input
        .parse()
        .map_err(|e: rrule::RRuleError| CalendarError::Recurrence(e.to_string()))?;

    let instances: Vec<DateTime<Utc>> = rrule_set
        .into_iter()
        .take(max)
        .map(|dt| dt.with_timezone(&Utc))
        .filter(|dt| *dt >= range_start && *dt <= range_end)
        .collect();

    Ok(instances)
}

/// Check whether a given recurrence rule string is valid
pub fn validate_rrule(rrule_str: &str, dtstart: DateTime<Utc>) -> bool {
    let tz = Tz::UTC;
    let dtstart_local = dtstart.with_timezone(&tz);
    let input = format!(
        "DTSTART:{}\nRRULE:{}",
        dtstart_local.format("%Y%m%dT%H%M%S"),
        rrule_str
    );
    input.parse::<RRuleSet>().is_ok()
}

/// Expand recurring event with EXDATE support (excluded instances)
pub fn expand_with_exceptions(
    rrule_str:   &str,
    dtstart:     DateTime<Utc>,
    tz:          &str,
    range_start: DateTime<Utc>,
    range_end:   DateTime<Utc>,
    exdates:     &[DateTime<Utc>],  // instances to skip
    max:         usize,
) -> CalendarResult<Vec<DateTime<Utc>>> {
    let all = expand(rrule_str, dtstart, tz, range_start, range_end, max)?;
    let filtered = all
        .into_iter()
        .filter(|dt| !exdates.contains(dt))
        .collect();
    Ok(filtered)
}

/// Compute the next N occurrences after a given date (for reminders)
pub fn next_occurrences(
    rrule_str: &str,
    dtstart:   DateTime<Utc>,
    tz:        &str,
    after:     DateTime<Utc>,
    n:         usize,
) -> CalendarResult<Vec<DateTime<Utc>>> {
    expand(
        rrule_str,
        dtstart,
        tz,
        after,
        after + chrono::Duration::days(365 * 2), // 2-year lookahead
        n,
    )
}

// ─── COMMON PATTERNS ─────────────────────────────────────────────────────────

pub mod patterns {
    /// Daily practice (every day)
    pub const DAILY: &str = "FREQ=DAILY";

    /// Weekday practice (Mon–Fri)
    pub const WEEKDAYS: &str = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR";

    /// Weekly on a specific day — pass in day e.g. "MO"
    pub fn weekly_on(day: &str) -> String {
        format!("FREQ=WEEKLY;BYDAY={}", day)
    }

    /// Monthly on nth weekday — e.g. 1st Sunday = (1, "SU")
    pub fn monthly_nth(n: i32, day: &str) -> String {
        format!("FREQ=MONTHLY;BYDAY={}{}", n, day)
    }

    /// Annual (every year on same date)
    pub const ANNUAL: &str = "FREQ=YEARLY";

    /// Every other week
    pub const BIWEEKLY: &str = "FREQ=WEEKLY;INTERVAL=2";

    /// Daily for N occurrences
    pub fn daily_count(count: u32) -> String {
        format!("FREQ=DAILY;COUNT={}", count)
    }

    /// Weekdays for N occurrences
    pub fn weekdays_count(count: u32) -> String {
        format!("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR;COUNT={}", count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn start() -> DateTime<Utc> {
        chrono::NaiveDate::from_ymd_opt(2026, 5, 11)
            .unwrap()
            .and_hms_opt(9, 0, 0)
            .unwrap()
            .and_utc()
    }

    #[test]
    fn test_expand_weekly() {
        let dtstart     = start();
        let range_end   = dtstart + chrono::Duration::days(28);
        let instances   = expand(
            patterns::WEEKDAYS, dtstart, "UTC", dtstart, range_end, 20
        ).unwrap();
        // 4 weeks of weekdays = ~20 instances
        assert!(instances.len() >= 15);
    }

    #[test]
    fn test_expand_daily_count() {
        let dtstart   = start();
        let rrule_str = patterns::daily_count(7);
        let range_end = dtstart + chrono::Duration::days(30);
        let instances = expand(&rrule_str, dtstart, "UTC", dtstart, range_end, 20).unwrap();
        assert_eq!(instances.len(), 7);
    }

    #[test]
    fn test_expand_with_exception() {
        let dtstart     = start();
        let range_end   = dtstart + chrono::Duration::days(14);
        let exception   = dtstart + chrono::Duration::days(7);
        let instances   = expand_with_exceptions(
            patterns::weekly_on("MO").as_str(),
            dtstart, "UTC", dtstart, range_end,
            &[exception], 10,
        ).unwrap();
        assert_eq!(instances.len(), 1);
    }

    #[test]
    fn test_validate_rrule_valid() {
        assert!(validate_rrule("FREQ=WEEKLY;BYDAY=MO", start()));
    }

    #[test]
    fn test_validate_rrule_invalid() {
        assert!(!validate_rrule("FREQ=NOTAFREQUENCY", start()));
    }

    #[test]
    fn test_next_occurrences() {
        let dtstart = start();
        let after   = dtstart + chrono::Duration::days(1);
        let next    = next_occurrences("FREQ=DAILY", dtstart, "UTC", after, 3).unwrap();
        assert_eq!(next.len(), 3);
    }
}
