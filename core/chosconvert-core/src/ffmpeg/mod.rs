//! FFmpeg integration: structured arguments, progress parsing and process execution.
//!
//! Rules enforced here:
//! * FFmpeg is always spawned directly with an argument vector — never through a shell.
//! * User paths are only ever substituted into dedicated `{input}`/`{output}` slots and are
//!   passed as `file:` URLs so that names such as `concat:…`, `http:…` or `--help.mov` are
//!   treated as plain files.

pub mod progress;
pub mod runner;

/// Placeholders allowed in argument templates produced by the planner.
pub const INPUT: &str = "{input}";
pub const OUTPUT: &str = "{output}";
pub const PASSLOG: &str = "{passlog}";
pub const NULL: &str = "{null}";

/// Converts an absolute path into an FFmpeg `file:` URL.
pub fn file_url(path: &str) -> String {
    format!("file:{path}")
}

/// Platform null sink used for first passes.
pub fn null_sink() -> &'static str {
    if cfg!(windows) { "NUL" } else { "/dev/null" }
}

/// Substitutes the placeholders of an argument template. Only whole-argument placeholders are
/// replaced, so a user-controlled path can never be spliced into another option.
pub fn materialize(
    template: &[String],
    input: &str,
    output: &str,
    passlog: Option<&str>,
) -> Vec<String> {
    template
        .iter()
        .map(|a| match a.as_str() {
            INPUT => file_url(input),
            OUTPUT => file_url(output),
            PASSLOG => passlog.unwrap_or("ffmpeg2pass").to_string(),
            NULL => null_sink().to_string(),
            other => other.to_string(),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hostile_names_stay_single_arguments() {
        let template: Vec<String> = ["-i", INPUT, "-c", "copy", OUTPUT]
            .iter()
            .map(|s| s.to_string())
            .collect();
        for name in [
            "hello world.mov",
            "\"video\".mov",
            "vídeo ñ.mov",
            "$HOME.mov",
            ";rm.mov",
            "--help.mov",
            "concat:a|b.mov",
            "`id`.mov",
            "a\nb.mov",
        ] {
            let input = format!("/Users/test/{name}");
            let args = materialize(&template, &input, "/tmp/cc/out.mp4", None);
            assert_eq!(args.len(), 5);
            assert_eq!(args[1], format!("file:{input}"));
            assert_eq!(args[4], "file:/tmp/cc/out.mp4");
        }
    }

    #[test]
    fn placeholders_inside_arguments_are_not_expanded() {
        let template = vec!["-metadata".to_string(), "title={input}".to_string()];
        let args = materialize(&template, "/evil", "/out", None);
        assert_eq!(args[1], "title={input}");
    }
}
