// przma-calendar/src/analytics.rs
//
// DuckDB-powered analytics over Lance calendar files.
// Queries Lance files directly via DuckDB's Arrow scanner.

use duckdb::{Connection, Result as DuckResult};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use crate::error::{CalendarError, CalendarResult};

// ─── ANALYTICS STORE ─────────────────────────────────────────────────────────

pub struct CalendarAnalytics {
    base_path: String,
    did:       String,
}

impl CalendarAnalytics {
    pub fn new(base_path: impl Into<String>, did: impl Into<String>) -> Self {
        Self {
            base_path: base_path.into(),
            did:       did.into(),
        }
    }

    fn events_lance_path(&self) -> String {
        format!("{}/{}/calendar/core/events.lance", self.base_path, self.did)
    }

    fn tasks_lance_path(&self) -> String {
        format!("{}/{}/calendar/core/tasks.lance", self.base_path, self.did)
    }

    fn open_conn(&self) -> CalendarResult<Connection> {
        let conn = Connection::open_in_memory()?;
        // Install and load lance extension
        conn.execute_batch(
            "INSTALL lance; LOAD lance;"
        ).map_err(CalendarError::DuckDb)?;
        Ok(conn)
    }

    // ── EVENT COUNT BY CATEGORY ───────────────────────────────────────────────

    pub fn event_count_by_category(
        &self,
        start_micros: i64,
        end_micros:   i64,
    ) -> CalendarResult<HashMap<String, u64>> {
        let conn = self.open_conn()?;
        let path = self.events_lance_path();

        let sql = format!(
            "SELECT category, COUNT(*) as cnt
             FROM scan_lance('{}')
             WHERE start_at >= {} AND start_at <= {}
               AND status != 'cancelled'
             GROUP BY category
             ORDER BY cnt DESC",
            path, start_micros, end_micros
        );

        let mut stmt = conn.prepare(&sql)?;
        let mut rows = stmt.query([])?;
        let mut map  = HashMap::new();

        while let Some(row) = rows.next()? {
            let cat: String = row.get(0)?;
            let cnt: u64    = row.get(1)?;
            map.insert(cat, cnt);
        }
        Ok(map)
    }

    // ── BUSY TIME BY DAY ─────────────────────────────────────────────────────

    pub fn busy_minutes_by_day(
        &self,
        start_micros: i64,
        end_micros:   i64,
    ) -> CalendarResult<Vec<DayBusyStats>> {
        let conn = self.open_conn()?;
        let path = self.events_lance_path();

        let sql = format!(
            "SELECT
               date_trunc('day', to_timestamp(start_at / 1000000)) AS day,
               COUNT(*) AS event_count,
               SUM((end_at - start_at) / 60000000) AS total_minutes
             FROM scan_lance('{}')
             WHERE start_at >= {} AND start_at <= {}
               AND busy_status = 'busy'
               AND status = 'confirmed'
             GROUP BY day
             ORDER BY day",
            path, start_micros, end_micros
        );

        let mut stmt = conn.prepare(&sql)?;
        let mut rows = stmt.query([])?;
        let mut result = vec![];

        while let Some(row) = rows.next()? {
            result.push(DayBusyStats {
                day:           row.get(0)?,
                event_count:   row.get(1)?,
                total_minutes: row.get(2)?,
            });
        }
        Ok(result)
    }

    // ── TASK COMPLETION RATE ─────────────────────────────────────────────────

    pub fn task_completion_stats(
        &self,
        start_micros: i64,
        end_micros:   i64,
    ) -> CalendarResult<TaskCompletionStats> {
        let conn = self.open_conn()?;
        let path = self.tasks_lance_path();

        let sql = format!(
            "SELECT
               COUNT(*) FILTER (WHERE status != 'cancelled') AS total,
               COUNT(*) FILTER (WHERE status = 'complete') AS completed,
               COUNT(*) FILTER (WHERE status = 'active')   AS active,
               COUNT(*) FILTER (WHERE status = 'blocked')  AS blocked,
               COUNT(*) FILTER (WHERE status = 'deferred') AS deferred
             FROM scan_lance('{}')
             WHERE created_at >= {} AND created_at <= {}",
            path, start_micros, end_micros
        );

        let mut stmt = conn.prepare(&sql)?;
        let mut rows = stmt.query([])?;

        if let Some(row) = rows.next()? {
            Ok(TaskCompletionStats {
                total:     row.get(0)?,
                completed: row.get(1)?,
                active:    row.get(2)?,
                blocked:   row.get(3)?,
                deferred:  row.get(4)?,
            })
        } else {
            Ok(TaskCompletionStats::default())
        }
    }

    // ── PRACTICE STREAK ──────────────────────────────────────────────────────

