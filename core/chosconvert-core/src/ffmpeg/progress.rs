//! Parser for FFmpeg's machine-readable `-progress` output (key=value blocks).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ProgressSnapshot {
    /// Position in the output timeline, seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub out_time_s: Option<f64>,
    /// 0…1 when the total duration is known; `None` means indeterminate.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fraction: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub speed: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fps: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_size: Option<u64>,
    pub ended: bool,
}

/// Incremental parser. Feed it lines; it yields a snapshot at each `progress=` marker.
#[derive(Debug, Default)]
pub struct ProgressParser {
    duration_s: Option<f64>,
    current: ProgressSnapshot,
}

impl ProgressParser {
    pub fn new(duration_s: Option<f64>) -> Self {
        Self {
            duration_s: duration_s.filter(|d| *d > 0.0 && d.is_finite()),
            current: ProgressSnapshot::default(),
        }
    }

    pub fn feed(&mut self, line: &str) -> Option<ProgressSnapshot> {
        let (key, value) = line.trim().split_once('=')?;
        let value = value.trim();
        let na = value == "N/A" || value.is_empty();
        match key.trim() {
            "out_time_us" | "out_time_ms" if !na => {
                // Despite its name, out_time_ms is also expressed in microseconds.
                if let Ok(us) = value.parse::<i64>() {
                    if us >= 0 {
                        self.current.out_time_s = Some(us as f64 / 1_000_000.0);
                    }
                }
            }
            "out_time" if !na && self.current.out_time_s.is_none() => {
                self.current.out_time_s = parse_clock(value);
            }
            "speed" if !na => {
                self.current.speed = value.trim_end_matches('x').trim().parse().ok();
            }
            "fps" if !na => self.current.fps = value.parse().ok(),
            "frame" if !na => self.current.frame = value.parse().ok(),
            "total_size" if !na => self.current.total_size = value.parse().ok(),
            "progress" => {
                let mut snap = std::mem::take(&mut self.current);
                snap.ended = value == "end";
                snap.fraction = match (self.duration_s, snap.out_time_s) {
                    (Some(d), Some(t)) => Some((t / d).clamp(0.0, 1.0)),
                    _ => None,
                };
                if snap.ended && self.duration_s.is_some() {
                    snap.fraction = Some(1.0);
                }
                return Some(snap);
            }
            _ => {}
        }
        None
    }
}

/// Parses `HH:MM:SS.micro`.
pub fn parse_clock(s: &str) -> Option<f64> {
    let mut parts = s.split(':');
    let h: f64 = parts.next()?.parse().ok()?;
    let m: f64 = parts.next()?.parse().ok()?;
    let sec: f64 = parts.next()?.parse().ok()?;
    if parts.next().is_some() || h < 0.0 {
        return None;
    }
    Some(h * 3600.0 + m * 60.0 + sec)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_blocks() {
        let mut p = ProgressParser::new(Some(10.0));
        let block = "frame=120\nfps=59.9\nbitrate=1000kbits/s\ntotal_size=524288\n\
                     out_time_us=5000000\nout_time=00:00:05.000000\nspeed=2.01x\nprogress=continue";
        let snaps: Vec<_> = block.lines().filter_map(|l| p.feed(l)).collect();
        assert_eq!(snaps.len(), 1);
        let s = &snaps[0];
        assert_eq!(s.frame, Some(120));
        assert_eq!(s.fraction, Some(0.5));
        assert_eq!(s.speed, Some(2.01));
        assert!(!s.ended);

        let end = "out_time_us=N/A\nspeed=N/A\nprogress=end";
        let s = end
            .lines()
            .filter_map(|l| p.feed(l))
            .next()
            .expect("end snapshot");
        assert!(s.ended);
        assert_eq!(s.fraction, Some(1.0));
    }

    #[test]
    fn unknown_duration_is_indeterminate() {
        let mut p = ProgressParser::new(None);
        p.feed("out_time_us=1000");
        let s = p.feed("progress=continue").expect("snapshot");
        assert_eq!(s.fraction, None);
    }

    #[test]
    fn fraction_is_clamped_and_negative_times_ignored() {
        let mut p = ProgressParser::new(Some(1.0));
        p.feed("out_time_us=-9223372036854775807");
        assert_eq!(p.feed("progress=continue").and_then(|s| s.fraction), None);
        p.feed("out_time_us=5000000");
        assert_eq!(
            p.feed("progress=continue").and_then(|s| s.fraction),
            Some(1.0)
        );
    }

    #[test]
    fn clock() {
        assert_eq!(parse_clock("01:02:03.5"), Some(3723.5));
        assert_eq!(parse_clock("bad"), None);
    }
}
