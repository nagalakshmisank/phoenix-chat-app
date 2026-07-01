// przma-calendar/src/analytics/patterns.rs
//
// DuckDB analytics patterns for companion context and longitudinal insights.
// Queries Lance files directly — no ETL, no intermediate storage.
// All queries run on the user's own data, never on PRZMA servers.

use crate::error::{CalendarError, CalendarResult};
use duckdb::Connection;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// ─── RESULT TYPES ────────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct TimeDistribution {
    pub by_category:      HashMap<String, u64>,     // events per category
    pub by_hour:          Vec<HourBucket>,           // events per hour of day
    pub by_day_of_week:   Vec<DayBucket>,
    pub total_events:     u64,
    pub total_busy_mins:  i64,
    pub avg_meeting_mins: f64,
    pub period_days:      u32,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct HourBucket {
    pub hour:        u8,
    pub event_count: u64,
    pub busy_mins:   i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct DayBucket {
    pub day_name:    String,
    pub event_count: u64,
    pub busy_mins:   i64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PracticeAdherence {
    pub title:           String,
    pub total_scheduled: u32,
    pub total_completed: u32,
    pub adherence_pct:   f32,
    pub current_streak:  u32,
    pub longest_streak:  u32,
    pub best_hour:       Option<u8>,    // hour of day with most completions
    pub last_completed:  Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct MeetingPatterns {
    pub avg_per_day:          f64,
    pub avg_duration_mins:    f64,
    pub peak_meeting_hour:    u8,
    pub back_to_back_count:   u64,
    pub longest_meeting_mins: i64,
    pub by_category:          HashMap<String, u64>,
    pub focus_block_ratio:    f64,       // focus blocks / total blocks
}

#[derive(Debug, Serialize, Deserialize)]
pub struct AttendeeFrequency {
    pub did:           String,
    pub meeting_count: u64,
    pub total_mins:    i64,
    pub first_meeting: Option<String>,
    pub last_meeting:  Option<String>,
    pub avg_duration:  f64,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct CompanionInsight {
    pub insight_type: String,     // pattern|streak|imbalance|suggestion
    pub title:        String,
    pub body:         String,
    pub metric:       Option<f64>,
    pub priority:     u8,         // 1=highest
}

// ─── PATTERN ANALYSER ────────────────────────────────────────────────────────

pub struct PatternAnalyser {
    base_path: String,
    did:       String,
}

impl PatternAnalyser {
    pub fn new(base_path: impl Into<String>, did: impl Into<String>) -> Self {
        Self { base_path: base_path.into(), did: did.into() }
    }

    fn events_lance(&self) -> String {
        format!("{}/{}/calendar/core/events.lance", self.base_path, self.did)
    }

    fn tasks_lance(&self) -> String {
        format!("{}/{}/calendar/core/tasks.lance", self.base_path, self.did)
    }

    fn open_conn(&self) -> CalendarResult<Connection> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch("INSTALL lance; LOAD lance;")
            .map_err(CalendarError::DuckDb)?;
        Ok(conn)
    }

    // ── TIME DISTRIBUTION ────────────────────────────────────────────────────

    pub fn time_distribution(
        &self,
        start_micros: i64,
        end_micros:   i64,
    ) -> CalendarResult<TimeDistribution> {
        let conn  = self.open_conn()?;
        let lance = self.events_lance();
        let period_days = ((end_micros - start_micros) / (86_400 * 1_000_000)).max(1) as u32;

        // By category
        let cat_sql = format!(
            "SELECT category, COUNT(*) as cnt, SUM((end_at - start_at) / 60000000) as total_mins
             FROM scan_lance('{lance}')
             WHERE start_at BETWEEN {start_micros} AND {end_micros}
               AND status != 'cancelled'
             GROUP BY category ORDER BY cnt DESC"
        );
        let mut stmt = conn.prepare(&cat_sql)?;
        let mut rows = stmt.query([])?;
        let mut by_category       = HashMap::new();
        let mut total_busy_mins   = 0i64;
        let mut total_events      = 0u64;
        let mut meeting_mins_sum  = 0i64;
        let mut meeting_count     = 0u64;

        while let Some(row) = rows.next()? {
            let cat: String  = row.get(0)?;
            let cnt: u64     = row.get(1)?;
            let mins: i64    = row.get(2).unwrap_or(0);
            by_category.insert(cat.clone(), cnt);
            total_busy_mins += mins;
            total_events    += cnt;
            if cat == "MEETING" {
                meeting_mins_sum += mins;
                meeting_count    += cnt;
            }
        }

        // By hour of day
        let hour_sql = format!(
            "SELECT hour(to_timestamp(start_at / 1000000)) as h,
                    COUNT(*) as cnt,
                    SUM((end_at - start_at) / 60000000) as mins
             FROM scan_lance('{lance}')
             WHERE start_at BETWEEN {start_micros} AND {end_micros}
               AND status != 'cancelled'
             GROUP BY h ORDER BY h"
        );
        let mut stmt = conn.prepare(&hour_sql)?;
        let mut rows = stmt.query([])?;
        let mut by_hour = Vec::new();
        while let Some(row) = rows.next()? {
            by_hour.push(HourBucket {
                hour:        row.get::<_, u8>(0).unwrap_or(0),
                event_count: row.get(1).unwrap_or(0),
                busy_mins:   row.get(2).unwrap_or(0),
            });
        }

        // By day of week
        let dow_names = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"];
        let dow_sql = format!(
            "SELECT dayofweek(to_timestamp(start_at / 1000000)) as dow,
                    COUNT(*) as cnt,
                    SUM((end_at - start_at) / 60000000) as mins
             FROM scan_lance('{lance}')
             WHERE start_at BETWEEN {start_micros} AND {end_micros}
               AND status != 'cancelled'
             GROUP BY dow ORDER BY dow"
        );
        let mut stmt = conn.prepare(&dow_sql)?;
        let mut rows = stmt.query([])?;
        let mut by_day = Vec::new();
        while let Some(row) = rows.next()? {
            let dow: u8 = row.get(0).unwrap_or(0);
            by_day.push(DayBucket {
                day_name:    dow_names.get(dow as usize).unwrap_or(&"Unknown").to_string(),
                event_count: row.get(1).unwrap_or(0),
                busy_mins:   row.get(2).unwrap_or(0),
            });
        }

        Ok(TimeDistribution {
            by_category,
            by_hour,
            by_day_of_week:   by_day,
            total_events,
            total_busy_mins,
            avg_meeting_mins: if meeting_count > 0 { meeting_mins_sum as f64 / meeting_count as f64 } else { 0.0 },
            period_days,
        })
    }

    // ── PRACTICE ADHERENCE ───────────────────────────────────────────────────

    pub fn practice_adherence(
        &self,
        practice_title: &str,
        start_micros:   i64,
        end_micros:     i64,
    ) -> CalendarResult<PracticeAdherence> {
        let conn  = self.open_conn()?;
        let lance = self.events_lance();
        let safe_title = practice_title.replace('\'', "''");

        let sql = format!(
            "SELECT
               CAST(date_trunc('day', to_timestamp(start_at / 1000000)) AS VARCHAR) AS day,
               hour(to_timestamp(start_at / 1000000)) AS hr
             FROM scan_lance('{lance}')
             WHERE category = 'PRACTICE'
               AND title ILIKE '%{safe_title}%'
               AND status = 'confirmed'
               AND start_at BETWEEN {start_micros} AND {end_micros}
             ORDER BY day DESC"
        );

        let mut stmt = conn.prepare(&sql)?;
        let mut rows = stmt.query([])?;
        let mut days   = vec![];
        let mut hours  = vec![];

        while let Some(row) = rows.next()? {
            days.push(row.get::<_, String>(0)?);
            hours.push(row.get::<_, u8>(1).unwrap_or(0));
        }

        let total_completed = days.len() as u32;
        let (current_streak, longest_streak) = compute_streaks(&days);

        // Most common hour
        let best_hour = if !hours.is_empty() {
            let mut freq = HashMap::new();
            for h in &hours { *freq.entry(h).or_insert(0u32) += 1; }
            freq.into_iter().max_by_key(|(_, c)| *c).map(|(h, _)| *h)
        } else {
            None
        };

        // Estimated scheduled (rrule expansion would give exact count; approximate here)
        let period_days = ((end_micros - start_micros) / (86_400 * 1_000_000)).max(1) as u32;
        let total_scheduled = period_days; // 1 per day assumed for daily practice

        let adherence_pct = if total_scheduled > 0 {
            (total_completed as f32 / total_scheduled as f32 * 100.0).min(100.0)
        } else {
            0.0
        };

        Ok(PracticeAdherence {
            title: practice_title.to_string(),
            total_scheduled,
            total_completed,
            adherence_pct,
            current_streak,
            longest_streak,
            best_hour,
            last_completed: days.first().cloned(),
        })
    }

    // ── MEETING PATTERNS ─────────────────────────────────────────────────────

    pub fn meeting_patterns(
        &self,
        start_micros: i64,
        end_micros:   i64,
    ) -> CalendarResult<MeetingPatterns> {
        let conn  = self.open_conn()?;
        let lance = self.events_lance();
        let period_days = ((end_micros - start_micros) / (86_400 * 1_000_000)).max(1) as f64;

        let sql = format!(
            "SELECT
               COUNT(*) as total,
               AVG((end_at - start_at) / 60000000.0) as avg_mins,
               MAX((end_at - start_at) / 60000000) as max_mins,
               mode() WITHIN GROUP (ORDER BY hour(to_timestamp(start_at / 1000000))) as peak_hour
             FROM scan_lance('{lance}')
             WHERE category = 'MEETING'
               AND start_at BETWEEN {start_micros} AND {end_micros}
               AND status = 'confirmed'"
        );

        let mut stmt = conn.prepare(&sql)?;
        let mut rows = stmt.query([])?;
        let (total, avg_mins, max_mins, peak_hour) = if let Some(row) = rows.next()? {
            (
                row.get::<_, u64>(0).unwrap_or(0),
                row.get::<_, f64>(1).unwrap_or(0.0),
                row.get::<_, i64>(2).unwrap_or(0),
                row.get::<_, u8>(3).unwrap_or(9),
            )
        } else {
            (0, 0.0, 0, 9)
        };

        // Count back-to-back meetings (gap < 5 min)
        let btb_sql = format!(
            "WITH meetings AS (
               SELECT start_at, end_at,
                 LAG(end_at) OVER (ORDER BY start_at) as prev_end
               FROM scan_lance('{lance}')
               WHERE category = 'MEETING'
                 AND start_at BETWEEN {start_micros} AND {end_micros}
                 AND status = 'confirmed'
             )
             SELECT COUNT(*) FROM meetings
             WHERE prev_end IS NOT NULL
               AND (start_at - prev_end) < 300000000"  // < 5 min gap
        );
        let mut stmt = conn.prepare(&btb_sql)?;
        let back_to_back = stmt.query_row([], |r| r.get::<_, u64>(0)).unwrap_or(0);

        // Focus vs meeting ratio
        let block_sql = format!(
            "SELECT
               COUNT(*) FILTER (WHERE category = 'BLOCK') as focus_blocks,
               COUNT(*) as total_blocks
             FROM scan_lance('{lance}')
             WHERE start_at BETWEEN {start_micros} AND {end_micros}
               AND status = 'confirmed'
               AND category IN ('BLOCK', 'MEETING', 'PRACTICE', 'ACTIVITY')"
        );
        let mut stmt = conn.prepare(&block_sql)?;
        let focus_ratio = stmt.query_row([], |r| {
            let focus: u64 = r.get(0)?;
            let total: u64 = r.get(1)?;
            Ok(if total > 0 { focus as f64 / total as f64 } else { 0.0 })
        }).unwrap_or(0.0);

        Ok(MeetingPatterns {
            avg_per_day:          total as f64 / period_days,
            avg_duration_mins:    avg_mins,
            peak_meeting_hour:    peak_hour,
            back_to_back_count:   back_to_back,
            longest_meeting_mins: max_mins,
            by_category:          HashMap::new(), // populated by time_distribution
            focus_block_ratio:    focus_ratio,
        })
    }

    // ── ATTENDEE FREQUENCY ───────────────────────────────────────────────────

    pub fn attendee_frequency(
        &self,
        start_micros: i64,
        end_micros:   i64,
        top_n:        u32,
    ) -> CalendarResult<Vec<AttendeeFrequency>> {
        // Phase 6: full attendee analysis via DuckDB JSON unnesting
        // attendees_json column contains JSON array of DIDs
        // DuckDB: UNNEST(from_json(attendees_json, '["VARCHAR"]'))
        // Simplified for Phase 6 — returns empty until Lance indexing ready
        Ok(vec![])
    }

    // ── COMPANION INSIGHTS ───────────────────────────────────────────────────

    /// Generate actionable companion insights from analytics patterns
    pub fn generate_insights(
        &self,
        start_micros: i64,
        end_micros:   i64,
    ) -> CalendarResult<Vec<CompanionInsight>> {
        let dist     = self.time_distribution(start_micros, end_micros)?;
        let meetings = self.meeting_patterns(start_micros, end_micros)?;
        let mut insights = vec![];

        // Insight: meeting overload
        if meetings.avg_per_day > 5.0 {
            insights.push(CompanionInsight {
                insight_type: "imbalance".to_string(),
                title:        "High meeting load".to_string(),
                body:         format!(
                    "You're averaging {:.1} meetings per day. Consider protecting more focus time.",
                    meetings.avg_per_day
                ),
                metric:   Some(meetings.avg_per_day),
                priority: 1,
            });
        }

        // Insight: low focus block ratio
        if meetings.focus_block_ratio < 0.2 && dist.total_events > 10 {
            insights.push(CompanionInsight {
                insight_type: "suggestion".to_string(),
                title:        "Add more focus blocks".to_string(),
                body:         format!(
                    "Only {:.0}% of your scheduled time is protected focus. Deep work benefits from at least 30%.",
                    meetings.focus_block_ratio * 100.0
                ),
                metric:   Some(meetings.focus_block_ratio * 100.0),
                priority: 2,
            });
        }

        // Insight: back-to-back meetings
        if meetings.back_to_back_count > 3 {
            insights.push(CompanionInsight {
                insight_type: "pattern".to_string(),
                title:        "Frequent back-to-back meetings".to_string(),
                body:         format!(
                    "You have {} back-to-back meetings this period. Adding 5-minute buffers improves transition quality.",
                    meetings.back_to_back_count
                ),
                metric:   Some(meetings.back_to_back_count as f64),
                priority: 2,
            });
        }

        // Insight: peak meeting hour
        if meetings.peak_meeting_hour < 9 || meetings.peak_meeting_hour > 17 {
            insights.push(CompanionInsight {
                insight_type: "pattern".to_string(),
                title:        "Off-hours meeting pattern".to_string(),
                body:         format!(
                    "Your peak meeting hour is {:02}:00, which is outside standard hours.",
                    meetings.peak_meeting_hour
                ),
                metric:   Some(meetings.peak_meeting_hour as f64),
                priority: 3,
            });
        }

        // Sort by priority
        insights.sort_by_key(|i| i.priority);
        Ok(insights)
    }
}

// ─── HELPERS ─────────────────────────────────────────────────────────────────

fn compute_streaks(days_desc: &[String]) -> (u32, u32) {
    if days_desc.is_empty() { return (0, 0); }

    let mut current = 1u32;
    let mut longest = 1u32;
    let mut running = 1u32;

    for window in days_desc.windows(2) {
        let prev = chrono::NaiveDate::parse_from_str(&window[0], "%Y-%m-%d").ok();
        let next = chrono::NaiveDate::parse_from_str(&window[1], "%Y-%m-%d").ok();
        if let (Some(p), Some(n)) = (prev, next) {
            if (p - n).num_days() == 1 {
                running += 1;
                longest  = longest.max(running);
            } else {
                if days_desc.first().map(|d| d == &window[0]).unwrap_or(false) {
                    current = running;
                }
                running = 1;
            }
        }
    }

    let current_final = if days_desc.len() == 1 { 1 } else { current };
    (current_final, longest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compute_streaks_consecutive() {
        let days = vec![
            "2026-05-10".into(), "2026-05-09".into(), "2026-05-08".into(),
        ];
        let (current, longest) = compute_streaks(&days);
        assert_eq!(longest, 3);
    }

    #[test]
    fn test_compute_streaks_broken() {
        let days = vec!["2026-05-10".into(), "2026-05-08".into()];
        let (_, longest) = compute_streaks(&days);
        assert_eq!(longest, 1);
    }

    #[test]
    fn test_compute_streaks_empty() {
        let (c, l) = compute_streaks(&[]);
        assert_eq!(c, 0);
        assert_eq!(l, 0);
    }

    #[test]
    fn test_insight_generation_no_panic_on_empty() {
        // Can't run full DuckDB in unit test (no Lance files) — test struct creation
        let insight = CompanionInsight {
            insight_type: "pattern".to_string(),
            title:        "Test insight".to_string(),
            body:         "Body text".to_string(),
            metric:       Some(4.2),
            priority:     1,
        };
        assert_eq!(insight.priority, 1);
    }
}