    pub fn practice_streak(
        &self,
        practice_title: &str,
    ) -> CalendarResult<PracticeStreakStats> {
        let conn = self.open_conn()?;
        let path = self.events_lance_path();

        // Find all completed practice events matching title, newest first
        let sql = format!(
            "SELECT
               CAST(date_trunc('day', to_timestamp(start_at / 1000000)) AS VARCHAR) AS practice_day
             FROM scan_lance('{}')
             WHERE category = 'PRACTICE'
               AND title = '{}'
               AND status = 'confirmed'
             ORDER BY practice_day DESC",
            path, practice_title.replace('\'', "''")
        );

        let mut stmt = conn.prepare(&sql)?;
        let mut rows = stmt.query([])?;
        let mut days: Vec<String> = vec![];

        while let Some(row) = rows.next()? {
            days.push(row.get(0)?);
        }

        let current_streak = compute_streak(&days);
        let total_count    = days.len() as u32;

        Ok(PracticeStreakStats {
            title:          practice_title.to_string(),
            current_streak,
            total_count,
            last_completed: days.first().cloned(),
        })
    }

    // ── MEETING LOAD BY WEEK ──────────────────────────────────────────────────

    pub fn meeting_load_by_week(
        &self,
        start_micros: i64,
        end_micros:   i64,
    ) -> CalendarResult<Vec<WeekMeetingStats>> {
        let conn = self.open_conn()?;
        let path = self.events_lance_path();

        let sql = format!(
            "SELECT
               CAST(date_trunc('week', to_timestamp(start_at / 1000000)) AS VARCHAR) AS week,
               COUNT(*) as meeting_count,
               SUM((end_at - start_at) / 60000000) as meeting_minutes
             FROM scan_lance('{}')
             WHERE category = 'MEETING'
               AND start_at >= {} AND start_at <= {}
               AND status = 'confirmed'
             GROUP BY week
             ORDER BY week",
            path, start_micros, end_micros
        );

        let mut stmt = conn.prepare(&sql)?;
        let mut rows = stmt.query([])?;
        let mut result = vec![];

        while let Some(row) = rows.next()? {
            result.push(WeekMeetingStats {
                week:            row.get(0)?,
                meeting_count:   row.get(1)?,
                meeting_minutes: row.get(2)?,
            });
        }
        Ok(result)
    }

    // ── ARBITRARY SQL (for custom analytics) ─────────────────────────────────

    pub fn raw_query(&self, sql: &str) -> CalendarResult<Vec<Vec<String>>> {
        let conn = self.open_conn()?;
        let mut stmt = conn.prepare(sql)?;
        let col_count = stmt.column_count();
        let mut rows  = stmt.query([])?;
        let mut result: Vec<Vec<String>> = vec![];

        while let Some(row) = rows.next()? {
            let mut record = vec![];
            for i in 0..col_count {
                let val: duckdb::types::Value = row.get(i)?;
                record.push(format!("{:?}", val));
            }
            result.push(record);
        }
        Ok(result)
    }
}

// ─── RESULT STRUCTS ───────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct DayBusyStats {
    pub day:           String,
    pub event_count:   u64,
    pub total_minutes: i64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct TaskCompletionStats {
    pub total:     u64,
    pub completed: u64,
    pub active:    u64,
    pub blocked:   u64,
    pub deferred:  u64,
}

impl TaskCompletionStats {
    pub fn completion_rate(&self) -> f64 {
        if self.total == 0 { return 0.0; }
        self.completed as f64 / self.total as f64 * 100.0
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PracticeStreakStats {
    pub title:          String,
    pub current_streak: u32,
    pub total_count:    u32,
    pub last_completed: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WeekMeetingStats {
    pub week:            String,
    pub meeting_count:   u64,
    pub meeting_minutes: i64,
}

// ─── HELPERS ──────────────────────────────────────────────────────────────────

/// Compute current consecutive-day streak from a list of day strings (newest first)
fn compute_streak(days: &[String]) -> u32 {
    if days.is_empty() { return 0; }
    let mut streak = 1u32;
    for window in days.windows(2) {
        let prev = chrono::NaiveDate::parse_from_str(&window[0], "%Y-%m-%d").ok();
        let next = chrono::NaiveDate::parse_from_str(&window[1], "%Y-%m-%d").ok();
        if let (Some(p), Some(n)) = (prev, next) {
            if (p - n).num_days() == 1 {
                streak += 1;
            } else {
                break;
            }
        }
    }
    streak
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_streak_consecutive() {
        let days = vec![
            "2026-05-10".to_string(),
            "2026-05-09".to_string(),
            "2026-05-08".to_string(),
        ];
        assert_eq!(compute_streak(&days), 3);
    }

    #[test]
    fn test_streak_broken() {
        let days = vec![
            "2026-05-10".to_string(),
            "2026-05-08".to_string(), // gap on 9th
        ];
        assert_eq!(compute_streak(&days), 1);
    }

    #[test]
    fn test_completion_rate() {
        let stats = TaskCompletionStats { total: 10, completed: 7, active: 2, blocked: 1, deferred: 0 };
        assert!((stats.completion_rate() - 70.0).abs() < 0.001);
    }
}
